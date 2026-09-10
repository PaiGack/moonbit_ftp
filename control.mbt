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
}

///|
/// Wrap an already connected reader/writer pair.
pub fn Control::new(
  reader : &@io.Reader,
  writer : &@io.Writer,
  host : String,
) -> Control {
  { reader, writer, host, }
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
  self.writer.write(line + "\r\n")
}

///|
/// Read one line, without its trailing CRLF. Raises `ReaderClosed` when the
/// connection was closed before a complete line arrived.
pub async fn Control::read_line(self : Control) -> String {
  match self.reader.read_until("\r\n") {
    Some(line) => line
    None => raise @io.ReaderClosed
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
  expected : Array[Int],
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
  expected : Array[Int],
) -> Response {
  let mut rendered = format
  for arg in args {
    check_for_command_injection(arg)
    rendered = replace_first(rendered, "{}", arg)
  }
  cmd_expect(control, rendered, expected)
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
/// A parsed FTP reply: the numeric status code and the (possibly multi line)
/// message body.
///
/// The body keeps the text of the framing status lines, matching the semantics
/// of Go's `textproto.ReadResponse`; see `read_response` for why the callers
/// depend on that.
pub struct Response {
  /// The 3 digit status code of the reply.
  code : Int
  /// The message, with continuation lines joined by `\n`.
  message : String
} derive(@debug.Debug)

///|
/// Build a reply value.
pub fn Response::new(code : Int, message : String) -> Response {
  { code, message, }
}

///|
/// The status code of the reply.
pub fn Response::code(self : Response) -> Int {
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
pub fn parse_code(line : String) -> Int? {
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
