// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

// The data channel: everything between "a transfer was requested" and "the
// socket is open".
//
// This file merges what used to be three files (`transport_pasv`,
// `transport_epsv`, `transport_dataconn`). They were always one concern —
// opening the passive data connection — and were only split by which RFC the
// command came from, which is a poor reason to make a reader jump between
// files. `get_data_port` below is the seam that ties `PASV` and `EPSV`
// together, and `open_data_conn` / `cmd_data_conn_from` are its only callers.

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

///|
/// Send `EPSV` (RFC 2428) and return the data port the server opened.
///
/// `229 Entering Extended Passive Mode (|||6446|)`
pub async fn epsv(session : Session) -> Int {
  let response = cmd_expect(session.control(), "EPSV", [
    status_enter_extended_passive_mode,
  ])
  parse_epsv(response.message())
}

///|
/// Extract the port from an `EPSV` reply body.
///
/// The body is expected to contain `|||` followed by the port and a closing
/// `|`. A malformed reply raises `ParseError` instead of silently using port
/// 0, which would otherwise hang the connect.
pub fn parse_epsv(line : String) -> Int raise FtpError {
  let marker = match line.find("|||") {
    Some(marker) => marker
    None => raise FtpError::ParseError(msg="invalid EPSV response: \{line}")
  }
  let start = marker + 3
  let tail = line[start:].to_owned()
  let end = match tail.find("|") {
    Some(end) => end
    None => raise FtpError::ParseError(msg="invalid EPSV response: \{line}")
  }
  guard end > 0 else {
    raise FtpError::ParseError(msg="invalid EPSV response: \{line}")
  }
  let digits = tail[0:end].to_owned()
  guard is_all_digits(digits) else {
    raise FtpError::ParseError(msg="invalid EPSV response: \{line}")
  }
  match parse_port(digits) {
    Some(port) => port
    None => raise FtpError::ParseError(msg="invalid EPSV response: \{line}")
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

///|
/// The data connection used for one transfer.
pub struct DataConn {
  /// Reads the payload coming from the server.
  reader : &@io.Reader
  /// Writes the payload going to the server.
  writer : &@io.Writer
  /// Closes the socket, keeping the raw connection alive for the 226 read.
  closer : () -> Unit
}

///|
/// The readable end of the data connection.
pub fn DataConn::reader(self : DataConn) -> &@io.Reader {
  self.reader
}

///|
/// The writable end of the data connection.
pub fn DataConn::writer(self : DataConn) -> &@io.Writer {
  self.writer
}

///|
/// Close the data connection without touching the control channel.
pub fn DataConn::close(self : DataConn) -> Unit {
  (self.closer)()
}

///|
/// Get the port to connect to, preferring `EPSV` and permanently falling back
/// to `PASV` after the first failure.
///
/// The "EPSV failed once, never try again" behaviour is a deliberate upstream
/// design choice: some servers answer `EPSV` with an error but also with a
/// malformed `PASV` reply, and retrying `EPSV` on every transfer turns a fast
/// failure into a timeout per file.
pub async fn get_data_port(session : Session) -> (String, Int) {
  if session.options().disable_epsv() == false && session.skip_epsv() == false {
    let port = epsv(session) catch {
      _ => {
        session.set_skip_epsv(true)
        return pasv(session)
      }
    }
    return (session.control().host(), port)
  }
  let (ip, port) = pasv(session)
  // SSRF guard: use the control connection IP unless the caller explicitly
  // trusts the server's answer *and* the answer is not obviously bogus.
  if session.options().trust_pasv_ip() &&
    is_bogus_data_ip(session.control().host(), ip) == false {
    return (ip, port)
  }
  (session.control().host(), port)
}

///|
/// Open the passive data connection.
///
/// With TLS the socket is connected but the handshake is deferred to the first
/// read/write: ProFTPD and PureFTPD both refuse a data connection that starts
/// its handshake before the transfer command was answered.
pub async fn open_data_conn(session : Session) -> DataConn {
  let (ip, port) = get_data_port(session)
  let addr = @socket.Addr::parse("\{ip}:\{port}") catch {
    _ =>
      raise FtpError::ParseError(
        msg="invalid data connection address: \{ip}:\{port}",
      )
  }
  let tcp = @async.with_timeout(session.options().timeout_ms(), async fn() {
    @socket.Tcp::connect(addr)
  })
  if session.options().tls() {
    let tls = @tls.Tls::client(
      tcp,
      host=session.control().host(),
      trust=session.options().trust(),
    )
    return { reader: tls, writer: tls, closer: () => tls.close(), }
  }
  { reader: tcp, writer: tcp, closer: () => tcp.close(), }
}

///|
/// Open a data connection and start a transfer command on it.
///
/// This is the heart of the data channel and follows upstream
/// `cmdDataConnFrom` step by step:
///
/// 1. `PRET <cmd>` first when the server advertised `PRET`,
/// 2. open the data connection,
/// 3. `REST <offset>` when a resume offset was given, expecting `350`,
/// 4. send the transfer command, expecting `125` or `150`,
/// 5. on a non 2xx answer, close the data connection before raising.
pub async fn cmd_data_conn_from(
  session : Session,
  offset : Int64,
  cmd : String,
  args : Array[String],
) -> DataConn {
  if session.use_pret() {
    let _ = try {
      ignore(
        cmd_expect(session.control(), "PRET \{cmd}", [
          status_cmd_ok, status_file_action_pending_further_info,
        ]),
      )
      true
    } catch {
      _ => false
    }
  }
  let conn = open_data_conn(session)
  if offset != 0 {
    let ok = try {
      ignore(
        cmd_format(session.control(), "REST {}", ["\{offset}"], [
          status_file_action_pending_further_info,
        ]),
      )
      true
    } catch {
      _ => false
    }
    guard ok else {
      conn.close()
      raise FtpError::ParseError(msg="REST command failed")
    }
  }
  let response = cmd_format(session.control(), cmd, args, [
    status_data_conn_already_in_use, 150,
  ]) catch {
    _ => {
      conn.close()
      raise FtpError::ParseError(msg="transfer command failed")
    }
  }
  // The reply that starts a transfer is a *positive intermediate* (`125` or
  // `150`), not a completion: `2xx` only arrives at the end, on `226`. Testing
  // `is_positive_completion` here rejected every real transfer.
  guard is_positive_intermediate(response.code()) else {
    conn.close()
    raise FtpError::ServerError(code=response.code(), msg=response.message())
  }
  conn
}
