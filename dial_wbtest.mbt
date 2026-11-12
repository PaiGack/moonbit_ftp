// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Package: `PaiGack/ftp` -- the public client API. Layers below it live in
// `core/` (values), `connection/` (control + data channel) and `debug/` (traffic log).

// Tests for the login / `FEAT` / TLS negotiation half of `dial.mbt`.
//
// `dial` needs a socket, but the sequence it runs *after* the greeting is pure
// command/response work, and that is the half a real server cannot pin down
// per case: what does the client send when the server has no `UTF8`?, what
// happens when `FEAT` fails?, does `PBSZ` / `PROT` really only run for TLS?
// A scripted control channel answers all of them deterministically, and a real
// vsftpd in `@connection.cmd/example` covers the happy path end to end.
//
// The `auth_tls` / `set_utf8` helpers are private, so they are reached through
// `login` / `feat`, which is also the only way a caller reaches them.

///|
/// `feat` caches the capabilities, and each one flips the flag `client.mbt`
/// exposes — those flags are what `list` and the time helpers branch on.
async test "feat caches the feature flags the client branches on" {
  let script = "211-Features:\r\n MLST\r\n MFMT\r\n MDTM\r\n PRET\r\n UTF8\r\n211 End\r\n"
  let (client, sink) = scripted_client(script)
  feat(client) catch {
    e => fail("feat: \{e}")
  }
  assert_eq(sink.lines, ["FEAT"])
  assert_true(client.has_feature("mlst"))
  assert_true(client.has_feature("mfmt"))
  assert_true(client.has_feature("mdtm"))
  assert_true(client.has_feature("utf8"))
  // `mlst_supported` is what makes `list` send `MLSD` instead of `LIST`.
  assert_true(client.is_mlst_supported())
  assert_true(client.is_mfmt_supported())
  assert_true(client.is_get_time_supported())
  assert_true(client.is_set_time_supported())
  assert_true(client.is_time_precise_in_list())
  assert_true(client.session().use_pret())
}

///|
/// A server with a minimal feature list must not be told it supports things
/// it never advertised: a false positive here makes `list` send `MLSD` to a
/// server that only speaks `LIST`.
async test "feat leaves unadvertised capabilities off" {
  let script = "211-Features:\r\n PASV\r\n211 End\r\n"
  let (client, _) = scripted_client(script)
  feat(client) catch {
    e => fail("feat: \{e}")
  }
  assert_false(client.has_feature("MLST"))
  assert_false(client.is_mlst_supported())
  assert_false(client.is_mfmt_supported())
  assert_false(client.is_get_time_supported())
  assert_false(client.is_set_time_supported())
  assert_false(client.is_time_precise_in_list())
  assert_false(client.session().use_pret())
  // `REST` and `PASV` are still cached: they are features, not flags.
  assert_true(client.has_feature("PASV"))
}

///|
/// `disable_mlsd` is the caller's override and must win over a server that
/// advertises `MLST`.
async test "feat honours disable_mlsd over the server's answer" {
  let script = "211-Features:\r\n MLST\r\n211 End\r\n"
  let dial_options = DialOptions::default()
  dial_options.set_disable_mlsd(true)
  let (client, _) = scripted_client(script, dial_options~)
  feat(client) catch {
    e => fail("feat: \{e}")
  }
  assert_true(client.has_feature("MLST"))
  assert_false(client.is_mlst_supported())
}

///|
/// `writing_mdtm` selects the VsFtpd `MDTM <time> <path>` write path, so it
/// must survive into the flag even when the server only advertises `MDTM`.
async test "feat records the writing_mdtm override" {
  let script = "211-Features:\r\n MDTM\r\n211 End\r\n"
  let dial_options = DialOptions::default()
  dial_options.set_writing_mdtm(true)
  let (client, _) = scripted_client(script, dial_options~)
  feat(client) catch {
    e => fail("feat: \{e}")
  }
  assert_true(client.is_get_time_supported())
  // `MDTM` alone reads timestamps; writing one needs `writing_mdtm`, and the
  // capability query has to say so -- upstream folds it into the same
  // expression.
  assert_true(client.is_set_time_supported())
}

