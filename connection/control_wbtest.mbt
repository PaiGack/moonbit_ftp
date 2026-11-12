// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

// White box tests for the two pieces of `control.mbt` that need the shared
// fixtures: `@connection.Control::upgrade` swaps in a `RecordingSink` (a package private
// type), and `@connection.read_response` / `@connection.render_command` are exercised against the same
// scripted reader the reply tests use.
//
// The reply parser's *shapes* are covered by `control_test.mbt`; what is
// checked here is the upgrade seam and the substitution helper that the `PRET`
// handshake now shares.

///|
/// `@connection.Control::upgrade` swaps both directions of the connection in place, which
/// is how `AUTH TLS` is meant to replace the plain socket with a TLS session.
/// The reader/writer are trait objects precisely so this works.
async test "@connection.Control::upgrade swaps the reader and writer in place" {
  let control = scripted_control_no_over("220 first\r\n")
  assert_eq(@connection.read_response(control).code(), 220)

  // Point the same `@connection.Control` at a second in-memory reader and a recording
  // writer; both halves must follow.
  let replacement : &@io.Reader = @io.MemoryReader(writer => {
    writer.write("221 second\r\n")
  })
  let sink = recording_sink()
  let writer : &@io.Writer = sink
  @connection.Control::upgrade(control, replacement, writer)
  assert_eq(@connection.read_response(control).message(), "second")
  @connection.Control::send_line(control, "NOOP")
  assert_eq(sink.lines, ["NOOP"])
}

///|
/// `@core.Response::new` is the value constructor the parsers hand back; its
/// accessors must return the two fields verbatim.
test "@core.Response::new and its accessors agree" {
  let response = @core.Response::new(550, "No such file or directory")
  assert_eq(response.code(), 550)
  assert_eq(response.message(), "No such file or directory")
  // An empty message is legitimate: `200 ` carries no text.
  let empty = @core.Response::new(200, "")
  assert_eq(empty.code(), 200)
  assert_eq(empty.message(), "")
}

///|
/// A multi line reply whose *terminating* line is a bare three digit code (no
/// separator) is a `short response`, not a body line: accepting it would lose
/// the end-of-reply signal and desynchronise every later read.
async test "a short terminating line is rejected" {
  let control = scripted_control_no_over("211-Features:\r\n UTF8\r\n211\r\n")
  let raised = try {
    ignore(@connection.read_response(control))
    None
  } catch {
    @core.FtpError::ParseError(msg~) => Some(msg)
    _ => None
  }
  assert_eq(raised, Some("short response: 211"))
}

///|
/// `@core.parse_code` needs three digits, so a two digit line and a letter are both
/// rejected; `@core.is_continuation` needs a `-` in the fourth byte.
test "@core.parse_code and @core.is_continuation handle the boundaries" {
  assert_eq(@core.parse_code("220 Service ready"), Some(220))
  assert_eq(@core.parse_code("999"), Some(999))
  assert_true(@core.parse_code("22") is None)
  assert_true(@core.parse_code("") is None)
  assert_true(@core.parse_code("2x0 ok") is None)
  assert_true(@core.is_continuation("211-Features:"))
  assert_false(@core.is_continuation("211 Features:"))
  assert_false(@core.is_continuation("211"))
}

///|
/// `replace_first` backs the `{}` substitution, and the `PRET` handshake now
/// shares it through `@connection.render_command`. A format with no placeholder is
/// returned unchanged rather than being mangled.
test "@connection.render_command substitutes the first placeholder only" {
  assert_eq(@connection.render_command("RETR {}", ["/a.txt"]), "RETR /a.txt")
  // Only the first `{}` is replaced, matching `@connection.cmd_format`.
  assert_eq(
    @connection.render_command("MFMT {} {}", ["20240102030405", "/a.txt"]),
    "MFMT 20240102030405 /a.txt",
  )
  assert_eq(@connection.render_command("NOOP", []), "NOOP")
  // Extra args with no placeholder left are ignored, not appended.
  assert_eq(@connection.render_command("PWD", ["ignored"]), "PWD")
}

///|
/// `@connection.render_command` validates its arguments before substituting, so a crafted
/// path cannot smuggle a second command into the `PRET` preview either.
test "@connection.render_command refuses a CR or LF in an argument" {
  let raised = try {
    ignore(@connection.render_command("RETR {}", ["/a\r\nDELE /b"]))
    None
  } catch {
    @core.FtpError::InvalidCommand(_) => Some(true)
    _ => None
  }
  assert_eq(raised, Some(true))
}

