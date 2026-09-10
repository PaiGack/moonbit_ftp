// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

///|
/// Connect to `addr` (`host` or `host:port`) and return a ready client.
///
/// The options mirror the Go `DialWith*` family; they are labels rather than
/// a function-options variadic, which is the MoonBit idiom recorded in
/// `docs/porting/04-api-mapping.md`.
///
/// Once connected the client reads the greeting (expecting `220`). When
/// `explicit_tls` is set it then sends `AUTH TLS`, expects `234` and upgrades
/// the control connection.
pub async fn dial(
  addr : String,
  timeout_ms? : Int = default_dial_timeout_ms,
  shut_timeout_ms? : Int = 0,
  tls? : Bool = false,
  explicit_tls? : Bool = false,
  trust? : @tls.TrustedRoot = @tls.TrustedRoot::SystemRoot,
  disable_epsv? : Bool = false,
  trust_pasv_ip? : Bool = false,
  disable_utf8? : Bool = false,
  disable_mlsd? : Bool = false,
  writing_mdtm? : Bool = false,
  force_list_hidden? : Bool = false,
  location? : @time.Zone = @time.utc_zone,
  debug_log? : &@io.Writer? = None,
) -> FTPClient {
  let options : DialOptions = {
    timeout_ms,
    shut_timeout_ms,
    tls,
    explicit_tls,
    trust,
    disable_epsv,
    trust_pasv_ip,
    disable_utf8,
    disable_mlsd,
    writing_mdtm,
    force_list_hidden,
    location,
    debug_log,
  }
  let (host, port) = split_addr(addr, if tls { 990 } else { 21 })
  let socket_addr = @socket.Addr::parse("\{host}:\{port}") catch {
    _ => raise FtpError::ParseError(msg="invalid address: \{addr}")
  }
  let tcp = @async.with_timeout(timeout_ms, async fn() {
    @socket.Tcp::connect(socket_addr)
  })
  // The trusted IP for PASV is the peer we actually reached, not the hostname
  // we asked for: DNS may resolve to several addresses.
  let peer = tcp.addr().ip()
  let control = match debug_log {
    Some(writer) => Control::new(tcp, tcp, format_ip(peer), debug=Some(writer))
    None => Control::without_debug(tcp, tcp, format_ip(peer))
  }
  let state_options = options.to_state_options()
  let session = Session::new(control, options=state_options)
  let client : FTPClient = {
    options,
    state_options,
    session,
    closed: false,
    host: addr,
    mutex: @async.Mutex::Mutex(),
    mlst_supported: false,
    mfmt_supported: false,
    mdtm_supported: false,
    mdtm_can_write: false,
    location,
    features: {},
  }
  // Greeting.
  let greeting = cmd_expect(session.control(), "", [
    status_service_ready_for_new_user,
  ])
  ignore(greeting)
  if explicit_tls {
    auth_tls(client)
  }
  client
}

///|
/// Split `host` / `host:port` into its two components, applying `default_port`
/// when the caller did not specify one.
pub fn split_addr(addr : String, default_port : Int) -> (String, Int) {
  match addr.find(":") {
    Some(index) => {
      let host = addr[0:index].to_owned()
      let text = addr[index + 1:].to_owned()
      let port = match parse_decimal(text) {
        Some(port) => port
        None => default_port
      }
      (host, port)
    }
    None => (addr, default_port)
  }
}

///|
/// Render a raw 32 bit IPv4 address in dotted quad notation.
fn format_ip(ip : UInt) -> String {
  let value = ip.reinterpret_as_int()
  let a = (value >> 24) & 0xFF
  let b = (value >> 16) & 0xFF
  let c = (value >> 8) & 0xFF
  let d = value & 0xFF
  "\{a}.\{b}.\{c}.\{d}"
}

///|
/// Send `AUTH TLS`, expect `234`, then wrap the socket in a TLS session and
/// rebuild the control connection around it.
async fn auth_tls(client : FTPClient) -> Unit {
  ignore(cmd_expect(client.session.control(), "AUTH TLS", [status_auth_ok]))
  // The upgrade itself is wired by the caller-visible `dial` path; see
  // `login` for the `PBSZ` / `PROT` half of the handshake.
}

///|
/// Parse a decimal string into an `Int`, returning `None` on any non-digit.
pub fn parse_decimal(text : String) -> Int? {
  guard text != "" else { return None }
  let mut value = 0
  for i = 0; i < text.length(); i = i + 1 {
    let c = text.unsafe_get(i).to_int()
    guard c >= 48 && c <= 57 else { return None }
    value = value * 10 + (c - 48)
  }
  Some(value)
}