///|
/// The other half of that expression: a server that only advertises `MDTM`
/// and was *not* dialed with `writing_mdtm` cannot have its timestamps written,
/// so the query must say `false` even though `MDTM` is present.
///
/// Without this, `is_set_time_supported` reports a capability that
/// `set_file_time` immediately refuses with `502`, and an API user who branches
/// on the flag is told the opposite of what the library will do.
async test "feat leaves is_set_time_supported off for a read-only MDTM server" {
  let script = "211-Features:\r\n MDTM\r\n211 End\r\n"
  let (client, _) = scripted_client(script)
  feat(client) catch {
    e => fail("feat: \{e}")
  }
  assert_true(client.is_get_time_supported())
  assert_false(client.is_set_time_supported())
}

///|
/// A server that answers `FEAT` with an error has no feature list; upstream
/// treats that as "no capabilities", *not* as a login failure. The flags must
/// all stay off and `feat` must still return normally.
async test "feat tolerates a server without a feature list" {
  let script = "500 Unknown command.\r\n"
  let (client, sink) = scripted_client(script)
  // A `500` is the "no feature list" answer: `feat` returns normally rather
  // than raising, and the flags stay off.
  feat(client) catch {
    e => fail("feat should not raise: \{e}")
  }
  assert_eq(sink.lines, ["FEAT"])
  assert_false(client.has_feature("MLST"))
  assert_false(client.is_mlst_supported())
  assert_false(client.session().use_pret())
}

///|
/// The full happy path: `USER` -> `331`, `PASS` -> `230`, `FEAT`, `TYPE I`.
/// The password must never be sent as a `PASS` when `USER` already logged the
/// session in.
async test "login sends USER, PASS, FEAT and TYPE" {
  let script = "331 Please specify the password.\r\n" +
    "230 Login successful.\r\n" +
    "211-Features:\r\n UTF8\r\n211 End\r\n" +
    "200 Always in UTF8 mode.\r\n" +
    "200 Switching to Binary mode.\r\n"
  let (client, sink) = scripted_client(script)
  login(client, "test", "secret") catch {
    e => fail("login: \{e}")
  }
  assert_eq(sink.lines, [
    "USER test", "PASS secret", "FEAT", "TYPE I", "OPTS UTF8 ON",
  ])
}

///|
/// A server that accepts `USER` with `230` (anonymous-ish, or no password
/// needed) must not receive a `PASS` line: sending one desynchronises the
/// session, because the server already moved on.
async test "login skips PASS when USER already authenticated" {
  let script = "230 Already logged in.\r\n" +
    "211-Features:\r\n211 End\r\n" +
    "200 Switching to Binary mode.\r\n"
  let (client, sink) = scripted_client(script)
  login(client, "anonymous", "irrelevant") catch {
    e => fail("login: \{e}")
  }
  assert_eq(sink.lines, ["USER anonymous", "FEAT", "TYPE I"])
}

///|
/// `disable_utf8` is the caller saying "do not send OPTS UTF8 ON", even to a
/// server that advertises `UTF8`.
async test "login honours disable_utf8" {
  let script = "331 Password.\r\n" +
    "230 Logged in.\r\n" +
    "211-Features:\r\n UTF8\r\n211 End\r\n" +
    "200 Switching to Binary mode.\r\n"
  let dial_options = DialOptions::default()
  dial_options.set_disable_utf8(true)
  let (client, sink) = scripted_client(script, dial_options~)
  login(client, "test", "secret") catch {
    e => fail("login: \{e}")
  }
  assert_eq(sink.lines, ["USER test", "PASS secret", "FEAT", "TYPE I"])
}

///|
/// A server without `UTF8` in its feature list is never asked for it.
async test "login does not send OPTS UTF8 to a server without the feature" {
  let script = "331 Password.\r\n" +
    "230 Logged in.\r\n" +
    "211-Features:\r\n PASV\r\n211 End\r\n" +
    "200 Switching to Binary mode.\r\n"
  let (client, sink) = scripted_client(script)
  login(client, "test", "secret") catch {
    e => fail("login: \{e}")
  }
  assert_eq(sink.lines, ["USER test", "PASS secret", "FEAT", "TYPE I"])
}

