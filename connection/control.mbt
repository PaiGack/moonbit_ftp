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
//
// The traffic log used to sit at the bottom of this file. The *switch* still
// does -- `Control` owns the `DebugLog?` and installs it -- but the recorder
// and its decorators moved to `debug.mbt`, which knows nothing about `Control`.

///|
/// An FTP control connection: a line buffered reader/writer pair over the
/// underlying socket.
///
/// The reader and the writer are kept as trait objects so the same code drives
/// a plain `Tcp` socket and a `Tls` connection after `AUTH TLS`.
pub struct Control {
  mut reader : &@io.Reader
  mut writer : &@io.Writer
  /// Address of the peer we are talking to; the `PASV` / `EPSV` data channel
  /// trusts this one, not the address the server advertises.
  ///
  /// It is the *data channel* address, so it is always text an
  /// `@socket.Addr::parse` accepts: `1.2.3.4`, an IPv6 literal in brackets, or
  /// -- only when the dial target never resolved -- the hostname the caller
  /// passed, which is left to the platform resolver.
  host : String
  /// The name to put in the TLS server name indication, i.e. the host the
  /// *certificate* has to match.
  ///
  /// Separate from `host` on purpose: `dial("203.0.113.7:21", tls=true,
  /// trust=CustomPemFile(ca))` talks to an IP but the certificate was issued
  /// for a name, and verification would fail on a mismatch that is not one.
  ///
  /// `None` means "no TLS was ever set up on this connection", and it is the
  /// only way to say that. It used to be a `String` defaulting to `""`, which
  /// `Control::new` silently turned into the peer *address* -- so a caller that
  /// meant "the certificate is verified against the IP" and a caller that never
  /// set a name were indistinguishable, and the second one quietly became the
  /// first. Pass a `Some(name)` whenever an SNI / verification name exists:
  /// `dial` does so for both TLS flavours, including an IP dial where the
  /// address really is the name (that is a *decision*, spelled out at the
  /// call site, not a fallback).
  server_name : String?
  /// A positive deadline applied to every reply read, in milliseconds.
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
  /// `@core.FtpError` the caller can read.
  ///
  /// It is never zero: `Control::new` substitutes the default for `0` (and
  /// for a negative value) rather than letting "no timeout" be a valid
  /// configuration. A public API whose default is the SIGABRT shape is not
  /// secure by default, and a call site that forgets to pass `timeout_ms`
  /// would hit exactly that against a real server.
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
  mut debug : @debug.DebugLog?
}

///|
/// Wrap an already connected reader/writer pair.
///
/// Raises `ParseError` for a blank `server_name`; see the body.
pub fn Control::new(
  reader : &@io.Reader,
  writer : &@io.Writer,
  host : String,
  server_name~ : String? = None,
  timeout_ms~ : Int32 = 0,
  debug~ : @debug.DebugLog? = None,
) -> Control raise @core.FtpError {
  // There is no fallback from a name to the peer address. `None` means "none
  // was set" and stays that way, so a caller can tell it apart from the address
  // having been chosen deliberately. A blank `Some(name)` is a name that was
  // *set* and carries nothing -- useless to verify a certificate against and
  // even less useful as an SNI -- so it is refused instead of quietly becoming
  // "no name" (and, under the old default, the address).
  let name = match server_name {
    Some(name) if is_blank(name) =>
      raise @core.FtpError::ParseError(msg="blank TLS server name: \{host}")
    other => other
  }
  // `0` and a negative value both mean "no deadline", which is the shape the
  // runtime reports as a deadlock -- see the field's documentation. The public
  // default is therefore the protocol default (30s), not `0`.
  let deadline = if timeout_ms > 0 {
    timeout_ms
  } else {
    @core.default_dial_timeout_ms
  }
  { reader, writer, host, server_name: name, timeout_ms: deadline, debug, }
}

