// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

// The control connection and the request/response framing on top of it.
//
// This file merges `control`, `command` and `response` (that split
// had already lost its files before this change: the block comments below are
// the only trace of it). A control connection is only meaningful together with
// the two operations performed on it (write a command, read a reply), and the
// reply type exists solely as the return of `read_response`. None of the three
// pieces was ever used apart from the others.

///|
/// An FTP control connection: a line buffered reader/writer pair over the
/// underlying socket.
///
/// The reader and the writer are kept as trait objects so the same code drives
/// a plain `Tcp` socket and a `Tls` connection after `AUTH TLS`.
pub struct Control {
  mut reader : &@io.Reader
  mut writer : &@io.Writer
  /// Address of the peer we are talking to; the `PASV` SSRF guard trusts this
  /// one, not the address the server advertises.
  host : String
  /// Deadline applied to every reply read, in milliseconds; `0` disables it.
  ///
  /// A read with no deadline is not merely missing a diagnostic: it is the
  /// shape the async runtime reports as a *deadlock*. `check_dead_lock` fires
  /// as soon as every task is parked, and a suspended socket read counts as
  /// parked — so a server that takes a few milliseconds longer than the client
  /// expects (a real ftpd answers `150` only *after* it accepted the data
  /// connection, which is one scheduling round where the client is already
  /// waiting) aborts the process with SIGABRT instead of waiting. The report
  /// then names whichever unrelated task happened to be parked too, which is
  /// how a plain `STOR` came to be blamed on a `MemoryReader` two files away.
  /// A deadline makes the wait bounded: the loop has a timer to expire, the
  /// deadlock check never runs, and a genuinely silent peer turns into a plain
  /// `FtpError` the caller can read.
  timeout_ms : Int32
  /// Traffic log sink, `None` when logging is off.
  ///
  /// The switch lives on the connection rather than being baked into the
  /// reader/writer at dial time (which is how upstream `debug.go` wires itself
  /// through `wrapConn`) because `Control::upgrade` replaces that pair
  /// wholesale after `AUTH TLS`: a decorator installed once at dial time would
  /// go on logging the plaintext socket and silently stop covering the TLS
  /// session every later command travels over. Keeping the switch here also
  /// means the logging layer never owns a `Reader`, so the `MemoryReader`
  /// ownership rule in AGENTS.md cannot be broken by turning logging on.
  mut debug : DebugLog?
}

///|
/// Wrap an already connected reader/writer pair.
pub fn Control::new(
  reader : &@io.Reader,
  writer : &@io.Writer,
  host : String,
  timeout_ms~ : Int32 = 0,
  debug~ : DebugLog? = None,
) -> Control {
  { reader, writer, host, timeout_ms, debug, }
}

///|
/// Install (or clear) the traffic log on an already built connection.
///
/// Separate from `Control::new` so `dial` can attach the sink the caller asked
/// for without every other call site growing the label.
pub fn Control::set_debug(self : Control, debug : DebugLog?) -> Unit {
  self.debug = debug
}

///|
/// Whether the traffic log is on.
pub fn Control::debug_enabled(self : Control) -> Bool {
  self.debug is Some(_)
}

///|
/// The peer address of the control connection.
pub fn Control::host(self : Control) -> String {
  self.host
}

///|
/// Replace the underlying reader/writer, used when the connection is upgraded
/// to TLS after `AUTH TLS`.
pub fn Control::upgrade(
  self : Control,
  reader : &@io.Reader,
  writer : &@io.Writer,
) -> Unit {
  self.reader = reader
  self.writer = writer
}

///|
/// Write `line` followed by CRLF.
pub async fn Control::send_line(self : Control, line : String) -> Unit {
  match self.debug {
    None => self.writer.write(line + "\r\n")
    Some(log) => {
      // Logging wraps the *same* write, and a sink that raises is swallowed
      // inside the decorator: the log is a diagnostic, so a broken sink must
      // not stop a command upstream would have sent.
      let mirror = MirrorWriter::new(self.writer, log~)
      @io.Writer::write(mirror, line + "\r\n")
    }
  }
}

