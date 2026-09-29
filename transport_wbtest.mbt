// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

// Tests for the data channel negotiation in `transport.mbt`.
//
// `parse_pasv` / `parse_epsv` are pure and covered by `transport_test.mbt`.
// What is left is the *sequence*: when does the client send `EPSV` versus
// `PASV`, when does it give up on `EPSV` for the rest of the session, when is
// `PRET` sent and what happens when the server refuses it, and which status
// code ends the negotiation. All of it is command/response work over a
// scripted control channel plus a real loopback data listener, which is what
// `ftp_test_helpers_wbtest.mbt` provides.

///|
/// A loopback listener whose port is advertised in a `PASV` reply. The reply
/// points at `127.0.0.1`, which is the address the SSRF guard compares against
/// the peer of the scripted control channel.
async test "get_data_port falls back to PASV when EPSV is refused" {
  let listener = data_listener()
  let port = listener.addr.port()
  let (session, sink) = scripted_session(
    "500 EPSV not understood.\r\n" + pasv_reply(port),
  )
  let (ip, port) = get_data_port(session) catch { _ => fail("get_data_port") }
  assert_eq(sink.lines, ["EPSV", "PASV"])
  // The `PASV` answer's IP is ignored (the SSRF guard) and the control
  // channel's host is used instead.
  assert_eq(ip, "127.0.0.1")
  assert_eq(port, listener.addr.port())
  // The failure latched, so the *next* transfer skips EPSV entirely.
  assert_true(session.skip_epsv())
}

///|
/// `disable_epsv` is the caller saying "never send EPSV"; the first transfer
/// must already go through `PASV`.
async test "get_data_port honours disable_epsv from the first transfer" {
  let listener = data_listener()
  let port = listener.addr.port()
  let options = Options::new(
    true,
    false,
    false,
    default_dial_timeout_ms,
    0,
    @tls.TrustedRoot::SystemRoot,
  )
  let (session, sink) = scripted_session(pasv_reply(port), options~)
  let (ip, port) = get_data_port(session) catch { _ => fail("get_data_port") }
  assert_eq(sink.lines, ["PASV"])
  assert_eq(ip, "127.0.0.1")
  assert_eq(port, listener.addr.port())
}

///|
/// `trust_pasv_ip` opts out of the SSRF guard, so the address the server
/// advertises is used verbatim — but only when it is not obviously bogus.
async test "get_data_port trusts the PASV answer when asked" {
  let listener = data_listener()
  let port = listener.addr.port()
  let options = Options::new(
    true,
    true,
    false,
    default_dial_timeout_ms,
    0,
    @tls.TrustedRoot::SystemRoot,
  )
  let (session, _) = scripted_session(pasv_reply(port), options~)
  let (ip, port) = get_data_port(session) catch { _ => fail("get_data_port") }
  assert_eq(ip, "127.0.0.1")
  assert_eq(port, listener.addr.port())
}

///|
/// A `PASV` answer pointing at a *different* private host is refused even with
/// `trust_pasv_ip` set: the address is bogus, so the control host wins.
async test "get_data_port refuses a bogus PASV answer even when trusting" {
  let options = Options::new(
    true,
    true,
    false,
    default_dial_timeout_ms,
    0,
    @tls.TrustedRoot::SystemRoot,
  )
  // The scripted control channel's peer is `127.0.0.1`; the reply advertises a
  // public address, so the loopback-ness differs and the guard fires.
  let (session, _) = scripted_session(
    "227 Entering Passive Mode (8,8,8,8,196,6)\r\n",
    options~,
  )
  let (ip, port) = get_data_port(session) catch { _ => fail("get_data_port") }
  assert_eq(ip, "127.0.0.1")
  assert_eq(port, 50182)
}

///|
/// A refused `EPSV` followed by a refused `PASV` raises instead of connecting
/// to a bogus address.
async test "get_data_port raises when both EPSV and PASV fail" {
  let (session, sink) = scripted_session(
    "500 EPSV not understood.\r\n500 PASV not understood.\r\n",
  )
  let raised = try {
    ignore(get_data_port(session))
    None
  } catch {
    FtpError::ServerError(code~, ..) => Some(code)
    _ => None
  }
  assert_eq(raised, Some(500))
  assert_eq(sink.lines, ["EPSV", "PASV"])
}

///|
/// `open_data_conn` connects to the advertised port for real, so the whole
/// `EPSV` -> connect path is exercised against a socket.
async test "open_data_conn connects to the EPSV port" {
  let listener = data_listener()
  let port = listener.addr.port()
  let (session, _) = scripted_session(epsv_reply(port))
  let (conn, received) = @async.with_task_group(async fn(group) {
    let server = group.spawn(no_wait=true, async fn() {
      let (peer, _) = listener.accept()
      let payload = peer.read_all() catch { _ => empty_data() }
      peer.close()
      payload.text() catch {
        _ => ""
      }
    })
    let conn = open_data_conn(session) catch { _ => fail("open_data_conn") }
    conn.writer().write("hello")
    conn.close()
    (conn, server.wait())
  })
  ignore(conn)
  assert_eq(received, "hello")
}

