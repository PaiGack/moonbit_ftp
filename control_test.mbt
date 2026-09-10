// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

// Control channel tests.
//
// These used to drive a scripted in-process mock (`@socket.TcpServer` plus a
// hand written reply table). That mock is gone: every end-to-end assertion now
// runs against the real vsftpd started by `scripts/start-ftp.sh`, so the client
// cannot be "helped along" by a server written to agree with it.
//
// What survives here is the half that never needed a server: the pure helpers
// (`parse_features`, `check_for_command_injection`, `parse_code`,
// `is_continuation`) and the reply parser driven over an in-memory reader,
// which lets a malformed frame be constructed exactly. A real daemon cannot be
// asked to emit `200` with no separator or a two line `MLST`, and pretending
// otherwise would mean keeping the mock.
//
// The cases that *could* be moved to a real server live in
// `ftp_server_test.mbt`; see `docs/porting/05-testing.md` section 3 for the
// list of mock-only cases that were dropped and why.

///|
/// A `Control` over an in-memory reader, so a test can feed the reply parser
/// an exact byte sequence without a socket. The writer is a sink: the reply
/// tests only ever read.
fn control_over(text : String) -> Control {
  let reader : &@io.Reader = @io.MemoryReader(writer => writer.write(text))
  let writer : &@io.Writer = DummySink::{ }
  Control::new(reader, writer, "127.0.0.1")
}

///|
/// A writer that discards everything, for the reply-parsing tests that never
/// send a command.
struct DummySink {}

///|
impl @io.Writer for DummySink with fn write_once(
  self : DummySink,
  buf : Bytes,
  offset~ : Int,
  len~ : Int,
) -> Int {
  ignore(self)
  ignore(buf)
  ignore(offset)
  len
}

///|
async test "single line reply splits code from message" {
  let control = control_over("220 FTP Server ready.\r\n")
  let response = read_response(control)
  assert_eq(response.code(), 220)
  assert_eq(response.message(), "FTP Server ready.")
}

///|
async test "multi line reply joins the body and excludes the status lines" {
  let control = control_over("211-Features:\r\n FEAT\r\n PASV\r\n211 End\r\n")
  let response = read_response(control)
  assert_eq(response.code(), 211)
  // Go's `textproto.ReadResponse` keeps the text of the first and of the
  // terminating status line, joined by `\n`. Verified against Go 1.27.
  assert_eq(response.message(), "Features:\n FEAT\n PASV\nEnd")
}

///|
async test "a line repeating the code without a dash is not a continuation" {
  // The trap: `211 End` must terminate the reply, not be collected as body.
  // If the end test were "starts with the code" the body would grow a bogus
  // `End` line and the parser would keep reading into the next reply.
  let control = control_over(
    "211-Features:\r\n UTF8\r\n211 End\r\n200 Two hundred ok\r\n",
  )
  assert_eq(read_response(control).message(), "Features:\n UTF8\nEnd")
  // The follow up reply is still readable, i.e. the parser did not
  // over-consume the stream.
  let next = read_response(control)
  assert_eq(next.code(), 200)
  assert_eq(next.message(), "Two hundred ok")
}

///|
async test "an empty expected list accepts any code" {
  let control = control_over("500 Unknown command\r\n")
  // `expected: []` is the MoonBit spelling of upstream's `cmd(..., -1)`.
  assert_eq(cmd_expect(control, "", []).code(), 500)
}

///|
async test "status mismatch raises ServerError carrying the original message" {
  let control = control_over("550 No such file or directory\r\n")
  let raised = try {
    ignore(cmd_expect(control, "", [200]))
    None
  } catch {
    FtpError::ServerError(code~, msg~) => Some((code, msg))
    _ => None
  }
  assert_eq(raised, Some((550, "No such file or directory")))
}

///|
async test "check_for_command_injection rejects CR and LF" {
  let raised_cr = try {
    check_for_command_injection("a\rb")
    None
  } catch {
    FtpError::InvalidCommand(_) => Some(true)
    _ => None
  }
  assert_eq(raised_cr, Some(true))
  let raised_lf = try {
    check_for_command_injection("a\nb")
    None
  } catch {
    FtpError::InvalidCommand(_) => Some(true)
    _ => None
  }
  assert_eq(raised_lf, Some(true))
}