///|
/// Read one line, without its trailing CRLF. Raises `ReaderClosed` when the
/// connection was closed before a complete line arrived, and
/// `RequestTimeout` when the server stayed silent for `timeout_ms`.
///
/// The deadline is on *the reply*, not on the transfer: only the idle part of
/// a wait is bounded, so a long listing still completes as long as the server
/// keeps the lines coming.
pub async fn Control::read_line(self : Control) -> String {
  // With logging on, the teeing reader *is* the source: the reply is recorded
  // by the same `read_until` that frames it, so a transcript cannot disagree
  // with what the parser saw. The trait object keeps this branch free of any
  // extra buffering.
  let source : &@io.Reader = match self.debug {
    None => self.reader
    Some(log) => {
      let tee = TeeLogReader::new(self.reader, log~)
      tee
    }
  }
  let read = async fn() -> String {
    match source.read_until("\r\n") {
      Some(line) => line
      None => raise @io.ReaderClosed
    }
  }
  // The deadline wraps *only* the socket read. Logging rides inside it, but
  // `TeeLogReader` swallows every sink error, so it can neither raise nor
  // stall: a server that stayed silent is still reported as silent, and a
  // broken sink still cannot turn a reply into a `RequestTimeout` -- the point
  // of the deadline rule in AGENTS.md.
  if self.timeout_ms > 0 {
    @async.with_timeout(self.timeout_ms, read) catch {
      @async.TimeoutError => raise FtpError::RequestTimeout
      err => raise err
    }
  } else {
    read()
  }
}

///|
/// Send `cmd` (already encoded) and return the reply.
pub async fn cmd(control : Control, command : String) -> Response {
  check_for_command_injection(command)
  control.send_line(command)
  read_response(control)
}

///|
/// Send `cmd` and require one of the `expected` status codes.
///
/// An empty `expected` list accepts any code, which is how upstream spells
/// `cmd(..., -1)` for the `expected == -1` case. A mismatch raises
/// `FtpError::ServerError` carrying the original message.
pub async fn cmd_expect(
  control : Control,
  command : String,
  expected : Array[Int32],
) -> Response {
  let response = cmd(control, command)
  if expected.length() == 0 || expected.contains(response.code()) {
    return response
  }
  raise FtpError::ServerError(code=response.code(), msg=response.message())
}

///|
/// Send `\`format\`` with `args` applied through `{}` substitution and require
/// one of the `expected` codes. Convenience wrapper mirroring upstream
/// `cmd(format, args, expected...)`.
pub async fn cmd_format(
  control : Control,
  format : String,
  args : Array[String],
  expected : Array[Int32],
) -> Response {
  cmd_expect(control, render_command(format, args), expected)
}

///|
/// Apply `{}` substitution to `format` without sending anything, validating
/// every argument first.
///
/// Split out of `cmd_format` because the `PRET` handshake needs the rendered
/// command *before* it is sent: it announces the line that follows, so the two
/// must be built by the same code or they drift.
pub fn render_command(
  format : String,
  args : Array[String],
) -> String raise FtpError {
  let mut rendered = format
  for arg in args {
    check_for_command_injection(arg)
    rendered = replace_first(rendered, "{}", arg)
  }
  rendered
}

///|
/// Refuse command arguments that contain CR or LF.
///
/// Upstream calls this `checkForCommandInjection`; the check must happen
/// before a single byte is written to the socket, otherwise a crafted path
/// could smuggle extra FTP commands into the session.
pub fn check_for_command_injection(arg : String) -> Unit raise FtpError {
  for byte in arg {
    if byte == '\r' || byte == '\n' {
      raise FtpError::InvalidCommand(arg~)
    }
  }
}

///|
/// Replace the first occurrence of `{}` in `format` with `value`.
fn replace_first(format : String, pattern : String, value : String) -> String {
  let index = match format.find(pattern) {
    Some(index) => index
    None => return format
  }
  format[0:index].to_owned() +
  value +
  format[index + pattern.length():].to_owned()
}

///|
/// One direction of the traffic log.
pub(all) enum DebugDirection {
  /// A line the client sent to the server.
  Command
  /// A line the server sent back.
  Reply
}

///|
/// The traffic log: a direction tagged, CRLF terminated line sink.
///
/// This is the MoonBit equivalent of upstream `debug.go`'s `TeeReader` /
/// `MultiWriter` pair, assembled into one object because a single transcript is
/// the point -- two untagged writers produce exactly the log you cannot debug
/// with. Upstream derives the direction implicitly, by teeing the socket's read
/// side and fanning out its write side; here the direction is an explicit tag,
/// so the record stays self describing even if a caller routes the two
/// directions into different sinks.
///
/// The two decorators are `MirrorWriter` (write side, the `MultiWriter` half)
/// and `TeeLogReader` (read side); `Control` routes both of its directions
/// through them, so the transcript and the protocol see the same bytes.
pub(all) struct DebugLog {
  sink : &@io.Writer
  /// Whether each record carries its `>>>` / `<<<` direction tag.
  prefix : Bool
}

///|
/// Build a traffic log over `sink`, tagging each line with its direction.
pub fn DebugLog::new(sink : &@io.Writer, prefix~ : Bool = true) -> DebugLog {
  { sink, prefix, }
}

