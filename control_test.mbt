// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
//
// W2 acceptance tests for the control channel. These are the first tests that
// drive a real socket instead of an in-memory value, so they pin the two
// behaviours the workplan calls out as easy to get wrong:
//
//   1. a multi line reply ends on the line that repeats the code *without* a
//      dash (getting this wrong makes FEAT swallow the next reply), and
//   2. `check_for_command_injection` runs before a single byte is written.

///|
/// Dial the mock and wrap the socket in a `Control`, mirroring how `dial`
/// wires the channel. The raw socket is returned too so the caller can close
/// it, which is what unblocks the server side `read_until`.
async fn connect_control(server : MockServer) -> (@socket.Tcp, Control) {
  let conn = @socket.Tcp::connect(server.addr())
  (conn, Control::without_debug(conn, conn, "127.0.0.1"))
}

///|
/// Run `body` against a scripted server, forwarding the server handle.
async fn with_mock(
  rules : Array[(String, String)],
  body : async (MockServer, Control) -> Unit,
  fallback? : String? = None,
) -> Unit {
  let server = MockServer::start(mock_rules(rules), fallback~)
  // The timeout guards against a scripting mistake turning into a hung test
  // run: a real regression should fail, not block CI for ten minutes.
  ignore(
    @async.with_timeout_opt(5000, () => {
      @async.with_task_group(root => {
        root.spawn_bg(() => server.serve_one())
        let (conn, control) = connect_control(server)
        defer conn.close()
        body(server, control)
      })
    }),
  )
}

///|
async test "single line reply splits code from message" {
  with_mock([], (_, control) => {
    let response = read_response(control)
    assert_eq(response.code(), 220)
    assert_eq(response.message(), "FTP Server ready.")
  })
}

///|
async test "multi line reply joins the body and excludes the status lines" {
  let features = "211-Features:\r\n FEAT\r\n PASV\r\n211 End"
  with_mock([("NOOP", features)], (server, control) => {
    // Consume the greeting first, exactly like `dial` does.
    assert_eq(read_response(control).code(), 220)
    let response = cmd_expect(control, "NOOP", [211])
    assert_eq(response.code(), 211)
    // Go's `textproto.ReadResponse` keeps the text of the first and of the
    // terminating status line, joined by `\n`. Verified against Go 1.27.
    assert_eq(response.message(), "Features:\n FEAT\n PASV\nEnd")
    assert_eq(server.commands(), ["NOOP"])
  })
}

///|
async test "a line repeating the code without a dash is not a continuation" {
  // The trap: `211 End` must terminate the reply, not be collected as body.
  // If the end test were "starts with the code" the body would grow a bogus
  // `End` line and the parser would keep reading into the next reply.
  let features = "211-Features:\r\n UTF8\r\n211 End"
  with_mock([("NOOP", features), ("NOOP2", "200 Two hundred ok")], (_, control) => {
    assert_eq(read_response(control).code(), 220)
    assert_eq(
      cmd_expect(control, "NOOP", [211]).message(),
      "Features:\n UTF8\nEnd",
    )
    // The follow up reply is still readable, i.e. the parser did not
    // over-consume the stream.
    assert_eq(cmd_expect(control, "NOOP2", [200]).code(), 200)
  })
}

///|
async test "status mismatch raises ServerError carrying the original message" {
  with_mock([("NOOP", "550 No such file or directory")], (_, control) => {
    assert_eq(read_response(control).code(), 220)
    let raised = try {
      ignore(cmd_expect(control, "NOOP", [200]))
      None
    } catch {
      FtpError::ServerError(code~, msg~) => Some((code, msg))
      _ => None
    }
    assert_eq(raised, Some((550, "No such file or directory")))
  })
}

///|
async test "an empty expected list accepts any code" {
  with_mock([("NOOP", "500 Unknown command")], (_, control) => {
    assert_eq(read_response(control).code(), 220)
    // `expected: []` is the MoonBit spelling of upstream's `cmd(..., -1)`.
    assert_eq(cmd_expect(control, "NOOP", []).code(), 500)
  })
}

///|
async test "check_for_command_injection rejects CR and LF" {
  let raised_cr = try {
    check_for_command_injection("a\rb")
    None
  } catch {
    FtpError::InvalidCommand(_) => Some(true)
    _ => None
  }
  assert_eq(raised_cr, Some(true))
  let raised_lf = try {
    check_for_command_injection("a\nb")
    None
  } catch {
    FtpError::InvalidCommand(_) => Some(true)
    _ => None
  }
  assert_eq(raised_lf, Some(true))
}