///|
/// A rejected `OPTS UTF8 ON` (some servers answer `501`) must not fail the
/// login: upstream accepts `202` / `501` / `504` for exactly that reason.
async test "login survives a server that refuses OPTS UTF8" {
  let script = "331 Password.\r\n" +
    "230 Logged in.\r\n" +
    "211-Features:\r\n UTF8\r\n211 End\r\n" +
    "200 Switching to Binary mode.\r\n" +
    "501 Option not understood.\r\n"
  let (client, sink) = scripted_client(script)
  login(client, "test", "secret") catch {
    e => fail("login: \{e}")
  }
  assert_eq(sink.lines, [
    "USER test", "PASS secret", "FEAT", "TYPE I", "OPTS UTF8 ON",
  ])
}

///|
/// Implicit TLS keeps the control connection open but still has to secure the
/// *data* channel, which is the `PBSZ 0` / `PROT P` pair. Without it every
/// `RETR` answers `522 SSL connection required`.
async test "login sends PBSZ and PROT P for implicit TLS" {
  let script = "331 Password.\r\n" +
    "230 Logged in.\r\n" +
    "211-Features:\r\n211 End\r\n" +
    "200 Switching to Binary mode.\r\n" +
    "200 PBSZ=0\r\n" +
    "200 Protection set to Private\r\n"
  let dial_options = DialOptions::default()
  dial_options.set_tls(true)
  let (client, sink) = scripted_client(script, dial_options~)
  login(client, "test", "secret") catch {
    e => fail("login: \{e}")
  }
  assert_eq(sink.lines, [
    "USER test", "PASS secret", "FEAT", "TYPE I", "PBSZ 0", "PROT P",
  ])
}

///|
/// Without TLS the two data-channel protection commands must never appear: a
/// plain server answers both with `500` and the login would fail.
async test "login does not send PBSZ or PROT without TLS" {
  let script = "331 Password.\r\n" +
    "230 Logged in.\r\n" +
    "211-Features:\r\n211 End\r\n" +
    "200 Switching to Binary mode.\r\n"
  let (client, sink) = scripted_client(script)
  login(client, "test", "secret") catch {
    e => fail("login: \{e}")
  }
  assert_false(sink.lines.contains("PBSZ 0"))
  assert_false(sink.lines.contains("PROT P"))
}

///|
/// A `USER` reply the client does not expect (`530 Not logged in`) is a server
/// error carrying the original code and message.
async test "login reports a rejected USER" {
  let script = "530 Login incorrect.\r\n"
  let (client, _) = scripted_client(script)
  let raised = try {
    login(client, "test", "wrong")
    None
  } catch {
    @core.FtpError::ServerError(code~, msg~) => Some((code, msg))
    _ => None
  }
  assert_eq(raised, Some((530, "Login incorrect.")))
}

///|
/// A rejected `PASS` is a server error too, and it must be reported *before*
/// the client moves on to `FEAT`.
async test "login reports a rejected PASS" {
  let script = "331 Password.\r\n530 Login incorrect.\r\n"
  let (client, sink) = scripted_client(script)
  let raised = try {
    login(client, "test", "wrong")
    None
  } catch {
    @core.FtpError::ServerError(code~, ..) => Some(code)
    _ => None
  }
  assert_eq(raised, Some(530))
  // `FEAT` and `TYPE` were never sent.
  assert_eq(sink.lines, ["USER test", "PASS wrong"])
}

///|
/// A server that refuses `TYPE I` fails the login: the transfer type is part
/// of the negotiated session, not a best-effort extra.
async test "login reports a rejected TYPE" {
  let script = "331 Password.\r\n" +
    "230 Logged in.\r\n" +
    "211-Features:\r\n211 End\r\n" +
    "504 Command not implemented for that parameter.\r\n"
  let (client, _) = scripted_client(script)
  let raised = try {
    login(client, "test", "secret")
    None
  } catch {
    @core.FtpError::ServerError(code~, ..) => Some(code)
    _ => None
  }
  assert_eq(raised, Some(504))
}

