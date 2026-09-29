// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: pure logic — the option plumbing that decides whether a connection is
// encrypted. No socket here; the wire behaviour is covered end to end by
// `cmd/ftps` against `scripts/ftps/start-ftps.sh`.
//
// These exist because the FTPS smoke test found three separate places where
// the TLS options were plumbed but not acted on: `AUTH TLS` was sent without
// ever upgrading the socket, `PBSZ` / `PROT P` were skipped for explicit TLS,
// and implicit TLS never wrapped the control connection at all. Each of those
// is a one-line mistake in a *different* file, and none of them was reachable
// from the plaintext end-to-end demo. Pinning the decisions here turns "the
// flag is set" into something a unit test can assert, so the next regression
// shows up without a live server.

///|
/// Build a `DialOptions` from the three flags that interact.
fn dial_options(
  tls? : Bool = false,
  explicit_tls? : Bool = false,
  trust_pasv_ip? : Bool = false,
) -> @ftp.DialOptions {
  let options = @ftp.DialOptions::default()
  options.set_tls(tls)
  options.set_explicit_tls(explicit_tls)
  options.set_trust_pasv_ip(trust_pasv_ip)
  options
}

///|
/// Implicit TLS is the one that changes the *control* connection: the data
/// channel layer only sees `Options::tls` through `to_state_options`, so the
/// flag has to survive the projection or the client transfers in the clear.
test "implicit tls turns on tls in the data channel options" {
  let state = dial_options(tls=true).to_state_options()
  assert_true(state.tls())
  assert_false(state.disable_epsv())
  assert_false(state.trust_pasv_ip())
}

///|
/// Explicit TLS protects the data channel too (`PROT P`), so the projection
/// has to be true for it as well. Getting this wrong is what made
/// `dial(explicit_tls=true)` answer every transfer with
/// `550 SSL/TLS required on the data channel.` against a server that
/// enforces RFC 4217.
test "explicit tls also turns on tls in the data channel options" {
  let state = dial_options(explicit_tls=true).to_state_options()
  assert_true(state.tls())
}

///|
/// A plain connection must not claim to be encrypted, or every transfer would
/// try a TLS handshake against a plaintext data port.
test "a plain dial leaves the data channel unencrypted" {
  let state = dial_options().to_state_options()
  assert_false(state.tls())
}

///|
/// `trust_pasv_ip` is the SSRF guard's opt-out and has to survive the
/// projection unchanged: the data channel layer is the only reader of it.
test "the ssrf guard flag survives the projection" {
  assert_true(
    dial_options(trust_pasv_ip=true).to_state_options().trust_pasv_ip(),
  )
  assert_false(dial_options().to_state_options().trust_pasv_ip())
}

///|
/// The `trust` policy is what the data channel verifies the server against, so
/// it has to travel with the options rather than defaulting back to the system
/// roots inside `open_data_conn`.
test "the trust policy survives the projection" {
  let options = @ftp.DialOptions::default()
  options.set_trust(@tls.TrustedRoot::NoVerification)
  assert_true(
    options.to_state_options().trust() is @tls.TrustedRoot::NoVerification,
  )
}

///|
/// Implicit TLS lives on 990 and explicit on 21; the default is chosen from
/// the `tls` flag alone, which is why `dial("host")` cannot mean "explicit".
test "split_addr defaults to 990 for implicit tls and 21 otherwise" {
  assert_eq(@ftp.split_addr("example.com", 990), ("example.com", 990))
  assert_eq(@ftp.split_addr("example.com", 21), ("example.com", 21))
}

///|
/// An explicit port always wins over the default, so the test's ephemeral
/// ports reach the socket instead of being replaced by 21 or 990.
test "split_addr keeps an explicit port" {
  assert_eq(@ftp.split_addr("example.com:2121", 990), ("example.com", 2121))
  assert_eq(@ftp.split_addr("127.0.0.1:0", 21), ("127.0.0.1", 0))
}
