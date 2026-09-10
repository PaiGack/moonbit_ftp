// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

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