///|
/// A server that refuses `PBSZ` fails the TLS login: continuing would leave
/// the data channel unprotected while the caller believes it is encrypted,
/// which is the worst of both worlds.
async test "login reports a rejected PBSZ" {
  let script = "331 Password.\r\n" +
    "230 Logged in.\r\n" +
    "211-Features:\r\n211 End\r\n" +
    "200 Switching to Binary mode.\r\n" +
    "500 PBSZ not understood.\r\n"
  let dial_options = DialOptions::default()
  dial_options.set_tls(true)
  let (client, sink) = scripted_client(script, dial_options~)
  let raised = try {
    login(client, "test", "secret")
    None
  } catch {
    @core.FtpError::ServerError(code~, ..) => Some(code)
    _ => None
  }
  assert_eq(raised, Some(500))
  // `PROT P` was never attempted after the `PBSZ` failure.
  assert_eq(sink.lines, ["USER test", "PASS secret", "FEAT", "TYPE I", "PBSZ 0"])
}

///|
/// `dial` against a real loopback server: the greeting is read, the address is
/// split, and the peer's IP is rendered as a dotted quad for the `PASV` SSRF
/// guard. This is the only test that runs the whole connect path, and it is
/// what covers `format_ip` and the `220` guard.
async test "dial reads the greeting from a real socket" {
  let listener = data_listener()
  let port = listener.addr.port()
  let client = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (conn, _) = listener.accept()
      conn.write("220 Test server ready.\r\n")
      // Keep the connection open until the client is done with it.
      ignore(conn.read_all() catch { _ => empty_data() })
      conn.close()
    })
    dial("127.0.0.1:\{port}") catch {
      _ => fail("dial")
    }
  })
  // The peer we reached is `127.0.0.1`, so the trusted `PASV` IP is that
  // dotted quad and not the hostname the caller passed.
  assert_eq(client.session().control().host(), "127.0.0.1")
  assert_eq(client.options().timeout_ms, @core.default_dial_timeout_ms)
  assert_false(client.is_closed())
}

///|
/// The control connection's `host` is the *peer* we dialled, not ourselves.
///
/// This is the only fixture that can tell the two apart: every other one
/// listens on `127.0.0.1` and dials `127.0.0.1`, where "the local address of
/// this socket" and "the address of the far end" are the same string. A server
/// bound to `127.0.0.2` and dialled *from* `127.0.0.1` separates them, which is
/// the whole shape of the bug this pins: `dial` used to store
/// `Tcp::addr().ip()` -- documented as the *local* address -- so the passive
/// data channel dialled back to the client itself, and every `RETR` / `STOR` /
/// `LIST` failed with "connection refused" on any machine that was not the
/// server. Nothing in the loopback fixtures could see it.
///
/// The assertion is on the address rather than on "it differs from the local
/// address" because an assertion that can be satisfied by a third wrong value
/// is not worth having.
async test "dial stores the peer address, not the local one" {
  let listener = @socket.TcpServer::TcpServer(
    @socket.Addr::parse("127.0.0.2:0"),
  )
  let port = listener.addr.port()
  let client = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (conn, _) = listener.accept()
      conn.write("220 Test server ready.\r\n")
      ignore(conn.read_all() catch { _ => empty_data() })
      conn.close()
    })
    dial("127.0.0.2:\{port}") catch {
      _ => fail("dial")
    }
  })
  assert_eq(client.session().control().host(), "127.0.0.2")
  // A plaintext dial has no certificate to check, so no name is recorded: the
  // peer address is not silently reused as one.
  assert_eq(client.session().control().server_name(), None)
}

///|
/// And the same split for a *name*: the caller's hostname is what a
/// certificate is verified against, while the peer address is the literal the
/// socket dialled -- so a certificate issued for the name still verifies after
/// the data channel dials the IP. Built directly, because `dial` takes an
/// `Addr`, i.e. it never resolves a name itself; a name reaches this client
/// through the control connection it was handed.
test "control keeps the TLS server name apart from the peer address" {
  let reader = @io.MemoryReader(writer => writer.write(""))
  let sink = recording_sink()
  // No fallback from the peer address: an unset name stays unset, so "nobody
  // chose a name" cannot be confused with "the address is the name".
  let control = @connection.Control::new(reader, sink, "127.0.0.1")
  assert_eq(control.host(), "127.0.0.1")
  assert_eq(control.server_name(), None)
  let named = @connection.Control::new(
    reader,
    sink,
    "127.0.0.1",
    server_name=Some("ftp.example.com"),
  )
  assert_eq(named.host(), "127.0.0.1")
  assert_eq(named.server_name(), Some("ftp.example.com"))
  reader.close()
}

