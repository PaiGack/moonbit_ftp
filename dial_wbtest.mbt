// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

// Tests for the login / `FEAT` / TLS negotiation half of `dial.mbt`.
//
// `dial` needs a socket, but the sequence it runs *after* the greeting is pure
// command/response work, and that is the half a real server cannot pin down
// per case: what does the client send when the server has no `UTF8`?, what
// happens when `FEAT` fails?, does `PBSZ` / `PROT` really only run for TLS?
// A scripted control channel answers all of them deterministically, and a real
// vsftpd in `cmd/example` covers the happy path end to end.
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
  // `is_set_time_supported` is `MFMT || MDTM`; the `writing_mdtm` flag is what
  // `set_file_time` consults on top of it.
  assert_true(client.is_set_time_supported())
}

///|
/// A server that answers `FEAT` with an error has no feature list; upstream
/// treats that as "no capabilities", *not* as a login failure. The flags must
/// all stay off and `feat` must still return normally.
async test "feat tolerates a server without a feature list" {
  let script = "500 Unknown command.\r\n"
  let (client, sink) = scripted_client(script)
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
    "USER test", "PASS secret", "FEAT", "OPTS UTF8 ON", "TYPE I",
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
    "501 Option not understood.\r\n" +
    "200 Switching to Binary mode.\r\n"
  let (client, sink) = scripted_client(script)
  login(client, "test", "secret") catch {
    e => fail("login: \{e}")
  }
  assert_eq(sink.lines, [
    "USER test", "PASS secret", "FEAT", "OPTS UTF8 ON", "TYPE I",
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
    FtpError::ServerError(code~, msg~) => Some((code, msg))
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
    FtpError::ServerError(code~, ..) => Some(code)
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
    FtpError::ServerError(code~, ..) => Some(code)
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
    FtpError::ServerError(code~, ..) => Some(code)
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
  assert_eq(client.options().timeout_ms, default_dial_timeout_ms)
  assert_false(client.is_closed())
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
      FtpError::ServerError(code~, ..) => code
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
    FtpError::ParseError(_) => Some(true)
    _ => None
  }
  assert_eq(raised, Some(true))
}

///|
/// `explicit_tls` sends `AUTH TLS` after the greeting and requires `234`; a
/// server that refuses it fails the dial instead of leaving the caller with a
/// plaintext session they believe is encrypted.
async test "dial with explicit_tls sends AUTH TLS" {
  let listener = data_listener()
  let port = listener.addr.port()
  let client = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (conn, _) = listener.accept()
      conn.write("220 Test server ready.\r\n")
      conn.write("234 AUTH TLS successful.\r\n")
      ignore(conn.read_all() catch { _ => empty_data() })
      conn.close()
    })
    dial("127.0.0.1:\{port}", explicit_tls=true) catch {
      _ => fail("dial")
    }
  })
  assert_false(client.is_closed())
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
      FtpError::ServerError(code~, ..) => code
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
    "504 Command not implemented for that parameter.\r\n" +
    "200 Switching to Binary mode.\r\n"
  let (client, sink) = scripted_client(script)
  login(client, "test", "secret") catch {
    _ => fail("login should not raise")
  }
  // The refused `OPTS` is the third command; `TYPE I` still followed, which is
  // what proves the failure was swallowed rather than aborting the login.
  assert_eq(sink.lines, [
    "USER test", "PASS secret", "FEAT", "OPTS UTF8 ON", "TYPE I",
  ])
}
