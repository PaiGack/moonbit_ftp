// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

// Pure tests for the data channel helpers.
//
// The mock used to feed these parsers malformed `PASV` / `EPSV` replies through
// a scripted socket. A real daemon never sends a broken `227` or `229`, so the
// malformed-input branches can only be reached by calling the parsers directly
// — which is all these tests do. No socket, no server.

///|
/// Whether `parse_pasv` refuses the reply.
fn pasv_rejects(line : String) -> Bool {
  ignore(parse_pasv(line)) catch {
    _ => return true
  }
  false
}

///|
test "parse_pasv reads the six numbers" {
  let (ip, port) = parse_pasv("227 Entering Passive Mode (127,0,0,1,196,6)")
  assert_eq(ip, "127.0.0.1")
  // 196 * 256 + 6
  assert_eq(port, 50182)
}

///|
test "parse_pasv rejects a reply with no parentheses" {
  assert_true(pasv_rejects("227 Entering Passive Mode"))
  assert_true(pasv_rejects("227 Entering Passive Mode (127,0,0,1"))
}

///|
test "parse_pasv rejects an empty parenthesised list" {
  assert_true(pasv_rejects("227 Entering Passive Mode ()"))
}

///|
test "parse_pasv rejects fewer than six numbers" {
  assert_true(pasv_rejects("227 Entering Passive Mode (127,0,0,1,196)"))
}

///|
test "parse_pasv rejects a non numeric field" {
  assert_true(pasv_rejects("227 (127,0,0,1,x,6)"))
  assert_true(pasv_rejects("227 (127,0,0,1,256,6)"))
}

///|
/// `parse_epsv` must extract the port between the `|||` markers.
test "parse_epsv reads the port" {
  assert_eq(parse_epsv("229 Entering Extended Passive Mode (|||6446|)"), 6446)
}

///|
test "parse_epsv rejects a malformed reply" {
  let rejects = fn(line : String) -> Bool {
    ignore(parse_epsv(line)) catch {
      _ => return true
    }
    false
  }
  assert_true(rejects("229 Entering Extended Passive Mode"))
  assert_true(rejects("229 (|||6446)"))
  assert_true(rejects("229 (||||)"))
  assert_true(rejects("229 (|||abc|)"))
  assert_true(rejects("229 (|||70000|)"))
}

///|
/// The SSRF guard: a `PASV` answer pointing somewhere else must be refused
/// unless the caller opted in.
test "is_bogus_data_ip refuses multicast" {
  assert_true(is_bogus_data_ip("127.0.0.1", "239.0.0.1"))
}

///|
test "is_bogus_data_ip refuses a private answer to a public peer" {
  assert_true(is_bogus_data_ip("8.8.8.8", "10.0.0.1"))
}

///|
test "is_bogus_data_ip refuses a loopback answer to a public peer" {
  assert_true(is_bogus_data_ip("8.8.8.8", "127.0.0.1"))
}

///|
test "is_bogus_data_ip accepts a matching answer" {
  assert_false(is_bogus_data_ip("127.0.0.1", "127.0.0.1"))
  assert_false(is_bogus_data_ip("8.8.8.8", "8.8.4.4"))
}

///|
/// The IPv6 forms of the SSRF predicates. IPv6 has no dotted quad, so
/// `ip_segments` returns `None` and the prefix rules take over.
test "is_private recognises IPv6 unique local addresses" {
  assert_true(is_private("fc00::1"))
  assert_true(is_private("fd12:3456::1"))
  assert_false(is_private("2001:db8::1"))
}

///|
test "is_loopback recognises IPv6 loopback" {
  assert_true(is_loopback("::1"))
  assert_true(is_loopback("127.0.0.1"))
  assert_false(is_loopback("::2"))
}

///|
test "is_multicast recognises IPv6 multicast" {
  assert_true(is_multicast("ff02::1"))
  assert_true(is_multicast("239.1.1.1"))
  assert_false(is_multicast("192.168.1.1"))
}

///|
test "is_private matches the private IPv4 ranges" {
  assert_true(is_private("10.1.2.3"))
  assert_true(is_private("172.16.0.1"))
  assert_true(is_private("172.31.255.255"))
  assert_true(is_private("192.168.1.1"))
  assert_true(is_private("169.254.1.1"))
  assert_true(is_private("100.64.0.1"))
  assert_false(is_private("172.32.0.1"))
  assert_false(is_private("8.8.8.8"))
}
