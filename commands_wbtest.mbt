// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

// Tests for the one-command wrappers in `commands.mbt`.
//
// Every function there is the same shape — lock, send one or two commands
// through `cmd_format` / `cmd_expect`, check the status code — so the contract
// worth pinning is per command: the exact rendering of the `{}` substitution,
// the status code the server has to answer with, and the two-step `RNFR` /
// `RNTO` sequence. The `extract_quoted` helper that `current_dir` depends on is
// pure and gets a table of its own.
//
// The scripted control channel from `ftp_test_helpers_wbtest.mbt` supplies the
// replies and records the commands; no daemon is involved.

///|
/// `change_dir` sends `CWD <path>` and requires `250`.
async test "change_dir sends CWD and requires 250" {
  let (client, sink) = scripted_client(
    "250 Directory successfully changed.\r\n",
  )
  change_dir(client, "/pub/incoming") catch {
    e => fail("change_dir: \{e}")
  }
  assert_eq(sink.lines, ["CWD /pub/incoming"])
}

///|
/// A path with spaces must reach the server verbatim: the substitution happens
/// after the argument is validated, and only the first `{}` is replaced.
async test "change_dir keeps spaces and braces in the path" {
  let (client, sink) = scripted_client(
    "250 Directory successfully changed.\r\n",
  )
  change_dir(client, "/incoming/{odd} dir name") catch {
    e => fail("change_dir: \{e}")
  }
  assert_eq(sink.lines, ["CWD /incoming/{odd} dir name"])
}

///|
/// A `CWD` reply other than `250` is a server error carrying the original code.
async test "change_dir rejects a non 250 reply" {
  let (client, _) = scripted_client("550 Failed to change directory.\r\n")
  let raised = try {
    change_dir(client, "/nope")
    None
  } catch {
    FtpError::ServerError(code~, msg~) => Some((code, msg))
    _ => None
  }
  assert_eq(raised, Some((550, "Failed to change directory.")))
}

///|
/// `change_dir_to_parent` sends a bare `CDUP` and requires `250`.
async test "change_dir_to_parent sends CDUP" {
  let (client, sink) = scripted_client(
    "250 Directory successfully changed.\r\n",
  )
  change_dir_to_parent(client) catch {
    e => fail("CDUP: \{e}")
  }
  assert_eq(sink.lines, ["CDUP"])
  // `CDUP` takes no argument, so nothing follows the command name.
  assert_false(sink.lines[0].contains(" "))
}

///|
/// `current_dir` sends `PWD` and unwraps the quoted path of the `257` reply.
async test "current_dir returns the quoted path of a 257 reply" {
  let (client, sink) = scripted_client(
    "257 \"/pub/incoming\" is the current directory\r\n",
  )
  let dir = current_dir(client) catch { e => fail("current_dir: \{e}") }
  assert_eq(sink.lines, ["PWD"])
  assert_eq(dir, "/pub/incoming")
}

///|
/// A `257` without a quoted path cannot be turned into a directory, so it is a
/// parse error rather than a silent empty string.
async test "current_dir rejects a 257 reply with no quotes" {
  let (client, _) = scripted_client("257 no quotes here\r\n")
  let raised = try {
    ignore(current_dir(client))
    None
  } catch {
    FtpError::ParseError(msg~) => Some(msg)
    _ => None
  }
  assert_eq(raised, Some("invalid PWD response"))
}

///|
/// `make_dir` sends `MKD <path>` and requires `257` (the created path).
async test "make_dir sends MKD and requires 257" {
  let (client, sink) = scripted_client("257 \"/new\" created\r\n")
  make_dir(client, "/new") catch {
    e => fail("make_dir: \{e}")
  }
  assert_eq(sink.lines, ["MKD /new"])
}

///|
/// `remove_dir` sends `RMD <path>` and requires `250`, not `257`.
async test "remove_dir sends RMD and requires 250" {
  let (client, sink) = scripted_client(
    "250 Remove directory operation successful.\r\n",
  )
  remove_dir(client, "/old") catch {
    e => fail("remove_dir: \{e}")
  }
  assert_eq(sink.lines, ["RMD /old"])
}

///|
/// `delete` sends `DELE <path>` and requires `250`.
async test "delete sends DELE and requires 250" {
  let (client, sink) = scripted_client("250 Delete operation successful.\r\n")
  delete(client, "/tmp/old.txt") catch {
    e => fail("delete: \{e}")
  }
  assert_eq(sink.lines, ["DELE /tmp/old.txt"])
}

///|
/// `rename` is a two-step exchange: `RNFR` first, and `RNTO` only after the
/// server answered `350`.
async test "rename sends RNFR then RNTO" {
  let (client, sink) = scripted_client(
    "350 Ready for destination name.\r\n250 Rename successful.\r\n",
  )
  rename(client, "/a.txt", "/b.txt") catch {
    e => fail("rename: \{e}")
  }
  assert_eq(sink.lines, ["RNFR /a.txt", "RNTO /b.txt"])
}