///|
/// Render one log record as it goes onto the wire.
pub fn DebugLog::render(
  self : DebugLog,
  direction : DebugDirection,
  line : String,
) -> String {
  let tag = match direction {
    Command => ">>> "
    Reply => "<<< "
  }
  let body = if self.prefix { tag + line } else { line }
  body + "\r\n"
}

///|
/// Append one captured line, tagged with its direction.
///
/// `Writer::write` already loops over short writes and a `BytesView` is one of
/// its `@io.Data` payloads, so the record goes out whole or the sink raises.
pub async fn DebugLog::write_line(
  self : DebugLog,
  direction : DebugDirection,
  line : String,
) -> Unit {
  self.sink.write(encode_ascii(self.render(direction, line)))
}

///|
/// The `MultiWriter` half of upstream `debug.go`: every byte written through
/// this writer goes to `inner` first and is then mirrored into `log`.
///
/// `Control::send_line` builds one per call instead of decorating its writer
/// once, for a reason `debug.go`'s shape hides: `Control::upgrade` replaces the
/// reader/writer pair wholesale after `AUTH TLS`, so a decorator installed at
/// dial time would keep logging the plaintext socket and stop covering the TLS
/// session every later command travels over. Decorating per call keeps the two
/// in step, and costs one `Option` match when logging is off.
///
/// A sink that raises does not fail the write: the decorator swallows the
/// error. Losing a log line is survivable, losing the session is not.
pub struct MirrorWriter {
  inner : &@io.Writer
  log : DebugLog
}

///|
/// Wrap `inner` so every write is also recorded as a command line.
pub fn MirrorWriter::new(inner : &@io.Writer, log~ : DebugLog) -> MirrorWriter {
  { inner, log, }
}

///|
impl @io.Writer for MirrorWriter with fn write_once(
  self : MirrorWriter,
  buf : Bytes,
  offset~ : Int32,
  len~ : Int32,
) -> Int32 {
  // If the write raises, the command never reached the wire; log what we
  // tried so the failure shows up in the transcript, then let it through.
  errdefer log_lines(self.log, Command, buf[offset:offset + len]) |> ignore
  let n = self.inner.write_once(buf, offset~, len~)
  guard n > 0 else { return n }
  // What the socket accepted is what gets logged, not what we offered: a short
  // write would otherwise put bytes in the transcript that never left the
  // client, which is the confusion a traffic log exists to remove.
  log_lines(self.log, Command, buf[offset:offset + n])
  n
}

///|
/// The `TeeReader` half of upstream `debug.go`: everything read through this
/// reader is mirrored into `log` before being handed to the caller.
///
/// The producer half of `@io.Reader` cannot be delegated by hand -- only
/// `moonbitlang/async/io` can mint a `ReaderBuffer` -- so `Control` keeps its
/// own reader and logs each line it parsed. This type is for the callers that
/// hand a reader somewhere `Control` is not: a data connection, or a `PRET`
/// preview. `_direct_read` is the one method that can be delegated, and it is
/// where the bytes are.
pub struct TeeLogReader {
  inner : &@io.Reader
  log : DebugLog
}

///|
/// Wrap `inner` so everything read through it is also recorded as a reply line.
pub fn TeeLogReader::new(inner : &@io.Reader, log~ : DebugLog) -> TeeLogReader {
  { inner, log, }
}

///|
impl @io.Reader for TeeLogReader with fn _get_internal_buffer(self) {
  self.inner._get_internal_buffer()
}

///|
impl @io.Reader for TeeLogReader with fn _direct_read(
  self : TeeLogReader,
  buf : FixedArray[Byte],
  offset~ : Int32,
  max_len~ : Int32,
) -> Int32 {
  let n = self.inner._direct_read(buf, offset~, max_len~)
  guard n > 0 else { return n }
  // Only the bytes the inner reader actually produced: `buf` beyond
  // `offset + n` is uninitialised scratch, and logging it would put a screenful
  // of NUL bytes in the transcript (which is exactly what this caught).
  log_lines(
    self.log,
    Reply,
    buf.unsafe_reinterpret_as_bytes()[offset:offset + n],
  )
  n
}

///|
/// Split a byte chunk into CRLF terminated lines and log each one.
///
/// A chunk that ends exactly on a line boundary yields a trailing empty piece
/// from `split`; it is dropped, because logging it would invent an empty
/// command that never went on the wire. A chunk whose last line is still
/// partial keeps that piece, which is what a buffered sink delivers.
///
/// The sink is a diagnostic, so nothing here may raise: a broken sink loses the
/// log line, never the session.
async fn log_lines(
  log : DebugLog,
  direction : DebugDirection,
  bytes : BytesView,
) -> Unit {
  let pieces : Array[StringView] = decode_ascii(bytes).split("\r\n").collect()
  let last = pieces.length() - 1
  for i = 0; i <= last; i = i + 1 {
    let piece = pieces[i]
    guard piece.length() > 0 || i < last else { continue }
    log.write_line(direction, piece.to_owned()) catch {
      _ => ()
    }
  }
}

