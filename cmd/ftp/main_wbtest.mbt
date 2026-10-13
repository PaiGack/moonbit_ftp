// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

///|
/// Whitebox tests for the CLI argument parser. The exit-code behaviour of
/// `main` is not testable in-process (it calls `exit(3)`), so the parser's
/// verdicts are pinned here instead: `Ok` means "run it", `Err` means "usage
/// error, exit 2", and a `help = true` result means "print usage, exit 0".
test "parse_args recognizes --help as a help request, not an unknown option" {
  for args in [["ftp", "--help"], ["ftp", "-h"]] {
    match parse_args(args) {
      Ok(parsed) => {
        assert_true(parsed.help)
        assert_eq(parsed.command, None)
      }
      Err(message) => fail("expected help, got error: \{message}")
    }
  }
}

///|
test "parse_args leaves help unset for a normal invocation" {
  match parse_args(["ftp", "ls", "/"]) {
    Ok(parsed) => {
      assert_false(parsed.help)
      assert_eq(parsed.command, Some("ls"))
      assert_eq(parsed.positional, ["/"])
    }
    Err(message) => fail("unexpected error: \{message}")
  }
}

///|
test "parse_args accepts --help alongside flags and a subcommand" {
  match parse_args(["ftp", "--host", "10.0.0.1", "--help", "ls", "/x"]) {
    Ok(parsed) => {
      assert_true(parsed.help)
      assert_eq(parsed.host, "10.0.0.1")
      assert_eq(parsed.command, Some("ls"))
    }
    Err(message) => fail("unexpected error: \{message}")
  }
}

///|
test "parse_args rejects unknown options and missing values" {
  for
    args in [
      ["ftp", "--bogus"],
      ["ftp", "-x"],
      ["ftp", "--host"],
      ["ftp", "--port", "abc"],
      ["ftp", "--timeout", "12x"],
    ] {
    match parse_args(args) {
      Err(_) => ()
      Ok(_) => fail("expected a usage error, got Ok")
    }
  }
}

///|
test "parse_args parses the documented flags" {
  match
    parse_args([
      "ftp", "--host", "127.0.0.1", "--port", "2121", "--user", "u", "--pass", "p",
      "--timeout", "1500", "--tls", "--trust-pasv-ip", "get", "/remote", "/local",
    ]) {
    Ok(parsed) => {
      assert_eq(parsed.host, "127.0.0.1")
      assert_eq(parsed.port, Some(2121))
      assert_eq(parsed.user, "u")
      assert_eq(parsed.password, "p")
      assert_eq(parsed.timeout_ms, 1500)
      assert_true(parsed.tls)
      assert_true(parsed.trust_pasv_ip)
      assert_eq(parsed.command, Some("get"))
      assert_eq(parsed.positional, ["/remote", "/local"])
    }
    Err(message) => fail("unexpected error: \{message}")
  }
}

///|
/// The environment is the default layer, and the reason it exists is that a
/// wrapper which *builds* `--host <value>` from an unset variable passes a bare
/// host name as a positional argument instead. These pin the layer's own
/// behaviour, which is what makes that impossible: unset means "keep the
/// built-in default", and a malformed number means the same thing rather than a
/// fatal error, because the environment is a convenience and the flag is still
/// the authority.
///
/// `@env.set_env_var` / `unset_env_var` are the only way to reach this from a
/// test, so the keys are set and removed around each case.
test "env_port and env_timeout treat unset and malformed values as absent" {
  let name = "FTP_SELFTEST_PORT"
  @env.unset_env_var(name)
  assert_eq(env_port(name), None)
  assert_eq(env_timeout(name), 30000)

  @env.set_env_var(name, "2121")
  assert_eq(env_port(name), Some(2121))
  assert_eq(env_timeout(name), 2121)

  // A typo in a shell profile must not make the tool unusable.
  @env.set_env_var(name, "abc")
  assert_eq(env_port(name), None)
  assert_eq(env_timeout(name), 30000)

  @env.unset_env_var(name)
  assert_eq(env_port(name), None)
}

///|
test "env_or falls back only when the variable is unset" {
  let name = "FTP_SELFTEST_HOST"
  @env.unset_env_var(name)
  assert_eq(env_or(name, "127.0.0.1"), "127.0.0.1")

  @env.set_env_var(name, "10.0.0.1")
  assert_eq(env_or(name, "127.0.0.1"), "10.0.0.1")

  // An explicitly *empty* value is a value: only an unset variable falls back,
  // so a caller that means "" can say so without losing the flag.
  @env.set_env_var(name, "")
  assert_eq(env_or(name, "127.0.0.1"), "")

  @env.unset_env_var(name)
  assert_eq(env_or(name, "127.0.0.1"), "127.0.0.1")
}

///|
/// The regression that matters: with `FTP_HOST` unset but `--host` on the
/// command line, the flag must still be the one that wins, in the right slot.
/// Before the environment layer existed the failure mode was the opposite --
/// an unset variable *handed the flag to* the next argv entry.
test "an explicit --host beats an unset FTP_HOST default" {
  @env.unset_env_var("FTP_HOST")
  match parse_args(["ftp", "--host", "10.0.0.1", "ls", "/"]) {
    Ok(parsed) => {
      assert_eq(parsed.host, "10.0.0.1")
      assert_eq(parsed.command, Some("ls"))
      assert_eq(parsed.positional, ["/"])
    }
    Err(message) => fail("unexpected error: \{message}")
  }
}

///|
/// Pin the *wiring*, not just the helpers: `parse_args` must actually consult
/// the environment. Asserting `env_or` in isolation stayed green when the
/// call site was reverted to the literal, which is exactly the "test the
/// helper, ship the bug" shape this file already lost a round to.
test "parse_args reads FTP_HOST / FTP_USER from the environment" {
  @env.set_env_var("FTP_HOST", "10.9.8.7")
  @env.set_env_var("FTP_USER", "someone")
  @env.set_env_var("FTP_PORT", "2121")
  match parse_args(["ftp", "ls", "/"]) {
    Ok(parsed) => {
      assert_eq(parsed.host, "10.9.8.7")
      assert_eq(parsed.user, "someone")
      assert_eq(parsed.port, Some(2121))
    }
    Err(message) => fail("unexpected error: \{message}")
  }
  // An explicit flag still wins over the environment.
  match parse_args(["ftp", "--host", "1.2.3.4", "ls", "/"]) {
    Ok(parsed) => assert_eq(parsed.host, "1.2.3.4")
    Err(message) => fail("unexpected error: \{message}")
  }
  @env.unset_env_var("FTP_HOST")
  @env.unset_env_var("FTP_USER")
  @env.unset_env_var("FTP_PORT")
  match parse_args(["ftp", "ls", "/"]) {
    Ok(parsed) => {
      assert_eq(parsed.host, "127.0.0.1")
      assert_eq(parsed.user, "anonymous")
      assert_eq(parsed.port, None)
    }
    Err(message) => fail("unexpected error: \{message}")
  }
}

///|
test "parse_int only accepts plain decimal digits" {
  assert_eq(parse_int("21"), Some(21))
  assert_eq(parse_int("0"), Some(0))
  assert_eq(parse_int(""), None)
  assert_eq(parse_int("2a"), None)
  assert_eq(parse_int("-1"), None)
  assert_eq(parse_int(" 1"), None)
}
