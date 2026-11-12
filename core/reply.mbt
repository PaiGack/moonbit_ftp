// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Package: `PaiGack/ftp/core` — pure values and parsers, no IO.
// frame it.
//
// `Response` is a value: a code and a message, no connection, no IO. The
// reader that assembles it (`read_response`) stays with `Control`, because
// assembling it means reading lines off a socket. Keeping the value here lets
// `control_test` and the parsers check the reply shape without a connection,
// and lets `Connection` and the root package share one reply type.

///|
/// A parsed FTP reply: the numeric status code and the (possibly multi line)
/// message body.
///
/// The body keeps the text of the framing status lines, matching the semantics
/// of Go's `textproto.ReadResponse`; see `read_response` for why the callers
/// depend on that.
#derive(@debug.Debug)
pub struct Response {
  /// The 3 digit status code of the reply.
  code : Int32
  /// The message, with continuation lines joined by `\n`.
  message : String
}

///|
/// `Response` promotes its `Debug` methods as regular methods; declare the
/// promotion explicitly so the deprecation warning stays away.
pub extend Response with @debug.Debug::{to_repr}

///|
/// Build a reply value.
pub fn Response::new(code : Int32, message : String) -> Response {
  { code, message, }
}

///|
/// The status code of the reply.
pub fn Response::code(self : Response) -> Int32 {
  self.code
}

///|
/// The message body of the reply.
pub fn Response::message(self : Response) -> String {
  self.message
}

///|
/// Parse the leading three digits of a reply line.
pub fn parse_code(line : String) -> Int32? {
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