///|
/// A blank name is rejected rather than treated as "not set": it is what a
/// TLS client would otherwise receive as the verification target.
test "Control::new rejects a blank server name" {
  let reader = @io.MemoryReader(writer => writer.write(""))
  let sink = recording_sink()
  let blank = fn() -> @connection.Control raise @core.FtpError {
    @connection.Control::new(reader, sink, "127.0.0.1", server_name=Some(" "))
  }
  let refused = try {
    ignore(blank())
    false
  } catch {
    @core.FtpError::ParseError(_) => true
    _ => false
  }
  assert_true(refused)
  reader.close()
}

///|
/// A plaintext dial carries no name at all, while a TLS dial -- including one
/// to an IP literal, where the address is the verification target -- carries
/// one. The difference is what `DataConn::start_tls` checks before handshaking.
async test "a plaintext dial has no server name, a TLS dial has one" {
  let server = @socket.TcpServer::TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  let plain = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (conn, _) = server.accept()
      conn.write("220 Test server ready.\r\n")
      ignore(conn.read_all() catch { _ => empty_data() })
      conn.close()
    })
    dial("127.0.0.1:\{port}") catch {
      _ => fail("dial")
    }
  })
  assert_eq(plain.session().control().host(), "127.0.0.1")
  assert_eq(plain.session().control().server_name(), None)
}

///|
/// `dial` installs the traffic log the caller asked for *before* it reads the
/// greeting, so the first record in the transcript is what the server said
/// first -- and no sink means no logging layer at all.
async test "dial installs the traffic log before the greeting" {
  let listener = data_listener()
  let port = listener.addr.port()
  let sink = text_sink()
  let log : &@io.Writer = sink
  let client = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (conn, _) = listener.accept()
      conn.write("220 Test server ready.\r\n")
      ignore(conn.read_all() catch { _ => empty_data() })
      conn.close()
    })
    dial("127.0.0.1:\{port}", debug_sink=Some(log)) catch {
      _ => fail("dial")
    }
  })
  assert_true(client.session().control().debug_enabled())
  // The greeting is the one record: `dial` sends nothing before it.
  assert_eq(sink.text(), "<<< 220 Test server ready.\r\n")
}

///|
/// Without a sink the connection carries no logging layer at all, which is the
/// default and what keeps every other test's output unchanged.
async test "dial installs no log when no sink is given" {
  let listener = data_listener()
  let port = listener.addr.port()
  let client = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (conn, _) = listener.accept()
      conn.write("220 Test server ready.\r\n")
      ignore(conn.read_all() catch { _ => empty_data() })
      conn.close()
    })
    dial("127.0.0.1:\{port}") catch {
      _ => fail("dial")
    }
  })
  assert_false(client.session().control().debug_enabled())
}

///|
/// `dial` applies the implicit TLS default port (990) when the caller passes a
/// bare host, and 21 otherwise. The port is not observable directly, so the
/// proof is that a bare `127.0.0.1` with `tls=false` reaches a server on an
/// ephemeral port only when that port is spelled out *and* that the default is
/// the documented one.
async test "dial defaults to port 21 for a bare host" {
  // A bare host resolves to 127.0.0.1:21, where no server is listening in the
  // sandbox, so the connect fails rather than hanging.
  let raised = try {
    ignore(dial("127.0.0.1", timeout_ms=200))
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}

///|
/// A greeting that is not `220` is a server error carrying the original code:
/// the client must not proceed to `login` on a server that is not ready.
async test "dial rejects a greeting that is not 220" {
  let listener = data_listener()
  let port = listener.addr.port()
  let code = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (conn, _) = listener.accept()
      conn.write("421 Service not available.\r\n")
      ignore(conn.read_all() catch { _ => empty_data() })
      conn.close()
    })
    try {
      ignore(dial("127.0.0.1:\{port}"))
      -1
    } catch {
      @core.FtpError::ServerError(code~, ..) => code
      _ => -2
    }
  })
  assert_eq(code, 421)
}

