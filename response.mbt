// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

///|
/// A parsed FTP reply: the numeric status code and the (possibly multi line)
/// message body.
///
/// The body **excludes** the status lines themselves, matching the semantics
/// of Go's `textproto.ReadResponse`.
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
/// The end of a multi line reply is detected exactly like `textproto` does: a
/// line whose first three bytes repeat the code *and* whose fourth byte is not
/// `-`. Getting this wrong makes `FEAT` swallow the reply of the next command,
/// so it has a dedicated test.
pub async fn read_response(control : Control) -> Response {
  let first = control.read_line()
  guard first.length() >= 3 else {
    raise FtpError::ParseError(msg="invalid response line: \{first}")
  }
  let code = match parse_code(first) {
    Some(code) => code
    None => raise FtpError::ParseError(msg="invalid response line: \{first}")
  }
  if is_continuation(first) {
    let body : Array[String] = []
    while true {
      let line = control.read_line()
      if line.length() >= 3 &&
        parse_code(line) == Some(code) &&
        is_continuation(line) == false {
        break
      }
      body.push(line)
    }
    let joined = body.join("\n")
    return { code, message: joined, }
  }
  let message = if first.length() > 4 { first[4:].to_owned() } else { "" }
  { code, message, }
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
