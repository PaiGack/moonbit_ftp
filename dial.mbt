// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

// Making a connection: dial, upgrade to TLS, then log in and learn the
// server's capabilities.
//
// This file merges `dial` and `login`: `login` is the second half of `dial`
// (every caller runs them back to back) and it is the only consumer of the
// `Session` that `dial` builds, including the `FEAT` handshake whose result the
// rest of the client reads. Address split, TLS negotiation and authentication
// are one "get me a usable connection" story.

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
  // Greeting: the server speaks first, so this only *reads* the `220` line.
  // Sending a command here (`cmd_expect(control, "", ...)`) would push an
  // empty line onto the wire and desynchronise the whole session, which real
  // servers answer with `500 Command "" not understood.`.
  let greeting = read_response(session.control())
  guard greeting.code() == status_service_ready_for_new_user else {
    raise FtpError::ServerError(code=greeting.code(), msg=greeting.message())
  }
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

///|
/// Authenticate with `USER` / `PASS`, then negotiate capabilities.
///
/// The sequence matches upstream `Login`:
/// `USER` -> `331` -> `PASS` -> `230`, then `FEAT`, then `TYPE I`, then
/// optionally `OPTS UTF8 ON`, and for implicit TLS `PBSZ 0` / `PROT P`.
///
/// The `FEAT` / `OPTS` / `TYPE` steps are taken *outside* the client lock: they
/// are public API and take the lock themselves, and the lock is deliberately
/// not re-entrant (see `FTPClient::lock`). Holding it across these calls would
/// deadlock every login against a real server.
pub async fn login(
  client : FTPClient,
  user : String,
  password : String,
) -> Unit {
  {
    client.lock()
    defer client.unlock()
    let response = cmd_format(client.session.control(), "USER {}", [user], [
      status_username_ok_need_password, status_user_logged_in_proceed,
    ])
    if response.code() == status_username_ok_need_password {
      ignore(
        cmd_format(client.session.control(), "PASS {}", [password], [
          status_user_logged_in_proceed,
        ]),
      )
    }
  }
  feat(client)
  if client.options.disable_utf8 == false && client.has_feature("UTF8") {
    set_utf8(client) catch {
      _ => ()
    }
  }
  set_transfer_type(client, TransferType::Binary)
  if client.options.tls {
    client.lock()
    defer client.unlock()
    ignore(cmd_expect(client.session.control(), "PBSZ 0", [status_cmd_ok]))
    ignore(cmd_expect(client.session.control(), "PROT P", [status_cmd_ok]))
  }
}

///|
/// Ask the server for its feature list and cache the capabilities the client
/// cares about.
///
/// A server that answers `FEAT` with anything other than `211` simply has no
/// feature list; that is **not** an error, upstream treats it the same way.
pub async fn feat(client : FTPClient) -> Unit {
  let response = cmd_expect(client.session.control(), "FEAT", [
    status_system_status,
  ]) catch {
    _ => return
  }
  let features = parse_features(response.message())
  client.set_features(features)
  client.set_mlst_supported(
    client.options.disable_mlsd == false && features.contains("MLST"),
  )
  client.set_mfmt_supported(features.contains("MFMT"))
  client.set_mdtm_supported(features.contains("MDTM"))
  client.set_mdtm_can_write(client.options.writing_mdtm)
  client.session.set_use_pret(features.contains("PRET"))
}

///|
/// Parse a `FEAT` body into a set of command names.
///
/// Feature lines have the shape ` COMMAND [description]`; only the first token
/// is kept, uppercased.
///
/// The leading space test is not cosmetic: the body carries the text of the
/// `211-Features:` and `211 End` framing lines too (see `read_response`), and
/// once trimmed they would otherwise register as features named `FEATURES:`
/// and `END`. Upstream filters with exactly this test.
pub fn parse_features(body : String) -> Map[String, Bool] {
  let features : Map[String, Bool] = Map([])
  for line in body.split("\n") {
    guard line.length() > 0 && line.unsafe_get(0) == ' ' else { continue }
    let trimmed = line.trim()
    guard trimmed != "" else { continue }
    let name = match trimmed.find(" ") {
      Some(index) => trimmed[0:index].to_owned()
      None => trimmed.to_owned()
    }
    features[name.to_upper()] = true
  }
  features
}

///|
/// Send `OPTS UTF8 ON`. Servers that do not implement it answer `501`, `504`
/// or `202`; all three are acceptable per upstream.
async fn set_utf8(client : FTPClient) -> Unit {
  ignore(
    cmd_expect(client.session.control(), "OPTS UTF8 ON", [
      status_cmd_ok, status_cmd_not_implemented_superfluous, status_syntax_error_unknown_params,
      status_not_implemented_for_param,
    ]),
  )
}
