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
/// `docs/porting.md` section 2.4 (API mapping).
///
/// Once connected the client reads the greeting (expecting `220`). When
/// `explicit_tls` is set it then sends `AUTH TLS`, expects `234` and upgrades
/// the control connection.
pub async fn dial(
  addr : String,
  timeout_ms~ : Int32 = default_dial_timeout_ms,
  shut_timeout_ms~ : Int32 = 0,
  tls~ : Bool = false,
  explicit_tls~ : Bool = false,
  trust~ : @tls.TrustedRoot = @tls.TrustedRoot::SystemRoot,
  disable_epsv~ : Bool = false,
  trust_pasv_ip~ : Bool = false,
  disable_utf8~ : Bool = false,
  disable_mlsd~ : Bool = false,
  writing_mdtm~ : Bool = false,
  force_list_hidden~ : Bool = false,
  location~ : @time.Zone = @time.utc_zone,
  debug_sink~ : &@io.Writer? = None,
  now_ms~ : () -> UInt64 = @env.now,
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
    debug_sink,
    now_ms,
  }
  let (host, port) = split_addr(addr, if tls { 990 } else { 21 })
  let socket_addr = @socket.Addr::parse("\{host}:\{port}") catch {
    _ => raise FtpError::ParseError(msg="invalid address: \{addr}")
  }
  // The peer we reached, captured *before* connecting.
  //
  // This address is what the passive data channel dials, and it has to be the
  // peer rather than the name the caller passed (DNS may resolve to several
  // addresses) -- and it cannot come from the connected socket either.
  // `Tcp::addr` is documented as "Get the *local* address of a TCP
  // connection", and this async runtime exposes no peer address on a client
  // socket at all, so reading it there stored *our own* address: on any client
  // that is not on the server's machine, every passive data connection then
  // dialled back to the client itself. The control channel kept working (that
  // one is connected to the right place) and `RETR` / `STOR` / `LIST` all
  // failed with "connection refused" at an address nobody chose. Loopback
  // fixtures cannot see the difference, which is why it shipped.
  //
  // `socket_addr` is the address `Tcp::connect` actually dials, which is what
  // "the peer we reached" means: the resolution decision already made, rather
  // than a second opinion about it.
  let peer_ip = addr_ip_text(socket_addr)
  // The two answers are not the same question. The data channel dials
  // `peer_ip`; the TLS client verifies the certificate against the name the
  // caller used, which is why `Control` keeps them apart.
  let server_name = host
  let tcp = @async.with_timeout(timeout_ms, async fn() {
    @socket.Tcp::connect(socket_addr)
  })
  // Implicit TLS (port 990) is encrypted from the first byte: the `220`
  // greeting itself arrives inside the TLS session, so the handshake has to
  // happen before a single byte is read. Explicit TLS is the opposite and is
  // handled further down, after the plaintext greeting and `AUTH TLS`.
  //
  // `DialOptions.tls` used to only pick the default port, leaving the control
  // connection in the clear: against a real implicit server that reads the
  // TLS handshake as a malformed command line and answers `500`, and the
  // first `read_until` of the greeting blocks on bytes it can never parse.
  let control = if tls {
    let encrypted = @async.with_timeout(timeout_ms, async fn() {
      @tls.Tls::client(tcp, host=server_name, trust~)
    })
    Control::new(encrypted, encrypted, peer_ip, server_name~, timeout_ms~)
  } else {
    Control::new(tcp, tcp, peer_ip, server_name~, timeout_ms~)
  }
  // Attach the traffic log once the connection exists and before the greeting
  // is read, so the first record is what the server said first. Nothing is
  // installed when no sink was asked for.
  control.set_debug(
    match debug_sink {
      None => None
      Some(sink) => Some(@ftplog.DebugLog::new(sink))
    },
  )
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
    auth_tls(client, tcp)
  }
  client
}

