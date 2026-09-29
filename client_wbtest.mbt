// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

// Tests for the client handle: the capability flags, the option accessors and
// the `DialOptions` -> `Options` projection.
//
// Every one of these is a getter/setter pair over a `FTPClient` field, which
// is exactly why they are worth a test: a setter that writes the wrong field
// still compiles, and the caller only finds out when `list` sends `LIST`
// instead of `MLSD`. The `FTPClient` fields are package private, so the white
// box scope from `ftp_test_helpers_wbtest.mbt` is what lets a test build one
// without a socket.
//
// The `MDTM` write path (`set_file_time`) is driven through the scripted
// control channel here as well: which of `MFMT` / `MDTM` / nothing goes on the
// wire is the whole contract of that function.

///|
/// The documented `DialOptions` defaults, one assertion per field.
test "DialOptions defaults match the documented values" {
  let options = DialOptions::default()
  assert_eq(options.timeout_ms, default_dial_timeout_ms)
  assert_eq(options.timeout_ms, 30000)
  assert_eq(options.shut_timeout_ms, 0)
  assert_false(options.tls)
  assert_false(options.explicit_tls)
  assert_false(options.disable_epsv)
  assert_false(options.trust_pasv_ip)
  assert_false(options.disable_utf8)
  assert_false(options.disable_mlsd)
  assert_false(options.writing_mdtm)
  assert_false(options.force_list_hidden)
  assert_eq(options.location, @time.utc_zone)
  assert_true(options.trust is @tls.TrustedRoot::SystemRoot)
}

///|
/// Every `DialOptions` setter writes the field its name promises.
test "DialOptions setters round trip through the getters" {
  let options = DialOptions::default()
  options.set_timeout_ms(1234)
  assert_eq(options.timeout_ms, 1234)
  options.set_shut_timeout_ms(56)
  assert_eq(options.shut_timeout_ms, 56)
  options.set_tls(true)
  assert_true(options.tls)
  options.set_explicit_tls(true)
  assert_true(options.explicit_tls)
  options.set_trust(@tls.TrustedRoot::NoVerification)
  assert_true(options.trust is @tls.TrustedRoot::NoVerification)
  options.set_disable_epsv(true)
  assert_true(options.disable_epsv)
  options.set_trust_pasv_ip(true)
  assert_true(options.trust_pasv_ip)
  options.set_disable_utf8(true)
  assert_true(options.disable_utf8)
  options.set_disable_mlsd(true)
  assert_true(options.disable_mlsd)
  options.set_writing_mdtm(true)
  assert_true(options.writing_mdtm)
  options.set_force_list_hidden(true)
  assert_true(options.force_list_hidden)
  options.set_location(@time.utc_zone)
  assert_eq(options.location, @time.utc_zone)
}

///|
/// The projection onto the data channel options: `tls` is the *or* of the two
/// TLS flags, because by the time a data connection is opened an explicit
/// `AUTH TLS` upgrade is indistinguishable from implicit TLS — both need the
/// data channel wrapped.
test "to_state_options projects tls as the or of both TLS flags" {
  let plain = DialOptions::default()
  assert_false(plain.to_state_options().tls())

  let implicit = DialOptions::default()
  implicit.set_tls(true)
  assert_true(implicit.to_state_options().tls())

  let explicit = DialOptions::default()
  explicit.set_explicit_tls(true)
  assert_true(explicit.to_state_options().tls())
}

///|
/// The projection copies the timeouts, the SSRF switches and the trust policy
/// verbatim, so the data channel sees exactly what the caller configured.
test "to_state_options copies the connection parameters" {
  let options = DialOptions::default()
  options.set_timeout_ms(4321)
  options.set_shut_timeout_ms(99)
  options.set_disable_epsv(true)
  options.set_trust_pasv_ip(true)
  options.set_trust(@tls.TrustedRoot::CustomPemFile("/tmp/ca.pem"))
  let state = options.to_state_options()
  assert_eq(state.timeout_ms(), 4321)
  assert_eq(state.shut_timeout_ms(), 99)
  assert_true(state.disable_epsv())
  assert_true(state.trust_pasv_ip())
  // No TLS flag was set, so the data channel stays plain.
  assert_false(state.tls())
  assert_true(state.trust() is @tls.TrustedRoot::CustomPemFile(_))
}