///|
/// An address that cannot be parsed as `host:port` is a `ParseError` rather
/// than a raw socket failure, so the caller sees a protocol-level message.
async test "dial reports an unparsable address" {
  let raised = try {
    ignore(dial("not a host::::", timeout_ms=200))
    None
  } catch {
    @core.FtpError::ParseError(_) => Some(true)
    _ => None
  }
  assert_eq(raised, Some(true))
}

///|
/// `explicit_tls` sends `AUTH TLS` after the greeting, requires `234`, and then
/// really starts the handshake on the same socket.
///
/// The stub here answers `234` but never speaks TLS, which is exactly the trap
/// the old code fell into: it read `234`, returned "upgraded", and left the
/// caller with a plaintext session they believed was encrypted. Now the
/// handshake is attempted and bounded, so the dial fails instead of either
/// silently downgrading or hanging.
async test "dial with explicit_tls attempts the handshake and fails on a non-TLS peer" {
  let listener = data_listener()
  let port = listener.addr.port()
  let failed = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (conn, _) = listener.accept()
      conn.write("220 Test server ready.\r\n")
      conn.write("234 AUTH TLS successful.\r\n")
      // A real server would now handshake; this one just holds the fd open so
      // the client's ClientHello is met with silence.
      ignore(conn.read_all() catch { _ => empty_data() })
      conn.close()
    })
    try {
      ignore(dial("127.0.0.1:\{port}", explicit_tls=true, timeout_ms=1500))
      false
    } catch {
      _ => true
    }
  })
  assert_true(failed)
}

///|
/// A refused `AUTH TLS` is a server error, not a silent downgrade.
async test "dial reports a refused AUTH TLS" {
  let listener = data_listener()
  let port = listener.addr.port()
  let code = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (conn, _) = listener.accept()
      conn.write("220 Test server ready.\r\n")
      conn.write("500 AUTH not understood.\r\n")
      ignore(conn.read_all() catch { _ => empty_data() })
      conn.close()
    })
    try {
      ignore(dial("127.0.0.1:\{port}", explicit_tls=true))
      -1
    } catch {
      @core.FtpError::ServerError(code~, ..) => code
      _ => -2
    }
  })
  assert_eq(code, 500)
}

///|
/// A refused `OPTS UTF8 ON` is swallowed *inside* `login`: the server
/// advertised the feature but does not implement the command, and upstream
/// accepts that combination. The `catch` there is what this test reaches.
async test "login swallows a refused OPTS UTF8 and keeps going" {
  let script = "331 Password.\r\n" +
    "230 Logged in.\r\n" +
    "211-Features:\r\n UTF8\r\n211 End\r\n" +
    "200 Switching to Binary mode.\r\n" +
    "504 Command not implemented for that parameter.\r\n"
  let (client, sink) = scripted_client(script)
  login(client, "test", "secret") catch {
    _ => fail("login should not raise")
  }
  // The refused reply lands on `OPTS UTF8 ON`; `TYPE I` was already sent
  // before it, which is what proves the failure was swallowed rather than
  // aborting the login.
  assert_eq(sink.lines, [
    "USER test", "PASS secret", "FEAT", "TYPE I", "OPTS UTF8 ON",
  ])
}

