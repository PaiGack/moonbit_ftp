// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

///|
/// Send `EPSV` (RFC 2428) and return the data port the server opened.
///
/// `229 Entering Extended Passive Mode (|||6446|)`
pub async fn epsv(session : @state.Session) -> Int {
  let response = @control.cmd_expect(session.control(), "EPSV", [
    @status.status_enter_extended_passive_mode,
  ])
  parse_epsv(response.message)
}

///|
/// Extract the port from an `EPSV` reply body.
///
/// The body is expected to contain `|||` followed by the port and a closing
/// `|`. A malformed reply raises `ParseError` instead of silently using port
/// 0, which would otherwise hang the connect.
pub fn parse_epsv(line : String) -> Int raise @error.FtpError {
  let marker = match line.find("|||") {
    Some(marker) => marker
    None =>
      raise @error.FtpError::ParseError(msg="invalid EPSV response: \{line}")
  }
  let start = marker + 3
  let tail = line[start:].to_owned()
  let end = match tail.find("|") {
    Some(end) => end
    None =>
      raise @error.FtpError::ParseError(msg="invalid EPSV response: \{line}")
  }
  guard end > 0 else {
    raise @error.FtpError::ParseError(msg="invalid EPSV response: \{line}")
  }
  let digits = tail[0:end].to_owned()
  guard is_all_digits(digits) else {
    raise @error.FtpError::ParseError(msg="invalid EPSV response: \{line}")
  }
  match parse_port(digits) {
    Some(port) => port
    None =>
      raise @error.FtpError::ParseError(msg="invalid EPSV response: \{line}")
  }
}

///|
/// Whether every byte of `src` is an ASCII digit.
pub fn is_all_digits(src : String) -> Bool {
  guard src != "" else { return false }
  for i = 0; i < src.length(); i = i + 1 {
    let c = src.unsafe_get(i).to_int()
    if c < 48 || c > 57 {
      return false
    }
  }
  true
}

///|
/// Parse a non-empty decimal string into an `Int`, returning `None` on any
/// non-digit byte or on overflow.
pub fn parse_port(digits : String) -> Int? {
  guard digits != "" else { return None }
  let mut value = 0
  for i = 0; i < digits.length(); i = i + 1 {
    let c = digits.unsafe_get(i).to_int()
    if c < 48 || c > 57 {
      return None
    }
    value = value * 10 + (c - 48)
    if value > 65535 {
      return None
    }
  }
  Some(value)
}