///|
async test "an injected command writes nothing to the socket" {
  // The server has no script for any verb, so it answers only the greeting.
  // The assertion is that the malicious line never reaches it.
  with_mock([], (server, control) => {
    assert_eq(read_response(control).code(), 220)
    let raised = try {
      ignore(cmd(control, "CWD /tmp\r\nDELE secret"))
      None
    } catch {
      FtpError::InvalidCommand(_) => Some(true)
      _ => None
    }
    assert_eq(raised, Some(true))
    assert_false(server.saw_any_command())
  })
}

///|
async test "send_line appends CRLF and is read back verbatim" {
  with_mock([("NOOP", "200 ok")], (server, control) => {
    assert_eq(read_response(control).code(), 220)
    control.send_line("NOOP")
    // `serve_one` reads up to the CRLF, so a full reply arriving proves the
    // line was terminated exactly once.
    assert_eq(read_response(control).code(), 200)
    assert_eq(server.commands(), ["NOOP"])
  })
}

///|
async test "a code line with no separator is a short response" {
  // `200` alone (three bytes, no space) is rejected by Go's textproto rather
  // than yielding an empty message; `200 ` is a valid empty message.
  with_mock([("NOOP", "200")], (_, control) => {
    assert_eq(read_response(control).code(), 220)
    let raised = try {
      ignore(cmd_expect(control, "NOOP", [200]))
      None
    } catch {
      FtpError::ParseError(msg~) => Some(msg)
      _ => None
    }
    assert_eq(raised, Some("short response: 200"))
  })
}

///|
async test "a bare code plus space yields an empty message" {
  with_mock([("NOOP", "200 ")], (_, control) => {
    assert_eq(read_response(control).code(), 220)
    assert_eq(cmd_expect(control, "NOOP", [200]).message(), "")
  })
}

///|
async test "FEAT parsing ignores the framing lines" {
  // The body now carries `Features:` and `End`; both must be filtered out by
  // the leading space test, otherwise `FEATURES:` and `END` would be cached
  // as capabilities and change the negotiation downstream.
  let features = parse_features("Features:\n FEAT\n PASV\n UTF8\nEnd")
  assert_true(features.contains("FEAT"))
  assert_true(features.contains("PASV"))
  assert_true(features.contains("UTF8"))
  assert_false(features.contains("FEATURES:"))
  assert_false(features.contains("END"))
  assert_eq(features.length(), 3)
}

///|
async test "FEAT parsing drops a feature line with no leading space" {
  // A server that omits the RFC-mandated space gets that line ignored, which
  // is exactly what upstream does (it never reaches the trim).
  let features = parse_features("Features:\nFEAT\nEnd")
  assert_false(features.contains("FEAT"))
  assert_false(features.contains("END"))
}

///|
async test "MLST merges the fact lines of the middle of the reply" {
  with_mock(
    [
      (
        "MLST", "250-File details\r\n Type=file;Size=1024;Modify=20220813133357; lo\r\n250 End",
      ),
    ],
    (_, control) => {
      assert_eq(read_response(control).code(), 220)
      let response = cmd_expect(control, "MLST /lo", [250])
      let lines = response.message().split("\n").collect()
      // `<head>\n<facts>\n<tail>`: exactly what upstream slices with
      // `lines[1 : lc-1]`.
      assert_eq(lines.length(), 3)
      assert_eq(
        lines[1].trim_start(),
        "Type=file;Size=1024;Modify=20220813133357; lo",
      )
      let entry = parse_rfc3659_line(lines[1].trim_start().to_owned())
      assert_true(entry is Some(_))
    },
  )
}

///|
async test "a two line MLST reply is rejected as an invalid response" {
  // `250-...\n250 End` has no room for a fact line; upstream rejects it.
  with_mock([("MLST", "250-File details\r\n250 End")], (_, control) => {
    assert_eq(read_response(control).code(), 220)
    let response = cmd_expect(control, "MLST /lo", [250])
    assert_eq(response.message().split("\n").collect().length(), 2)
  })
}

///|
async test "a multi line reply with a blank body line still collects it" {
  // `211-\r\n\r\n211 End` has an empty continuation line; Go joins it as an
  // empty entry, so the body is `"\\n\\nEnd"` and the line count stays 3.
  with_mock([("NOOP", "211-\r\n\r\n211 End")], (_, control) => {
    assert_eq(read_response(control).code(), 220)
    let response = cmd_expect(control, "NOOP", [211])
    assert_eq(response.message(), "\n\nEnd")
    assert_eq(response.message().split("\n").collect().length(), 3)
  })
}