///|
/// Split `host` / `host:port` into its two components, applying `default_port`
/// when the caller did not specify one.
pub fn split_addr(addr : String, default_port : Int32) -> (String, Int32) {
  // An IPv6 literal is bracketed -- `[::1]:21`, `[2001:db8::1]` -- and the
  // brackets are *kept* in the returned host, because `@socket.Addr::parse`
  // needs them to tell a literal from a `host:port` pair. Splitting on the
  // first colon instead folded `[::1]:21` into the host `[`, which parses as
  // nothing at all.
  if addr.has_prefix("[") {
    let close = match addr.find("]") {
      Some(close) => close
      None => return (addr, default_port)
    }
    let host = addr[0:close + 1].to_owned()
    let rest = addr[close + 1:].to_owned()
    guard rest.has_prefix(":") else { return (host, default_port) }
    let port = match parse_decimal(rest[1:].to_owned()) {
      Some(port) => port
      None => default_port
    }
    return (host, port)
  }
  // Unbracketed: the *last* colon separates host and port, so an IPv6 literal
  // that was not bracketed keeps its address instead of being cut at the first
  // colon. For a hostname or a dotted quad there is only one colon either way.
  match addr.rev_find(":") {
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
/// The text form of the address `dial` dialled, for the passive data channel.
///
/// `socket_addr.to_string()` is the address in host byte order, which is
/// exactly the text the next `Addr::parse` has to read back -- and it is the
/// only form that survives an IPv6 literal, whose bracketed text has no four
/// octets to spell as a dotted quad.
fn addr_ip_text(socket_addr : @socket.Addr) -> String {
  // `Show` always appends `:port`, so the host is what precedes the last
  // separator; for the bracketed v6 form that separator is the one after `]`.
  // A v6 literal keeps its brackets, which is what the data channel has to
  // dial with.
  let text = socket_addr.to_string()
  if text.has_prefix("[") {
    let close = match text.find("]") {
      Some(close) => close
      None => return text
    }
    return text[0:close + 1].to_owned()
  }
  match text.rev_find(":") {
    Some(index) => text[0:index].to_owned()
    None => text
  }
}

///|
/// Send `AUTH TLS`, expect `234`, then wrap the socket in a TLS session and
/// rebuild the control connection around it.
///
/// The order matters and is the whole point of the command: `234` is the
/// server's promise that *everything after this reply* is TLS. So the reply has
/// to be read off the plaintext connection first, and the client-side handshake
/// can only start once the `234` line has been consumed -- wrapping before
/// would negotiate TLS over a socket whose buffered `234` has not been read
/// yet, and the server would be waiting for a `ClientHello` while the client is
/// still waiting for a reply that is already in its own buffer.
///
/// The upgraded connection is built with `Tls::client`, which owns a *new*
/// reader/writer pair over the same socket (`Control` holds trait objects for
/// exactly this), and `Control::upgrade` swaps them in. Reusing `DialOptions.tls`
/// here would be wrong: that flag means implicit TLS on port 990, where the
/// greeting itself arrives encrypted and no `AUTH TLS` happens at all.
async fn auth_tls(client : FTPClient, socket : @socket.Tcp) -> Unit {
  let control = client.session.control()
  ignore(cmd_expect(control, "AUTH TLS", [status_auth_ok]))
  // `Tls::client` drives a full handshake and blocks on the peer's reply. A
  // peer that answered `234` but never speaks TLS (a broken proxy, a stub, or
  // a server that lied) would otherwise park this task forever -- the timeout
  // turns that into an ordinary failed dial.
  let deadline = client.options.timeout_ms
  let tls = @async.with_timeout(deadline, async fn() {
    @tls.Tls::client(
      socket,
      host=control.server_name(),
      trust=client.options.trust,
    )
  }) catch {
    e =>
      raise FtpError::ServerError(
        code=status_service_unavailable,
        msg="TLS handshake after AUTH TLS failed: \{e}",
      )
  }
  control.upgrade(tls, tls)
}

///|
/// Parse a decimal string into an `Int`, returning `None` on any non-digit.
pub fn parse_decimal(text : String) -> Int32? {
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
/// The sequence matches upstream `Login` command for command:
/// `USER` -> `331` -> `PASS` -> `230`, then `FEAT`, then `TYPE I`, then
/// optionally `OPTS UTF8 ON`, then `PBSZ 0` / `PROT P` for either TLS flavour.
///
/// The `FEAT` / `TYPE` / `OPTS` steps are taken *outside* the client lock:
/// they are public API and take the lock themselves, and the lock is
/// deliberately not re-entrant (see `FTPClient::lock`). Holding it across
/// these calls would deadlock every login against a real server.
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
  // `TYPE I` comes *before* `OPTS UTF8 ON`, which is upstream's order. The two
  // are independent (`TYPE` picks the data representation, `OPTS UTF8` the
  // filename encoding), so reversing them changes nothing a server can see --
  // but it would make this file's "matches upstream" claim false, and the
  // order is exactly what a reader compares against `ftp.go`.
  set_transfer_type(client, TransferType::Binary)
  if client.options.disable_utf8 == false && client.has_feature("UTF8") {
    set_utf8(client) catch {
      _ => ()
    }
  }
  // `PBSZ` / `PROT P` protect the *data* channel, and that is needed for both
  // FTPS flavours: `AUTH TLS` only upgrades the control channel, so an
  // explicit-TLS session that stops there answers every transfer with
  // `550 SSL/TLS required on the data channel.` from a server configured the
  // way RFC 4217 intends (vsftpd's `force_local_data_ssl`). Implicit TLS needs
  // it for the same reason after the greeting: the data connection is still a
  // fresh plaintext socket.
  //
  // Upstream keys this on `dialOpts.TLS` alone, which is why its implicit-only
  // handling looked complete; the explicit path was never wired end to end.
  if client.options.tls || client.options.explicit_tls {
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