///|
/// The data-channel TLS handshake is *deferred*: `open_data_conn` only connects
/// the socket, and the handshake runs later in `DataConn::start_tls`.
///
/// This is the regression test for the FTPS ordering bug. `open_data_conn` used
/// to call `Tls::client` eagerly, i.e. before the transfer command was sent, so
/// against a real ftpd the client wrote a `ClientHello` into a socket the server
/// had not started reading and every transfer died with
/// `425 Unable to build data connection`. The observable consequence is the one
/// asserted here: after `open_data_conn` with TLS enabled, no TLS session exists
/// yet.
async test "open_data_conn defers the TLS handshake until start_tls" {
  let listener = data_listener()
  let port = listener.addr.port()
  let options = Options::new(
    false,
    false,
    true,
    default_dial_timeout_ms,
    0,
    @tls.TrustedRoot::SystemRoot,
  )
  let (session, sink) = scripted_session(epsv_reply(port), options~)
  let tls_started = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (peer, _) = listener.accept()
      peer.close()
    })
    let conn = open_data_conn(session) catch { _ => fail("open_data_conn") }
    let started = conn.tls is Some(_)
    conn.close()
    started
  })
  assert_false(tls_started)
  // The only commands on the wire are the passive-mode negotiation: nothing
  // was sent for the handshake, because nothing was attempted.
  assert_eq(sink.lines, ["EPSV"])
}

///|
/// `PRET` is only sent when the server advertised it, and the transfer command
/// follows it.
async test "cmd_data_conn_from sends PRET when the server supports it" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = "200 PRET command okay.\r\n" +
    epsv_reply(port) +
    "150 Opening BINARY mode data connection.\r\n"
  let (session, sink) = scripted_session(script)
  session.set_use_pret(true)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (peer, _) = listener.accept()
      peer.close()
    })
    let conn = cmd_data_conn_from(session, 0, "RETR {}", ["/a.txt"]) catch {
      _ => fail("cmd_data_conn_from")
    }
    conn.close()
    ()
  })
  assert_eq(sink.lines, ["PRET RETR /a.txt", "EPSV", "RETR /a.txt"])
}

///|
/// A server that refuses `PRET` is not an error: the flag was optimistic, the
/// transfer goes ahead without it. That is upstream's `try { ... } catch`.
async test "cmd_data_conn_from tolerates a refused PRET" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = "500 PRET not understood.\r\n" +
    epsv_reply(port) +
    "150 Opening BINARY mode data connection.\r\n"
  let (session, sink) = scripted_session(script)
  session.set_use_pret(true)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (peer, _) = listener.accept()
      peer.close()
    })
    let conn = cmd_data_conn_from(session, 0, "RETR {}", ["/a.txt"]) catch {
      _ => fail("cmd_data_conn_from")
    }
    conn.close()
    ()
  })
  assert_eq(sink.lines, ["PRET RETR /a.txt", "EPSV", "RETR /a.txt"])
}

///|
/// A status code outside the accepted set (`125` / `150`) is turned into a
/// `ParseError`: the command was refused, and the caller gets a stable
/// "transfer command failed" rather than the server's raw code — the same
/// treatment `REST` gets below.
async test "cmd_data_conn_from reports a refused transfer command" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) + "550 No such file.\r\n"
  let (session, sink) = scripted_session(script)
  let message = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (peer, _) = listener.accept()
      peer.close()
    })
    try {
      ignore(cmd_data_conn_from(session, 0, "RETR {}", ["/gone.txt"]))
      "no error"
    } catch {
      FtpError::ParseError(msg~) => msg
      _ => "other"
    }
  })
  assert_eq(message, "transfer command failed")
  assert_eq(sink.lines, ["EPSV", "RETR /gone.txt"])
}

///|
/// Both accepted transfer-start codes (`125` and `150`) are positive
/// *intermediate* replies, which is why the guard after the `cmd_format` can
/// only ever see one of them: the `cmd_format` expected list is exactly
/// `[125, 150]`, so any other code already turned into a `ParseError` above.
///
/// The guard is therefore the assertion that the accepted set and the
/// `is_positive_intermediate` class have not drifted apart — the regression
/// that once made this reject *every* real transfer. Pinning the two constants
/// against the predicate is what keeps it honest.
test "the accepted transfer-start codes are positive intermediates" {
  assert_true(is_positive_intermediate(status_data_conn_already_in_use))
  assert_true(is_positive_intermediate(150))
  assert_eq(status_data_conn_already_in_use, 125)
  // The completion code that ends a transfer is deliberately *not* one, so a
  // `226` arriving here can never be mistaken for a start.
  assert_false(is_positive_intermediate(status_closing_data_connection))
  // And the mistake the guard exists to catch: a 2xx is not a start.
  assert_false(is_positive_intermediate(226))
}

///|
/// The accepted transfer-start codes are `125` and `150`, both of which are
/// *positive intermediate*. A `2xx` here would mean the server skipped the
/// transfer, which must not be mistaken for success.
async test "cmd_data_conn_from accepts 125 as a transfer start" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) +
    "125 Data connection already open, transfer starting.\r\n"
  let (session, _) = scripted_session(script)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (peer, _) = listener.accept()
      peer.close()
    })
    let conn = cmd_data_conn_from(session, 0, "RETR {}", ["/a.txt"]) catch {
      _ => fail("125 must be accepted")
    }
    conn.close()
    ()
  })
}

///|
/// A non-zero `offset` puts a `REST <offset>` before the transfer command, in
/// that order — the restart marker has to precede the command it modifies.
async test "cmd_data_conn_from sends REST before the transfer command" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) +
    "350 Restarting at 4096.\r\n" +
    "150 Opening BINARY mode data connection.\r\n"
  let (session, sink) = scripted_session(script)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (peer, _) = listener.accept()
      peer.close()
    })
    let conn = cmd_data_conn_from(session, 4096L, "RETR {}", ["/big.bin"]) catch {
      _ => fail("cmd_data_conn_from")
    }
    conn.close()
    ()
  })
  assert_eq(sink.lines, ["EPSV", "REST 4096", "RETR /big.bin"])
}