///|
/// The data channel `Options` defaults: EPSV on, `PASV` IP untrusted (the SSRF
/// guard), no TLS, the 30s dial timeout.
test "Options defaults match DialOptions defaults" {
  let options = Options::default()
  assert_false(options.disable_epsv())
  assert_false(options.trust_pasv_ip())
  assert_false(options.tls())
  assert_eq(options.timeout_ms(), default_dial_timeout_ms)
  assert_eq(options.shut_timeout_ms(), 0)
  assert_true(options.trust is @tls.TrustedRoot::SystemRoot)
}

///|
/// `Options::new` is field-for-field; the accessors read back what went in.
test "Options::new and its accessors agree" {
  let options = Options::new(
    true,
    true,
    true,
    777,
    88,
    @tls.TrustedRoot::NoVerification,
  )
  assert_true(options.disable_epsv())
  assert_true(options.trust_pasv_ip())
  assert_true(options.tls())
  assert_eq(options.timeout_ms(), 777)
  assert_eq(options.shut_timeout_ms(), 88)
  assert_true(options.trust() is @tls.TrustedRoot::NoVerification)
}

///|
/// `Session` starts with `EPSV` un-tried and `PRET` unsupported, so the first
/// transfer tries `EPSV` and never sends `PRET`.
test "Session defaults are EPSV enabled and PRET unsupported" {
  let (control, _) = scripted_control("")
  let session = Session::new(control)
  assert_false(session.skip_epsv())
  assert_false(session.use_pret())
  assert_eq(session.control().host(), "127.0.0.1")
}

///|
/// The `skip_epsv` latch is what turns "the server refused EPSV once" into
/// "every later transfer goes through PASV", so both directions must work.
test "Session skip_epsv and use_pret round trip" {
  let (control, _) = scripted_control("")
  let session = Session::new(control)
  session.set_skip_epsv(true)
  assert_true(session.skip_epsv())
  session.set_skip_epsv(false)
  assert_false(session.skip_epsv())
  session.set_use_pret(true)
  assert_true(session.use_pret())
  session.set_use_pret(false)
  assert_false(session.use_pret())
}

///|
/// The `FTPClient` capability accessors read the flags the setters wrote, and
/// `has_feature` uppercases before looking up — that asymmetry with
/// `parse_features` (which stores uppercase) is what makes `has_feature("mlst")`
/// work from a caller.
test "the client capability flags round trip" {
  let (client, _) = scripted_client("")
  assert_false(client.is_mlst_supported())
  client.set_mlst_supported(true)
  assert_true(client.is_mlst_supported())

  client.set_mfmt_supported(true)
  assert_true(client.is_mfmt_supported())
  assert_true(client.is_set_time_supported())

  client.set_mfmt_supported(false)
  assert_false(client.is_set_time_supported())
  client.set_mdtm_supported(true)
  assert_true(client.is_get_time_supported())
  assert_true(client.is_set_time_supported())
  assert_true(client.is_time_precise_in_list())

  client.set_mdtm_can_write(true)
  assert_true(client.mdtm_can_write)
  client.set_mdtm_can_write(false)
  assert_false(client.mdtm_can_write)
}

///|
/// `has_feature` is case insensitive and knows nothing it was not told.
test "has_feature uppercases the lookup and misses cleanly" {
  let (client, _) = scripted_client("")
  let features : Map[String, Bool] = Map([])
  features["MLST"] = true
  client.set_features(features)
  assert_true(client.has_feature("MLST"))
  assert_true(client.has_feature("mlst"))
  assert_true(client.has_feature("Mlst"))
  assert_false(client.has_feature("UTF8"))
}

///|
/// `set_closed` is what makes `quit` idempotent, and the client reports the
/// closed state through `is_closed`.
test "the client closed flag round trips" {
  let (client, _) = scripted_client("")
  assert_false(client.is_closed())
  client.set_closed(true)
  assert_true(client.is_closed())
}

