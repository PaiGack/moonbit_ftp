// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

// White box tests for the traffic log (`DebugLog`, `MirrorWriter`,
// `TeeLogReader`) and for the two `Control` hooks that drive it.
//
// The rules these tests lock down, in the order the issue words them:
//
// 1. switch off => byte identical behaviour and zero output, which is what the
//    rest of the suite (and CI) relies on;
// 2. switch on => both directions are recorded whole, a multi line reply
//    included;
// 3. the log never swallows an error and never changes the reply read's
//    deadline -- a sink that raises must not turn a timeout into a success or a
//    command into a failure.
//
// Case 3 is the one with a history in this repo: `read_line` deliberately wraps
// only the socket read in `with_timeout`, so a logging layer written as a
// decorator around the reader would have moved the log inside that deadline.
//
// Every `@io.MemoryReader` here is bound to a name and closed in a `defer`:
// its producer runs in a background task that only `close` stops, and a parked
// producer trips the event loop's deadlock check (AGENTS.md).

///|
/// With no sink installed, `send_line` and `read_line` behave exactly as
/// before: the command is written once, the reply comes back, and nothing
/// anywhere produces output.
async test "a control with no log is silent and unchanged" {
  let (control, sent) = scripted_control("220 ready\r\n")
  assert_false(control.debug_enabled())
  assert_eq(control.read_line(), "220 ready")
  control.send_line("NOOP")
  assert_eq(sent.lines, ["NOOP"])
}

///|
/// Switching the sink on records both directions, tagged and CRLF terminated:
/// the record keeps the framing the wire carries so a transcript can be
/// diffed against a real capture.
async test "an enabled log records commands and replies" {
  let sink = log_sink()
  let log : &@io.Writer = sink
  let reader = @io.MemoryReader(w => w.write("220 ready\r\n"))
  defer reader.close()
  let reader_ref : &@io.Reader = reader
  let (control, _) = logged_control(reader_ref, Some(log))
  assert_true(control.debug_enabled())
  assert_eq(control.read_line(), "220 ready")
  control.send_line("USER anonymous")
  control.send_line("PASS")
  assert_eq(sink.text(), "<<< 220 ready\r\n>>> USER anonymous\r\n>>> PASS\r\n")
}

///|
/// A multi line reply is logged line by line, continuation and terminating
/// `211 End` included: `read_response` reads those lines off `read_line`, so a
/// log that only saw the assembled `Response` would hide the framing that the
/// reply parser's own tests are about.
async test "a multi line reply is logged line by line" {
  let sink = log_sink()
  let log : &@io.Writer = sink
  let reader = @io.MemoryReader(w => {
    w.write("211-Features:\r\n UTF8\r\n211 End\r\n")
  })
  defer reader.close()
  let reader_ref : &@io.Reader = reader
  let (control, _) = logged_control(reader_ref, Some(log))
  let response = read_response(control)
  assert_eq(response.code(), 211)
  assert_eq(response.message(), "Features:\n UTF8\nEnd")
  assert_eq(sink.text(), "<<< 211-Features:\r\n<<<  UTF8\r\n<<< 211 End\r\n")
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
/// The `TeeReader` half: reading through `TeeLogReader` mirrors the bytes into
/// the log, so a caller that only has a reader still gets a transcript.
async test "TeeLogReader mirrors what it reads" {
  let sink = log_sink()
  let inner = @io.MemoryReader(w => w.write("220 ready\r\n"))
  defer inner.close()
  let inner_ref : &@io.Reader = inner
  let tee : &@io.Reader = TeeLogReader::new(inner_ref, log=DebugLog::new(sink))
  assert_eq(tee.read_until("\r\n"), Some("220 ready"))
  assert_eq(sink.text(), "<<< 220 ready\r\n")
}

///|
/// The `MultiWriter` half: writing through `MirrorWriter` forwards to the
/// inner writer *and* logs, which is what the decorator is for.
async test "MirrorWriter forwards and logs" {
  let sink = log_sink()
  let inner = recording_sink()
  let inner_ref : &@io.Writer = inner
  let mirror : &@io.Writer = MirrorWriter::new(
    inner_ref,
    log=DebugLog::new(sink),
  )
  mirror.write("NOOP\r\n")
  assert_eq(inner.lines, ["NOOP"])
  assert_eq(sink.text(), ">>> NOOP\r\n")
}

///|
/// A sink that raises must not make a command fail: the log is a diagnostic,
/// and a broken diagnostic should not take the session with it.
async test "a failing log sink does not fail the command" {
  let reader = @io.MemoryReader(w => w.write("220 ready\r\n"))
  defer reader.close()
  let reader_ref : &@io.Reader = reader
  let (control, sent) = logged_control(reader_ref, Some(FailingSink::{ }))
  control.send_line("NOOP")
  assert_eq(sent.lines, ["NOOP"])
  // ... and the reply still comes back, too.
  assert_eq(control.read_line(), "220 ready")
}

///|
/// A write the inner writer *rejects* is still logged, and the error is
/// re-raised: a command that never reached the wire is the single most useful
/// thing to find in a transcript when a session desynchronises, and swallowing
/// the error instead would report a clean send that never happened.
async test "a failed write is logged and still raises" {
  let sink = log_sink()
  let broken : &@io.Writer = FailingSink::{ }
  let mirror : &@io.Writer = MirrorWriter::new(broken, log=DebugLog::new(sink))
  let raised = try {
    mirror.write("NOOP\r\n")
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
  let mirror = MirrorWriter::new(inner_ref, log=DebugLog::new(sink))
  // `Writer::write` short circuits a zero length payload, so the guard inside
  // `write_once` is only reached by calling it directly -- which is what a
  // caller that drives the trait method itself would do.
  let written = @io.Writer::write_once(mirror, b"", offset=0, len=0)
  assert_eq(written, 0)
  assert_eq(inner.lines, [])
  assert_eq(sink.text(), "")
}

///|
/// A zero length read or write logs nothing: there is no line to record, and
/// recording an empty one would put a phantom command in the transcript.
async test "empty chunks log nothing" {
  let sink = log_sink()
  let inner = @io.MemoryReader(w => w.write(""))
  defer inner.close()
  let inner_ref : &@io.Reader = inner
  let tee : &@io.Reader = TeeLogReader::new(inner_ref, log=DebugLog::new(sink))
  // EOF: `read_until` finds nothing, and the log stays empty.
  assert_true(tee.read_until("\r\n") is None)
  assert_eq(sink.text(), "")
}

///|
/// The deadline stays on the socket read, not on the log: a silent server is
/// still `RequestTimeout` when logging is on, and a sink that raises does not
/// turn that timeout into a success.
async test "logging does not change the reply deadline" {
  let listener = @socket.TcpServer::TcpServer(
    @socket.Addr::parse("127.0.0.1:0"),
  )
  let raised = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (peer, _) = listener.accept()
      @async.sleep(5000)
      peer.close()
    })
    let socket = @socket.Tcp::connect(listener.addr)
    let control = Control::new(socket, socket, "127.0.0.1", timeout_ms=100)
    control.set_debug(Some(DebugLog::new(FailingSink::{ })))
    try {
      ignore(read_response(control))
      "no error"
    } catch {
      FtpError::RequestTimeout => "RequestTimeout"
      err => "other: \{err}"
    }
  })
  assert_eq(raised, "RequestTimeout")
}
