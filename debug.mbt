// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

// The traffic log: the MoonBit counterpart of upstream `debug.go`, plus the
// two decorators that route the control channel through it.
//
// This used to live at the bottom of `control.mbt`, on the argument that a log
// is only meaningful together with the connection it logs. That is true of the
// *switch*, and `Control` still owns it -- what lives here is the recorder
// itself: `DebugLog`, `MirrorWriter` and `TeeLogReader` know nothing about
// `Control`, and the ASCII codec under them is shared with no one. Keeping them
// apart leaves `control.mbt` about command framing and `debug.mbt` about
// recording, so the reader of either file has one subject.
//
// The two rules that must survive any refactor here are recorded in
// `docs/porting.md` section 3: the log is a diagnostic, so it must never change
// what a command or a reply read does (a raising sink loses its line, never the
// session), and it must stay out of the reply read's deadline.

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