///|
async test "a code line with no separator is a short response" {
  // `200` alone (three bytes, no space) is rejected by Go's textproto rather
  // than yielding an empty message; `200 ` is a valid empty message.
  let control = control_over("200\r\n")
  let raised = try {
    ignore(read_response(control))
    None
  } catch {
    FtpError::ParseError(msg~) => Some(msg)
    _ => None
  }
  assert_eq(raised, Some("short response: 200"))
}

///|
async test "a bare code plus space yields an empty message" {
  let control = control_over("200 \r\n")
  let response = read_response(control)
  assert_eq(response.code(), 200)
  assert_eq(response.message(), "")
}

///|
async test "a non-numeric first line is a parse error" {
  let control = control_over("HELLO THERE\r\n")
  let raised = try {
    ignore(read_response(control))
    None
  } catch {
    FtpError::ParseError(_) => Some(true)
    _ => None
  }
  assert_eq(raised, Some(true))
}

///|
async test "a multi line reply with a blank body line still collects it" {
  // `211-\r\n\r\n211 End` has an empty continuation line; Go joins it as an
  // empty entry, so the body is `"\n\nEnd"` and the line count stays 3.
  let control = control_over("211-\r\n\r\n211 End\r\n")
  let response = read_response(control)
  assert_eq(response.code(), 211)
  assert_eq(response.message(), "\n\nEnd")
  assert_eq(response.message().split("\n").collect().length(), 3)
}

///|
async test "a two line reply has no room for a body line" {
  // `250-...\n250 End` is the shape an `MLST` reply takes when the server
  // sends no fact line; `get_entry` rejects it because `lines[1:lc-1]` is
  // empty. Constructing it in memory is the only way to reach that branch.
  let control = control_over("250-File details\r\n250 End\r\n")
  let response = read_response(control)
  assert_eq(response.message().split("\n").collect().length(), 2)
}

///|
async test "FEAT parsing ignores the framing lines" {
  // The body carries `Features:` and `End`; both must be filtered out by
  // the leading space test, otherwise `FEATURES:` and `END` would be cached
  // as capabilities and change the negotiation downstream.
  let features = parse_features("Features:\n FEAT\n PASV\n UTF8\nEnd")
  assert_true(features.contains("FEAT"))
  assert_true(features.contains("PASV"))
  assert_true(features.contains("UTF8"))
  assert_false(features.contains("FEATURES:"))
  assert_false(features.contains("END"))
  assert_eq(features.length(), 3)
}

///|
async test "FEAT parsing drops a feature line with no leading space" {
  // A server that omits the RFC-mandated space gets that line ignored, which
  // is exactly what upstream does (it never reaches the trim).
  let features = parse_features("Features:\nFEAT\nEnd")
  assert_false(features.contains("FEAT"))
  assert_false(features.contains("END"))
}

///|
async test "FEAT parsing keeps only the first token of a feature line" {
  // Real vsftpd advertises `REST STREAM`, which must be cached as `REST`, the
  // name the client asks for. Pinned against the live handshake.
  let features = parse_features("Features:\n REST STREAM\n EPRT\nEnd")
  assert_true(features.contains("REST"))
  assert_false(features.contains("REST STREAM"))
  assert_true(features.contains("EPRT"))
}

///|
async test "MLST merges the fact lines of the middle of the reply" {
  let control = control_over(
    "250-File details\r\n Type=file;Size=1024;Modify=20220813133357; lo\r\n250 End\r\n",
  )
  let response = read_response(control)
  assert_eq(response.code(), 250)
  let lines = response.message().split("\n").collect()
  // `<head>\n<facts>\n<tail>`: exactly what upstream slices with
  // `lines[1 : lc-1]`.
  assert_eq(lines.length(), 3)
  assert_eq(
    lines[1].trim_start(),
    "Type=file;Size=1024;Modify=20220813133357; lo",
  )
  let entry = parse_rfc3659_line(lines[1].trim_start().to_owned())
  assert_true(entry is Some(_))
}
