// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Package: `PaiGack/ftp/debug` -- the traffic log, its own package so that
// anything that speaks the wire can record it without pulling in the client.
//
// The traffic log: the MoonBit counterpart of upstream `debug.go`, plus the
// two decorators that route the control channel through it.
//
// This used to live at the bottom of `control.mbt`, on the argument that a log
// is only meaningful together with the connection it logs. That is true of the
// *switch*, and `Control` still owns it -- what lives here is the recorder
// itself: `DebugLog` and the two record paths know nothing about `Control`,
// and the ASCII codec under them is shared with no one. It is a
// package of its own rather than a file under `core/` or `connection/` because
// both layers record, and neither should have to import the other to say so.
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
/// The two directions get one record path each, `write_path` and `read_path`;
/// `Control` routes both of its directions through them, so the transcript and
/// the protocol see the same bytes. They are functions rather than the
/// `MultiWriter` / `TeeReader` decorators upstream uses because a decorator
/// needs `impl @io.Writer for <new type>`, and MoonBit lets only the defining
/// package write that -- a decorator living here could never wrap the socket
/// `Control` holds.
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
/// Record one already CRLF terminated record, byte for byte.
///
/// This is the entry point the control channel uses: it hands over exactly the
/// bytes it is about to write (or has just read), so the transcript cannot
/// disagree with the wire even when the payload is not valid UTF-8. A sink
/// that raises loses the record, never the caller -- see `write_path` and
/// `read_path` below.
pub async fn DebugLog::record(self : DebugLog, bytes : BytesView) -> Unit {
  self.sink.write(bytes)
}

///|
/// Record one line with its direction tag, the way `render` spells it.
///
/// The text arrives without its CRLF (`read_path` and `write_path` both frame
/// on it), and `render` adds it back; a caller that pre-terminated the line
/// would put a blank record in the transcript, so a trailing CRLF is dropped
/// here rather than at every call site.
async fn DebugLog::record_line(
  self : DebugLog,
  direction : DebugDirection,
  text : String,
) -> Unit {
  let body = if text.has_suffix("\r\n") {
    text[0:text.length() - 2].to_owned()
  } else {
    text
  }
  self.sink.write(encode_ascii(self.render(direction, body)))
}

///|
/// One write through the log: the bytes go to `inner` first, then the bytes
/// that `inner` actually accepted are recorded.
///
/// The order is the point. A write that raises still records what was
/// attempted (the command never reached the wire, and that is the single most
/// useful line in a desynchronised session), but a *short* write records only
/// what the socket took -- logging the offered buffer would put bytes in the
/// transcript that never left the client.
///
/// This used to be the `MirrorWriter` decorator. It is a function now because
/// the type lived in this package while `Control` did not, and MoonBit does
/// not let another package `impl @io.Writer` for a type it does not own.
pub async fn DebugLog::write_path(
  self : DebugLog,
  inner : &@io.Writer,
  bytes : BytesView,
) -> Unit {
  let buf = bytes.to_owned()
  let (n, failure) : (Int32, Error?) = (
    inner.write_once(buf, offset=0, len=buf.length()),
    None,
  ) catch {
    e => {
      self.record_line(Command, decode_ascii(bytes)) catch {
        _ => ()
      }
      (-1, Some(e))
    }
  }
  match failure {
    Some(e) => raise e
    None => ()
  }
  guard n > 0 else { return }
  self.record_line(Command, decode_ascii(bytes[0:n])) catch {
    _ => ()
  }
}

///|
/// Read one line through the log: `inner.read_until` frames it, the bytes that
/// were actually produced are recorded before the framed line is returned.
///
/// This used to be the `TeeLogReader` decorator, moved to a function for the
/// same ownership reason as `write_path`. It records what it read *including*
/// false reads -- a zero length read is not an error, there was simply no line.
pub async fn DebugLog::read_path(
  self : DebugLog,
  inner : &@io.Reader,
  delimiter : StringView,
) -> String? {
  let line = inner.read_until(delimiter)
  match line {
    Some(text) => self.record_line(Reply, text) catch { _ => () }
    None => ()
  }
  line
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
/// Decode a byte chunk as ASCII.
///
/// A control line is ASCII by RFC 959 (the UTF8 feature only widens the
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
/// A control line is ASCII by RFC 959, so a byte for byte translation is
/// enough -- and it cannot fail, which keeps a malformed line from turning
/// into a dropped log entry.
fn encode_ascii(text : String) -> Bytes {
  let out = FixedArray::make(text.length(), b'\x00')
  for i = 0; i < text.length(); i = i + 1 {
    out[i] = text.unsafe_get(i).to_int().to_byte()
  }
  out.unsafe_reinterpret_as_bytes()
}
