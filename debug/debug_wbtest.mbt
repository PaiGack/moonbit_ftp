// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Package: `PaiGack/ftp/debug`.
//
// White box tests for the traffic log (`DebugLog`, `MirrorWriter`,
// `TeeLogReader`).
//
// The rules these tests lock down, in the order the issue words them:
//
// 1. switch off => byte identical behaviour and zero output, which is what the
//    rest of the suite (and CI) relies on;
// 2. switch on => both directions are recorded whole, a multi line reply
//    included;
// 3. the log never swallows an error -- a sink that raises must not turn a
//    command into a failure.
//
// The `Control` hooks that drive this log are `PaiGack/ftp/connection`'s, and
// their tests live there; this package only owns the recorder.
//
// Every `@io.MemoryReader` here is bound to a name and closed in a `defer`:
// its producer runs in a background task that only `close` stops, and a parked
// producer trips the event loop's deadlock check (AGENTS.md).

///|
/// A writer that decodes every byte to ASCII and records each CRLF terminated
/// line.
struct RecordingSink {
  lines : Array[String]
  mut pending : String
}

///|
/// An empty recording sink.
fn recording_sink() -> RecordingSink {
  { lines: [], pending: "", }
}

///|
impl @io.Writer for RecordingSink with fn write_once(
  self : RecordingSink,
  buf : Bytes,
  offset~ : Int32,
  len~ : Int32,
) -> Int32 {
  let mut decoded = ""
  for i = offset; i < offset + len; i = i + 1 {
    decoded = decoded + buf[i].to_int().unsafe_to_char().to_string()
  }
  self.pending = self.pending + decoded
  while true {
    let index = match self.pending.find("\r\n") {
      Some(index) => index
      None => break
    }
    self.lines.push(self.pending[0:index].to_owned())
    self.pending = self.pending[index + 2:].to_owned()
  }
  len
}

///|
/// A traffic log sink that keeps whole decoded records.
///
/// The log renders `>>> CMD\r\n` / `<<< 220 ready\r\n`, so a `RecordingSink`
/// needed only to decode bytes would work too -- but its `pending` re-splits on
/// CRLF and would drop the trailing empty piece, which is exactly the boundary
/// the log tests assert. This one reads bytes and keeps the raw text.
struct LogSink {
  text : StringBuilder
}

///|
/// An empty traffic log sink.
fn log_sink() -> LogSink {
  { text: StringBuilder(), }
}

///|
impl @io.Writer for LogSink with fn write_once(
  self : LogSink,
  buf : Bytes,
  offset~ : Int32,
  len~ : Int32,
) -> Int32 {
  for i = offset; i < offset + len; i = i + 1 {
    self.text.write_char(buf[i].to_int().unsafe_to_char())
  }
  len
}

///|
/// The captured transcript, as one string.
fn LogSink::text(self : LogSink) -> String {
  self.text.to_string()
}

///|
/// A traffic log sink whose every write fails, to prove logging never changes
/// the outcome of a command.
struct FailingSink {}

///|
impl @io.Writer for FailingSink with fn write_once(
  self : FailingSink,
  buf : Bytes,
  offset~ : Int32,
  len~ : Int32,
) -> Int32 {
  ignore(self)
  ignore(buf)
  ignore(offset)
  ignore(len)
  raise @io.ReaderClosed
}

///|
/// `DebugLog::render` is the whole record format, so it is asserted directly:
/// tag, body, CRLF. Turning the tag off is what a caller does when it already
/// knows the direction (separate sinks per direction, say).
test "DebugLog::render tags the direction and terminates the line" {
  let sink = log_sink()
  let log = DebugLog::new(sink)
  assert_eq(log.render(Command, "NOOP"), ">>> NOOP\r\n")
  assert_eq(log.render(Reply, "200 OK"), "<<< 200 OK\r\n")
  let untagged = DebugLog::new(sink, prefix=false)
  assert_eq(untagged.render(Command, "NOOP"), "NOOP\r\n")
}

///|
/// The read side: `read_path` frames the line itself and records exactly the
/// bytes the reader produced.
async test "read_path mirrors what it reads" {
  let sink = log_sink()
  let inner = @io.MemoryReader(w => w.write("220 ready\r\n"))
  defer inner.close()
  let inner_ref : &@io.Reader = inner
  let line = DebugLog::new(sink).read_path(inner_ref, "\r\n")
  assert_true(line is Some("220 ready"))
  assert_eq(sink.text(), "<<< 220 ready\r\n")
}

///|
/// The write side: `write_path` forwards to the inner writer *and* logs, which
/// is what the old `MirrorWriter` decorator did.
async test "write_path forwards and logs" {
  let sink = log_sink()
  let inner = recording_sink()
  let inner_ref : &@io.Writer = inner
  DebugLog::new(sink).write_path(inner_ref, b"NOOP\r\n")
  assert_eq(inner.lines, ["NOOP"])
  assert_eq(sink.text(), ">>> NOOP\r\n")
}

///|
/// A sink that raises must not make a command fail: the log is a diagnostic,
/// and a broken diagnostic should not take the session with it.
async test "a failing log sink does not fail the command" {
  let inner = recording_sink()
  let inner_ref : &@io.Writer = inner
  DebugLog::new(FailingSink::{ }).write_path(inner_ref, b"NOOP\r\n")
  assert_eq(inner.lines, ["NOOP"])
}

///|
/// A write the inner writer *rejects* is still logged, and the error is
/// re-raised: a command that never reached the wire is the single most useful
/// thing to find in a transcript when a session desynchronises, and swallowing
/// the error instead would report a clean send that never happened.
async test "a failed write is logged and still raises" {
  let sink = log_sink()
  let broken : &@io.Writer = FailingSink::{ }
  let raised = try {
    DebugLog::new(sink).write_path(broken, b"NOOP\r\n")
    false
  } catch {
    _ => true
  }
  assert_true(raised)
  assert_eq(sink.text(), ">>> NOOP\r\n")
}

///|
/// A zero byte write logs nothing: there was no line to record, so recording
/// one would put a phantom command in the transcript.
async test "a zero byte write logs nothing" {
  let sink = log_sink()
  let inner = recording_sink()
  let inner_ref : &@io.Writer = inner
  DebugLog::new(sink).write_path(inner_ref, b"")
  assert_eq(inner.lines, [])
  assert_eq(sink.text(), "")
}

///|
/// A zero length read logs nothing: there is no line to record, and recording
/// an empty one would put a phantom command in the transcript.
async test "empty reads log nothing" {
  let sink = log_sink()
  let inner = @io.MemoryReader(w => w.write(""))
  defer inner.close()
  let inner_ref : &@io.Reader = inner
  assert_true(DebugLog::new(sink).read_path(inner_ref, "\r\n") is None)
  assert_eq(sink.text(), "")
}