///|
/// A `@connection.Control` over an in-memory reader with a discarding writer, the
/// white box twin of `control_over` in `control_test.mbt` (that one is a
/// blackbox helper and is not visible from this target).
fn scripted_control_no_over(
  text : String,
) -> @connection.Control raise @core.FtpError {
  let reader : &@io.Reader = @io.MemoryReader(writer => writer.write(text))
  let writer : &@io.Writer = NullSink::{ }
  @connection.Control::new(reader, writer, "127.0.0.1")
}

///|
/// A writer that discards everything.
struct NullSink {}

///|
impl @io.Writer for NullSink with fn write_once(
  self : NullSink,
  buf : Bytes,
  offset~ : Int32,
  len~ : Int32,
) -> Int32 {
  ignore(self)
  ignore(buf)
  ignore(offset)
  len
}

///|
/// A silent server fails with `RequestTimeout` instead of parking forever.
///
/// This is the regression test for the CI failure that made the whole suite
/// abort with "Dead lock detected": the reply read had no deadline, so a
/// server that did not answer left the only live task parked on the control
/// socket. The async runtime reports a fully parked loop as a deadlock and
/// aborts the process, naming whichever *other* task happened to be parked —
/// so the failure named a `MemoryReader` two files away from the real stall.
/// With a deadline the wait is bounded and the error names the wait.
async test "@connection.read_response times out on a silent server" {
  let listener = @socket.TcpServer::TcpServer(
    @socket.Addr::parse("127.0.0.1:0"),
  )
  let raised = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      // Accept the connection, then never say anything.
      let (peer, _) = listener.accept()
      @async.sleep(5000)
      peer.close()
    })
    let socket = @socket.Tcp::connect(listener.addr)
    // 100 ms is far below the 5 s the peer stays silent.
    let control = @connection.Control::new(
      socket,
      socket,
      "127.0.0.1",
      timeout_ms=100,
    )
    let result = try {
      ignore(@connection.read_response(control))
      "no error"
    } catch {
      @core.FtpError::RequestTimeout => "RequestTimeout"
      err => "other: \{err}"
    }
    result
  })
  assert_eq(raised, "RequestTimeout")
}

///|
/// `timeout_ms = 0` keeps the deadline off, which is the default every
/// in-package fixture relies on: a scripted reader has no peer to time out
/// against and must still answer.
async test "a zero deadline leaves the reply read unbounded" {
  let control = @connection.Control::new(
    @io.MemoryReader(writer => writer.write("220 ready\r\n")),
    NullSink::{ },
    "127.0.0.1",
  )
  assert_eq(@connection.read_response(control).code(), 220)
}

///|
/// A reply line over the cap is refused instead of allocated. `read_until`
/// has no size bound of its own: a peer that never sends CRLF keeps its
/// buffer growing for as long as it keeps writing, and the per-read idle
/// deadline never fires because every read completes.
async test "@connection.read_line refuses an oversized reply line" {
  // An in-memory reader with no `\r\n` at all: a socket peer would need a
  // deadline in the seconds to deliver 64 KiB of a single line, which makes
  // the test slower than the behaviour it pins.
  let text = StringBuilder()
  for i = 0; i <= @core.max_reply_line_bytes; i = i + 1 {
    text.write_char('a')
  }
  let reader = @io.MemoryReader(writer => writer.write(text.to_string()))
  defer reader.close()
  let control = @connection.Control::new(
    reader,
    NullSink::{ },
    "127.0.0.1",
    timeout_ms=5000,
  )
  let raised = try {
    ignore(@connection.read_response(control))
    "no error"
  } catch {
    @core.FtpError::ParseError(msg~) => "ParseError: \{msg}"
    err => "other: \{err}"
  }
  assert_true(raised.has_prefix("ParseError: reply line exceeds"))
}

///|
/// A multi-line reply that never terminates is bounded by `max_reply_lines`.
/// Each line arrives and completes, so the per-line deadline never fires; only
/// a limit on how many lines one reply may carry stops the loop.
async test "@connection.read_response bounds the number of continuation lines" {
  let line = "211-continuation\r\n"
  let endless = StringBuilder()
  // One more than the cap, all well under the per-line size bound.
  for i = 0; i <= @core.max_reply_lines; i = i + 1 {
    endless.write(line)
  }
  let control = scripted_control_no_over(endless.to_string())
  let raised = try {
    ignore(@connection.read_response(control))
    "no error"
  } catch {
    @core.FtpError::ParseError(msg~) => "ParseError: \{msg}"
    err => "other: \{err}"
  }
  assert_true(raised.has_prefix("ParseError: reply exceeds"))
}
