// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

///|
/// Send `PASV` and return the `(ip, port)` pair the server advertises.
///
/// `227 Entering Passive Mode (127,0,0,1,196,6)`
pub async fn pasv(session : Session) -> (String, Int) {
  let response = cmd_expect(session.control(), "PASV", [
    status_enter_passive_mode,
  ])
  parse_pasv(response.message())
}

///|
/// Parse the six comma separated numbers of a `PASV` reply into an IP and a
/// port (`port = p1 * 256 + p2`). Fewer than six numbers is an error.
pub fn parse_pasv(line : String) -> (String, Int) raise FtpError {
  let open = match line.find("(") {
    Some(open) => open
    None => raise FtpError::ParseError(msg="invalid PASV response: \{line}")
  }
  let close = match line.find(")") {
    Some(close) => close
    None => raise FtpError::ParseError(msg="invalid PASV response: \{line}")
  }
  guard close > open + 1 else {
    raise FtpError::ParseError(msg="invalid PASV response: \{line}")
  }
  let inner = line[open + 1:close].to_owned()
  let parts = inner.split(",").collect()
  guard parts.length() >= 6 else {
    raise FtpError::ParseError(msg="invalid PASV response: \{line}")
  }
  let numbers : Array[Int] = []
  for i = 0; i < 6; i = i + 1 {
    let text = parts[i].trim().to_owned()
    guard is_all_digits(text) else {
      raise FtpError::ParseError(msg="invalid PASV response: \{line}")
    }
    let value = match parse_octet(text) {
      Some(value) => value
      None => raise FtpError::ParseError(msg="invalid PASV response: \{line}")
    }
    numbers.push(value)
  }
  let ip = "\{numbers[0]}.\{numbers[1]}.\{numbers[2]}.\{numbers[3]}"
  let port = numbers[4] * 256 + numbers[5]
  (ip, port)
}

///|
/// Decide whether the IP returned by `PASV` may be used as the data
/// destination.
///
/// Upstream's rule, kept verbatim: the address is bogus when it is multicast,
/// or when its "privateness" differs from the control connection, or when its
/// loopback-ness differs. This is what makes a server that answers
/// `PASV ... (10,0,0,1,...)` from a public IP unusable unless the caller opts
/// in with `trust_pasv_ip`.
pub fn is_bogus_data_ip(cmd_ip : String, data_ip : String) -> Bool {
  if is_multicast(data_ip) {
    return true
  }
  if is_private(data_ip) != is_private(cmd_ip) {
    return true
  }
  if is_loopback(data_ip) != is_loopback(cmd_ip) {
    return true
  }
  false
}

///|
/// Parse a decimal byte value (0..255), returning `None` otherwise.
pub fn parse_octet(text : String) -> Int? {
  guard text != "" && text.length() <= 3 else { return None }
  let mut value = 0
  for i = 0; i < text.length(); i = i + 1 {
    let c = text.unsafe_get(i).to_int()
    guard c >= 48 && c <= 57 else { return None }
    value = value * 10 + (c - 48)
  }
  guard value <= 255 else { return None }
  Some(value)
}

///|
/// Whether `ip` is a private (RFC 1918 / link local / ULA) address.
pub fn is_private(ip : String) -> Bool {
  match ip_segments(ip) {
    Some(s) =>
      s[0] == 10 ||
      (s[0] == 172 && s[1] >= 16 && s[1] <= 31) ||
      (s[0] == 192 && s[1] == 168) ||
      (s[0] == 169 && s[1] == 254) ||
      (s[0] == 100 && s[1] >= 64 && s[1] <= 127)
    None => ip.to_lower().has_prefix("fc") || ip.to_lower().has_prefix("fd")
  }
}

///|
/// Whether `ip` is a loopback address (`127.0.0.0/8` or `::1`).
pub fn is_loopback(ip : String) -> Bool {
  match ip_segments(ip) {
    Some(s) => s[0] == 127
    None => ip == "::1" || ip.to_lower() == "::1"
  }
}

///|
/// Whether `ip` is a multicast address (`224.0.0.0/4` or `ff00::/8`).
pub fn is_multicast(ip : String) -> Bool {
  match ip_segments(ip) {
    Some(s) => s[0] >= 224 && s[0] <= 239
    None => ip.to_lower().has_prefix("ff")
  }
}

///|
/// Split a dotted quad into four integers, returning `None` for IPv6 or a
/// malformed input.
fn ip_segments(ip : String) -> Array[Int]? {
  let parts = ip.split(".").collect()
  guard parts.length() == 4 else { return None }
  let out : Array[Int] = []
  for part in parts {
    let part = part.to_owned()
    guard is_all_digits(part) else { return None }
    let value = match parse_octet(part) {
      Some(value) => value
      None => return None
    }
    out.push(value)
  }
  Some(out)
}