///|
/// Decode a byte chunk as ASCII.
///
/// FTP control lines are ASCII by RFC 959 (the UTF8 feature only widens the
/// *argument* encoding, it never makes a control line binary), and the log is a
/// diagnostic, so a byte for byte translation is enough -- and it cannot fail,
/// which keeps a malformed line from turning into a dropped log entry.
fn decode_ascii(bytes : BytesView) -> String {
  let out = StringBuilder()
  let len = bytes.length()
  for i = 0; i < len; i = i + 1 {
    out.write_char(bytes[i].to_int().unsafe_to_char())
  }
  out.to_string()
}

///|
/// Encode an ASCII control line back to bytes.
///
/// The inverse of `decode_ascii`, and equally unable to fail.
fn encode_ascii(text : String) -> Bytes {
  let out = FixedArray::make(text.length(), b'\x00')
  for i = 0; i < text.length(); i = i + 1 {
    out[i] = text.unsafe_get(i).to_int().to_byte()
  }
  out.unsafe_reinterpret_as_bytes()
}

///|
/// A parsed FTP reply: the numeric status code and the (possibly multi line)
/// message body.
///
/// The body keeps the text of the framing status lines, matching the semantics
/// of Go's `textproto.ReadResponse`; see `read_response` for why the callers
/// depend on that.
pub struct Response {
  /// The 3 digit status code of the reply.
  code : Int32
  /// The message, with continuation lines joined by `\n`.
  message : String
} derive(@debug.Debug)

///|
/// `Response` promotes its `Debug` methods as regular methods; declare the
/// promotion explicitly so the deprecation warning stays away.
pub extend Response with @debug.Debug::{to_repr}

///|
/// Build a reply value.
pub fn Response::new(code : Int32, message : String) -> Response {
  { code, message, }
}

///|
/// The status code of the reply.
pub fn Response::code(self : Response) -> Int32 {
  self.code
}

///|
/// The message body of the reply.
pub fn Response::message(self : Response) -> String {
  self.message
}

///|
/// Read a complete reply from the control connection, handling both the single
/// line and the multi line (RFC 959 `211-...211 End`) shapes.
///
/// The result reproduces Go's `net/textproto.ReadResponse` byte for byte,
/// because the rest of the port (starting with `FEAT` and `MLST`) is written
/// against that shape. Two consequences are load bearing:
///
/// - the message **includes** the text of the first and of the terminating
///   status line, joined by `\n`. Go's `feat()` filters those back out with a
///   leading space test, and its `GetEntry` relies on `lines[1:lc-1]`; a body
///   that dropped the boundary lines would break `MLST` outright.
/// - a line that is exactly three digits, with no separator, is a
///   `short response` error, not an empty message.
///
/// The multi line terminator is the line that repeats the code *without* a
/// dash. Getting that wrong makes `FEAT` swallow the next reply, so it has a
/// dedicated test.
pub async fn read_response(control : Control) -> Response {
  let first = control.read_line()
  let code = match parse_code(first) {
    Some(code) => code
    None => raise FtpError::ParseError(msg="invalid response line: \{first}")
  }
  guard first.length() > 3 else {
    raise FtpError::ParseError(msg="short response: \{first}")
  }
  let head = first[4:].to_owned()
  if is_continuation(first) {
    let body : Array[String] = [head]
    while true {
      let line = control.read_line()
      let line_code = parse_code(line)
      if line_code == Some(code) && is_continuation(line) == false {
        guard line.length() > 3 else {
          raise FtpError::ParseError(msg="short response: \{line}")
        }
        body.push(line[4:].to_owned())
        break
      }
      body.push(line)
    }
    return { code, message: body.join("\n"), }
  }
  { code, message: head, }
}

///|
/// Parse the leading three digits of a reply line.
pub fn parse_code(line : String) -> Int32? {
  guard line.length() >= 3 else { return None }
  let mut value = 0
  for i = 0; i < 3; i = i + 1 {
    let c = line.unsafe_get(i).to_int()
    guard c >= 48 && c <= 57 else { return None }
    value = value * 10 + (c - 48)
  }
  Some(value)
}

///|
/// Whether the line is a multi line continuation (`211-Features:`), i.e. the
/// fourth byte is `-`.
pub fn is_continuation(line : String) -> Bool {
  line.length() > 3 && line.unsafe_get(3).to_int() == 45
}