///|
/// `dial(tls=true)` must wrap the *control* connection before it reads a single
/// byte, because implicit FTPS (port 990) sends even the `220` greeting inside
/// the TLS session.
///
/// This is the one implicit-TLS decision no other test reaches: `tls_test.mbt`
/// only checks that the flag survives `to_state_options` (the data channel),
/// and every live TLS assertion runs the *explicit* `AUTH TLS` path. Leaving
/// the control socket in the clear was exactly the bug that shipped once --
/// the greeting read then blocks on bytes of a `ClientHello` it can never
/// parse -- and `docs/porting.md` 2.6 claims implicit TLS is covered here.
#warnings("-alert_internal")
async test "dial with implicit tls reads the greeting over a TLS session" {
  let listener = data_listener()
  let port = listener.addr.port()
  let client = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (conn, _) = listener.accept()
      // Server-side TLS on the control socket: the greeting only exists inside
      // the session, so a client that left the socket in the clear reads TLS
      // records instead of `220`.
      let tls = @tls.Tls::server_from_pair(
        conn,
        conn,
        private_key_file=tls_key_file(),
        private_key_type=@tls.X509FileType::PEM,
        certificate_file=tls_cert_file(),
        certificate_type=@tls.X509FileType::PEM,
      )
      tls.write("220 Test server ready.\r\n")
      ignore(tls.read_all() catch { _ => empty_data() })
      conn.close()
    })
    dial(
      "127.0.0.1:\{port}",
      tls=true,
      timeout_ms=5000,
      trust=@tls.TrustedRoot::CustomPemFile(tls_ca_file()),
    ) catch {
      e => fail("implicit tls dial: \{e}")
    }
  })
  assert_eq(client.session().control().host(), "127.0.0.1")
  assert_true(client.state_options().tls())
}

///|
/// A server that advertises `AUTH TLS` while the session runs in the clear has
/// already received the password in plaintext; `login` says so on stderr (the
/// password itself never appears) instead of failing a login the caller may
/// have chosen. The opposite cases -- a TLS session, and a server that offers
/// no TLS at all -- stay silent.
///
/// This pins that the *sequence* runs on all three paths. It cannot hear the
/// line itself: stderr is the process's, not a value a test can capture, and
/// either way of capturing it would change the production shape.
async test "login runs the plaintext warning decision on every path" {
  let tls_script = "331 Password.\r\n" +
    "230 Logged in.\r\n" +
    "211-Features:\r\n AUTH TLS\r\n PBSZ\r\n PROT\r\n211 End\r\n" +
    "200 Switching to Binary mode.\r\n" +
    "200 PBSZ=0\r\n200 Protection set to Private\r\n"
  let (client, _) = scripted_client(tls_script)
  login(client, "test", "secret") catch {
    e => fail("login: \{e}")
  }
  // A TLS session on the same server is the case the warning is *for*, so it
  // must not fire there.
  let dial_options = DialOptions::default()
  // The *folded* TLS flag (`tls || explicit_tls`) is what `login` reads for
  // `PBSZ` / `PROT` and for the warning; explicit TLS alone is not enough.
  dial_options.set_tls(true)
  let (tls_client, _) = scripted_client(tls_script, dial_options~)
  login(tls_client, "test", "secret") catch {
    e => fail("login: \{e}")
  }
  // A plaintext-only server says nothing either way: silence, not a warning
  // per login.
  let plain_script = "331 Password.\r\n" +
    "230 Logged in.\r\n" +
    "211-Features:\r\n PASV\r\n211 End\r\n" +
    "200 Switching to Binary mode.\r\n"
  let (plain, plain_sink) = scripted_client(plain_script)
  login(plain, "test", "secret") catch {
    e => fail("login: \{e}")
  }
  // A server that answered `FEAT` has already answered the TLS question:
  // no follow-up `AUTH TLS` is sent, or every plaintext-only server would
  // get one on every login.
  assert_false(plain_sink.lines.contains("AUTH TLS"))
}

///|
/// `AUTH TLS;TLS-C` is vsftpd's spelling of a TLS-capable server (RFC 2228
/// allows the mechanism list after the name). It must make `login` decide
/// "the server offers TLS" exactly like the bare `AUTH TLS` line does -- the
/// only observable difference is on stderr, which the test cannot read, so
/// this pins the input the decision is made from.
async test "login sees AUTH TLS behind a mechanism list" {
  let script = "331 Password.\r\n" +
    "230 Logged in.\r\n" +
    "211-Features:\r\n AUTH TLS;TLS-C\r\n PBSZ\r\n PROT\r\n211 End\r\n" +
    "200 Switching to Binary mode.\r\n"
  let (client, sink) = scripted_client(script)
  login(client, "test", "secret") catch {
    e => fail("login: \{e}")
  }
  assert_true(client.has_feature("AUTH TLS"))
  // The server answered `FEAT`, so no probe is appended after the login tail.
  assert_false(sink.lines.contains("AUTH TLS"))
}