///|
/// The client hands back the very options it was built with, plus the matching
/// data channel projection and session.
test "the client accessors return its own options and session" {
  let options = DialOptions::default()
  options.set_timeout_ms(5555)
  let state = options.to_state_options()
  let (client, _) = scripted_client("", options=state, dial_options=options)
  assert_eq(client.options().timeout_ms, 5555)
  assert_eq(client.state_options().timeout_ms(), 5555)
  assert_eq(client.session().control().host(), "127.0.0.1")
}

///|
/// `location` is the timezone `LIST` timestamps are interpreted in; a setter
/// that dropped it would silently shift every parsed date.
test "the client location round trips" {
  let (client, _) = scripted_client("")
  assert_eq(client.location(), @time.utc_zone)
  client.set_location(@time.utc_zone)
  assert_eq(client.location(), @time.utc_zone)
}

///|
/// `set_file_time` prefers `MFMT` when the server advertises it, and sends the
/// encoded timestamp plus the path.
async test "set_file_time sends MFMT when the server supports it" {
  let (client, sink) = scripted_client("213 20240102030405\r\n")
  client.set_mfmt_supported(true)
  let timestamp = parse_mdtm("20240102030405") catch { _ => fail("parse_mdtm") }
  set_file_time(client, "/hello.txt", timestamp) catch {
    _ => fail("set_file_time raised")
  }
  assert_eq(sink.lines, ["MFMT 20240102030405 /hello.txt"])
}

///|
/// The VsFtpd quirk: a server that only advertises `MDTM` and was dialed with
/// `writing_mdtm` gets `MDTM <time> <path>`.
async test "set_file_time falls back to MDTM for the VsFtpd quirk" {
  let (client, sink) = scripted_client("213 20240102030405\r\n")
  client.set_mdtm_supported(true)
  client.set_mdtm_can_write(true)
  let timestamp = parse_mdtm("20240102030405") catch { _ => fail("parse_mdtm") }
  set_file_time(client, "/hello.txt", timestamp) catch {
    _ => fail("set_file_time raised")
  }
  assert_eq(sink.lines, ["MDTM 20240102030405 /hello.txt"])
}

///|
/// `MDTM` without `writing_mdtm` is the read-only case: the call must refuse
/// *before* sending anything, with the upstream `502` code.
async test "set_file_time refuses when only MDTM reads are supported" {
  let (client, sink) = scripted_client("")
  client.set_mdtm_supported(true)
  let timestamp = parse_mdtm("20240102030405") catch { _ => fail("parse_mdtm") }
  let raised = try {
    set_file_time(client, "/hello.txt", timestamp)
    None
  } catch {
    FtpError::ServerError(code~, ..) => Some(code)
    _ => None
  }
  assert_eq(raised, Some(502))
  assert_eq(sink.lines, [])
}

///|
/// `file_size` parses the `213` payload and reports a non numeric answer as a
/// parse error instead of `0`.
async test "file_size reads the 213 payload" {
  let (client, sink) = scripted_client("213 1048576\r\n")
  let size = file_size(client, "/big.bin") catch { _ => fail("file_size") }
  assert_eq(size, 1048576UL)
  assert_eq(sink.lines, ["SIZE /big.bin"])
}

///|
async test "file_size rejects a non numeric payload" {
  let (client, _) = scripted_client("213 not a number\r\n")
  let raised = try {
    ignore(file_size(client, "/big.bin"))
    None
  } catch {
    FtpError::ParseError(_) => Some(true)
    _ => None
  }
  assert_eq(raised, Some(true))
}

///|
/// `get_time` reads the `213` timestamp of `MDTM`.
async test "get_time reads the 213 timestamp" {
  let (client, sink) = scripted_client("213 20220813133357\r\n")
  let timestamp = get_time(client, "/hello.txt") catch { _ => fail("get_time") }
  assert_eq(format_mdtm(timestamp), "20220813133357")
  assert_eq(sink.lines, ["MDTM /hello.txt"])
}