///|
/// Install (or clear) the traffic log on an already built connection.
///
/// Separate from `Control::new` so `dial` can attach the sink the caller asked
/// for without every other call site growing the label.
pub fn Control::set_debug(self : Control, debug : @debug.DebugLog?) -> Unit {
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
/// Whether `text` is empty or only whitespace.
///
/// Spelled as a byte loop rather than `trim().length() == 0`: a view's length
/// is measured in characters only up to its first multi-byte sequence, and a
/// name is never supposed to contain one anyway.
fn is_blank(text : String) -> Bool {
  for i = 0; i < text.length(); i = i + 1 {
    let c = text.unsafe_get(i)
    guard c == ' ' || c == '\t' || c == '\r' || c == '\n' else { return false }
  }
  true
}

///|
/// The deadline applied to every reply read, in milliseconds. Never zero.
pub fn Control::timeout_ms(self : Control) -> Int32 {
  self.timeout_ms
}

///|
/// The hostname the TLS certificate is verified against, `None` when none was
/// set (which is also "this connection was never upgraded to TLS").
pub fn Control::server_name(self : Control) -> String? {
  self.server_name
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
    Some(log) =>
      // Logging rides on the *same* write, and a sink that raises is swallowed
      // inside `write_path`: the log is a diagnostic, so a broken sink must
      // not stop a command upstream would have sent.
      log.write_path(self.writer, b"\{line}\r\n")
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
  let read = match self.debug {
    None =>
      async fn() -> String {
        match self.reader.read_until("\r\n") {
          Some(line) => line
          None => raise @io.ReaderClosed
        }
      }
    Some(log) =>
      async fn() -> String {
        match log.read_path(self.reader, "\r\n") {
          Some(line) => line
          None => raise @io.ReaderClosed
        }
      }
  }
  // The deadline wraps *only* the socket read. Logging rides inside it, but
  // `TeeLogReader` swallows every sink error, so it can neither raise nor
  // stall: a server that stayed silent is still reported as silent, and a
  // broken sink still cannot turn a reply into a `RequestTimeout` -- the point
  // of the deadline rule in AGENTS.md.
  //
  // The guard stays even though `Control::new` never stores a zero: the field
  // is `mut` inside the package, so this is the one place that decides a zero
  // means "unbounded" rather than "expire immediately".
  //
  // The size bound sits *inside* `read`, i.e. inside the deadline: `read_until`
  // has no bound of its own (it grows its buffer one read at a time until the
  // delimiter shows up), so a peer that never sends CRLF keeps it growing
  // while the read stays "busy". A check after the deadline returned would
  // only see the already-allocated line; checked inside, the oversized line is
  // still refused, and what a hostile peer can cost is bounded by the deadline
  // (see `max_reply_line_bytes` for the residual trade-off).
  let bounded = async fn() -> String {
    let line = read()
    guard line.length() <= @core.max_reply_line_bytes else {
      raise @core.FtpError::ParseError(
        msg="reply line exceeds \{@core.max_reply_line_bytes} bytes",
      )
    }
    line
  }
  if self.timeout_ms > 0 {
    @async.with_timeout(self.timeout_ms, bounded) catch {
      @async.TimeoutError => raise @core.FtpError::RequestTimeout
      err => raise err
    }
  } else {
    bounded()
  }
}

///|
/// Send `cmd` (already encoded) and return the reply.
pub async fn cmd(control : Control, command : String) -> @core.Response {
  check_for_command_injection(command)
  control.send_line(command)
  read_response(control)
}

///|
/// Send `cmd` and require one of the `expected` status codes.
///
/// An empty `expected` list accepts any code, which is how upstream spells
/// `cmd(..., -1)` for the `expected == -1` case -- but it is also what a caller
/// gets from a forgotten status list, and then the check is silently off. The
/// list is therefore required to be non-empty: a call site that really means
/// "any code" passes `accept_any_status`, so the intent is written down rather
/// than implied by an empty array. A mismatch raises
/// `@core.FtpError::ServerError` carrying the original message.
pub async fn cmd_expect(
  control : Control,
  command : String,
  expected : Array[Int32],
) -> @core.Response {
  // A forgotten status list must not read as "any code": refuse it before the
  // command goes out, so the bug shows up as an error naming the call and not
  // as a session that happily accepted `500`.
  guard expected.length() > 0 else {
    raise @core.FtpError::ParseError(
      msg="cmd_expect needs a status list; pass accept_any_status() to accept any code: \{command}",
    )
  }
  let response = cmd(control, command)
  if expected.contains(-1) || expected.contains(response.code()) {
    return response
  }
  raise @core.FtpError::ServerError(
    code=response.code(),
    msg=response.message(),
  )
}

///|
/// The explicit "any status code is acceptable" status list.
///
/// Upstream spells this `cmd(command, ..., -1)`; an empty list is refused (see
/// `cmd_expect`), so "any code" has to be asked for by name. No server can send
/// `-1`, which is what `cmd_expect` looks for; every real code is three digits
/// and compares against `expected`.
pub fn accept_any_status() -> Array[Int32] {
  [-1]
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
) -> @core.Response {
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
) -> String raise @core.FtpError {
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
pub fn check_for_command_injection(arg : String) -> Unit raise @core.FtpError {
  for byte in arg {
    if byte == '\r' || byte == '\n' {
      raise @core.FtpError::InvalidCommand(arg~)
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
pub async fn read_response(control : Control) -> @core.Response {
  let first = control.read_line()
  let code = match @core.parse_code(first) {
    Some(code) => code
    None =>
      raise @core.FtpError::ParseError(msg="invalid response line: \{first}")
  }
  guard first.length() > 3 else {
    raise @core.FtpError::ParseError(msg="short response: \{first}")
  }
  let head = first[4:].to_owned()
  if @core.is_continuation(first) {
    let body : Array[String] = [head]
    // Bounded as well: a server that never repeats its code (or keeps
    // listing continuation lines) would otherwise keep this loop alive for as
    // long as it keeps talking, which the per-line deadline cannot catch.
    while body.length() <= @core.max_reply_lines {
      let line = control.read_line()
      let line_code = @core.parse_code(line)
      if line_code == Some(code) && @core.is_continuation(line) == false {
        guard line.length() > 3 else {
          raise @core.FtpError::ParseError(msg="short response: \{line}")
        }
        body.push(line[4:].to_owned())
        break
      }
      body.push(line)
      // The per-line deadline catches a silent peer; this catches a chatty
      // one, which the deadline never sees because the read keeps completing.
      guard body.length() <= @core.max_reply_lines else {
        raise @core.FtpError::ParseError(
          msg="reply exceeds \{@core.max_reply_lines} lines",
        )
      }
    }
    return @core.Response::new(code, body.join("\n"))
  }
  @core.Response::new(code, head)
}

///|
/// Parse a `FEAT` body into a set of command names.
///
/// Feature lines have the shape ` COMMAND [description]`; only the first token
/// is kept, uppercased.
///
/// The leading space test is not cosmetic: the body carries the text of the
/// `211-Features:` and `211 End` framing lines too (see `@connection.read_response`), and
/// once trimmed they would otherwise register as features named `FEATURES:`
/// and `END`. Upstream filters with exactly this test.
///
/// A feature name may carry a parameter list after a `;`: RFC 2228 registers
/// the security extensions as `AUTH <mechanism>` and lets a server list the
/// mechanisms it supports on the same line, so vsftpd configured with
/// `ssl_enable=YES` may answer `AUTH TLS;TLS-C`. The name is cut at the `;`
/// as well as at the first space: a caller asking `has_feature("AUTH TLS")`
/// means "does this server speak TLS", and `AUTH TLS;TLS-C` is a yes. Without
/// the cut the entry was keyed `AUTH TLS;TLS-C`, the plaintext-login warning
/// in `login` never fired, and a server that advertises TLS *most* explicitly
/// was the one that stayed silent.
pub fn parse_features(body : String) -> Map[String, Bool] {
  let features : Map[String, Bool] = Map([])
  for line in body.split("\n") {
    guard line.length() > 0 && line.unsafe_get(0) == ' ' else { continue }
    let trimmed = line.trim()
    guard trimmed != "" else { continue }
    // The first space separates a feature name from its description, and the
    // name stops there -- `REST STREAM` caches `REST`, which is the name the
    // client asks for. The `;` lists the *parameters* of the name before it,
    // so it is cut first: `AUTH TLS;TLS-C` is `AUTH` with the mechanism `TLS`
    // and `TLS-C`, which is what `login`'s TLS warning has to recognise. The
    // second token is reattached for `AUTH` specifically, because RFC 2228
    // spells the mechanism-bearing name with a space.
    let head = match trimmed.find(";") {
      Some(index) => trimmed[0:index].to_owned()
      None => trimmed.to_owned()
    }
    let first = match head.find(" ") {
      Some(index) => head[0:index].to_owned()
      None => head
    }
    guard first != "" else { continue }
    let upper_first = first.to_upper()
    if upper_first == "AUTH" && head.to_upper().has_prefix("AUTH TLS") {
      features["AUTH TLS"] = true
    }
    features[upper_first] = true
  }
  features
}
