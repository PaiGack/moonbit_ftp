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
test "parse_int only accepts plain decimal digits" {
  assert_eq(parse_int("21"), Some(21))
  assert_eq(parse_int("0"), Some(0))
  assert_eq(parse_int(""), None)
  assert_eq(parse_int("2a"), None)
  assert_eq(parse_int("-1"), None)
  assert_eq(parse_int(" 1"), None)
}