///|
/// A refused `RNFR` must stop the exchange: sending `RNTO` anyway would rename
/// whatever the previous `RNFR` had selected, or be rejected as a protocol
/// error — and either way it would desynchronise the session.
async test "rename does not send RNTO when RNFR is refused" {
  let (client, sink) = scripted_client("550 File not found.\r\n")
  let raised = try {
    rename(client, "/missing.txt", "/b.txt")
    None
  } catch {
    FtpError::ServerError(code~, ..) => Some(code)
    _ => None
  }
  assert_eq(raised, Some(550))
  assert_eq(sink.lines, ["RNFR /missing.txt"])
}

///|
/// A refused `RNTO` surfaces the second code, not the `350` that opened the
/// exchange.
async test "rename surfaces a rejected RNTO" {
  let (client, sink) = scripted_client(
    "350 Ready for destination name.\r\n550 Rename failed.\r\n",
  )
  let raised = try {
    rename(client, "/a.txt", "/b.txt")
    None
  } catch {
    FtpError::ServerError(code~, ..) => Some(code)
    _ => None
  }
  assert_eq(raised, Some(550))
  assert_eq(sink.lines, ["RNFR /a.txt", "RNTO /b.txt"])
}

///|
/// `no_op` sends `NOOP` and requires `200`.
async test "no_op sends NOOP and requires 200" {
  let (client, sink) = scripted_client("200 NOOP ok.\r\n")
  no_op(client) catch {
    e => fail("no_op: \{e}")
  }
  assert_eq(sink.lines, ["NOOP"])
}

///|
/// `logout` sends `REIN` and requires `220`: the authentication state is
/// dropped but the control connection stays open.
async test "logout sends REIN and requires 220" {
  let (client, sink) = scripted_client("220 Service ready for new user.\r\n")
  logout(client) catch {
    e => fail("logout: \{e}")
  }
  assert_eq(sink.lines, ["REIN"])
}

///|
/// `quit` sends `QUIT` and accepts any of the three codes a server may use to
/// close the control connection.
async test "quit accepts 221 200 and 220" {
  for code in ["221 Goodbye.\r\n", "200 Bye.\r\n", "220 See you.\r\n"] {
    let (client, sink) = scripted_client(code)
    quit(client) catch {
      e => fail("quit refused \{code}: \{e}")
    }
    assert_eq(sink.lines, ["QUIT"])
  }
}

///|
/// `quit` is idempotent: the client records that it already said goodbye, so a
/// second call must not put a second `QUIT` on the wire.
async test "quit is idempotent" {
  let (client, sink) = scripted_client("221 Goodbye.\r\n")
  quit(client) catch {
    e => fail("first quit: \{e}")
  }
  assert_true(client.is_closed())
  // A second call returns immediately; if it sent `QUIT` again the scripted
  // channel would have to supply another reply.
  quit(client) catch {
    e => fail("second quit: \{e}")
  }
  assert_eq(sink.lines, ["QUIT"])
}

///|
/// A `QUIT` reply that is none of the accepted codes still marks the client
/// closed, so a retry cannot reuse a connection the server has dropped.
async test "quit marks the client closed even when the reply is refused" {
  let (client, _) = scripted_client("500 Unknown command.\r\n")
  ignore(quit(client) catch { _ => () })
  assert_true(client.is_closed())
}

///|
/// `extract_quoted` takes the text between the first pair of double quotes,
/// which is how the `257` reply encodes a path.
///
/// The paths are the ones real servers emit; the pair-of-quotes rule is
/// upstream's, so a path containing a `"` is not a supported case and is not
/// tested as if it were.
test "extract_quoted takes the first quoted substring" {
  let cases : Array[(String, String?)] = [
    ("257 \"/pub\" is the current directory", Some("/pub")),
    ("257 \"/\"", Some("/")),
    ("257 \"/incoming\" created", Some("/incoming")),
    // An empty quoted pair is still a match, not a failure.
    ("257 \"\"", Some("")),
    // No quotes at all.
    ("257 no quotes", None),
    // Only an opening quote.
    ("257 \"/unterminated", None),
    // The empty message.
    ("", None),
  ]
  for case in cases {
    let (input, expected) = case
    assert_eq(extract_quoted(input), expected)
  }
}

///|
/// `extract_quoted` uses the *first* pair of quotes, so text after the closing
/// quote is ignored — the trap is a trailing comment that also contains one.
test "extract_quoted stops at the closing quote" {
  assert_eq(extract_quoted("257 \"/pub\" and \"/other\" too"), Some("/pub"))
}
