// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

// White box tests for the two pieces of `control.mbt` that need the shared
// fixtures: `Control::upgrade` swaps in a `RecordingSink` (a package private
// type), and `read_response` / `render_command` are exercised against the same
// scripted reader the reply tests use.
//
// The reply parser's *shapes* are covered by `control_test.mbt`; what is
// checked here is the upgrade seam and the substitution helper that the `PRET`
// handshake now shares.

///|
/// `Control::upgrade` swaps both directions of the connection in place, which
/// is how `AUTH TLS` is meant to replace the plain socket with a TLS session.
/// The reader/writer are trait objects precisely so this works.
async test "Control::upgrade swaps the reader and writer in place" {
  let control = scripted_control_no_over("220 first\r\n")
  assert_eq(read_response(control).code(), 220)

  // Point the same `Control` at a second in-memory reader and a recording
  // writer; both halves must follow.
  let replacement : &@io.Reader = @io.MemoryReader(writer => {
    writer.write("221 second\r\n")
  })
  let sink = recording_sink()
  let writer : &@io.Writer = sink
  Control::upgrade(control, replacement, writer)
  assert_eq(read_response(control).message(), "second")
  Control::send_line(control, "NOOP")
  assert_eq(sink.lines, ["NOOP"])
}

///|
/// `Response::new` is the value constructor the parsers hand back; its
/// accessors must return the two fields verbatim.
test "Response::new and its accessors agree" {
  let response = Response::new(550, "No such file or directory")
  assert_eq(response.code(), 550)
  assert_eq(response.message(), "No such file or directory")
  // An empty message is legitimate: `200 ` carries no text.
  let empty = Response::new(200, "")
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
    ignore(read_response(control))
    None
  } catch {
    FtpError::ParseError(msg~) => Some(msg)
    _ => None
  }
  assert_eq(raised, Some("short response: 211"))
}

///|
/// `parse_code` needs three digits, so a two digit line and a letter are both
/// rejected; `is_continuation` needs a `-` in the fourth byte.
test "parse_code and is_continuation handle the boundaries" {
  assert_eq(parse_code("220 Service ready"), Some(220))
  assert_eq(parse_code("999"), Some(999))
  assert_true(parse_code("22") is None)
  assert_true(parse_code("") is None)
  assert_true(parse_code("2x0 ok") is None)
  assert_true(is_continuation("211-Features:"))
  assert_false(is_continuation("211 Features:"))
  assert_false(is_continuation("211"))
}

///|
/// `replace_first` backs the `{}` substitution, and the `PRET` handshake now
/// shares it through `render_command`. A format with no placeholder is
/// returned unchanged rather than being mangled.
test "render_command substitutes the first placeholder only" {
  assert_eq(render_command("RETR {}", ["/a.txt"]), "RETR /a.txt")
  // Only the first `{}` is replaced, matching `cmd_format`.
  assert_eq(
    render_command("MFMT {} {}", ["20240102030405", "/a.txt"]),
    "MFMT 20240102030405 /a.txt",
  )
  assert_eq(render_command("NOOP", []), "NOOP")
  // Extra args with no placeholder left are ignored, not appended.
  assert_eq(render_command("PWD", ["ignored"]), "PWD")
}

///|
/// `render_command` validates its arguments before substituting, so a crafted
/// path cannot smuggle a second command into the `PRET` preview either.
test "render_command refuses a CR or LF in an argument" {
  let raised = try {
    ignore(render_command("RETR {}", ["/a\r\nDELE /b"]))
    None
  } catch {
    FtpError::InvalidCommand(_) => Some(true)
    _ => None
  }
  assert_eq(raised, Some(true))
}

///|
/// A `Control` over an in-memory reader with a discarding writer, the
/// white box twin of `control_over` in `control_test.mbt` (that one is a
/// blackbox helper and is not visible from this target).
fn scripted_control_no_over(text : String) -> Control {
  let reader : &@io.Reader = @io.MemoryReader(writer => writer.write(text))
  let writer : &@io.Writer = NullSink::{ }
  Control::new(reader, writer, "127.0.0.1")
}

///|
/// A writer that discards everything.
struct NullSink {}

///|
impl @io.Writer for NullSink with fn write_once(
  self : NullSink,
  buf : Bytes,
  offset~ : Int,
  len~ : Int,
) -> Int {
  ignore(self)
  ignore(buf)
  ignore(offset)
  len
}
