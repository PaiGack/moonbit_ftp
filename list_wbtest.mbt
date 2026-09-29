// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

// Tests for the `NLST` / `LIST` / `MLST` wrappers in `list.mbt`.
//
// The wrapper itself is three lines long, so what is worth pinning is the
// contract around it: which command goes on the wire (including `MLSD` versus
// `LIST -a` versus `LIST`), which status code is required, how the payload
// becomes entries, and how a listing failure is reported. The scripted
// control channel plus a real loopback data listener from
// `ftp_test_helpers_wbtest.mbt` cover all four without a mock FTP daemon.

///|
/// `name_list` sends `NLST <path>` and keeps one name per non-empty line.
async test "name_list sends NLST and splits the payload into names" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) +
    "150 Here comes the directory listing.\r\n226 Directory send OK.\r\n"
  let (client, sink) = scripted_client(script)
  let names = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      serve_payload(listener, "hello.txt\nsub\n")
    })
    name_list(client, "/pub") catch {
      e => fail("name_list: \{e}")
    }
  })
  assert_eq(names, ["hello.txt", "sub"])
  // The `{}` substitution is what makes the path reach the server; a bare
  // `NLST {}` would be sent verbatim by a broken formatter.
  assert_eq(sink.lines, ["EPSV", "NLST /pub"])
}

///|
/// Blank lines in an `NLST` payload are dropped, not turned into empty names.
///
/// Some servers pad the listing with a trailing newline; upstream filters with
/// `line != ""`, so a name list never carries an empty entry.
async test "name_list drops empty lines" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) +
    "150 Here comes the directory listing.\r\n226 Directory send OK.\r\n"
  let (client, _) = scripted_client(script)
  let names = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      serve_payload(listener, "\n  hello.txt  \n\nsub\n\n")
    })
    name_list(client, "/") catch {
      e => fail("name_list: \{e}")
    }
  })
  // Names are trimmed, and the CRLF a real server leaves behind disappears.
  assert_eq(names, ["hello.txt", "sub"])
}

///|
/// With `MLST` advertised, `list` sends `MLSD` and parses RFC 3659 facts.
async test "list prefers MLSD when the server supports MLST" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) +
    "150 Here comes the directory listing.\r\n226 Directory send OK.\r\n"
  let (client, sink) = scripted_client(script, mlst_supported=true)
  let entries = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      serve_payload(
        listener,
        "type=file;size=12;modify=20240101000000; hello.txt\r\n" +
        "type=dir;modify=20240101000000; sub\r\n",
      )
    })
    list(client, "/") catch {
      e => fail("list: \{e}")
    }
  })
  assert_eq(sink.lines, ["EPSV", "MLSD /"])
  assert_eq(entries.length(), 2)
  assert_eq(entries[0].name, "hello.txt")
  assert_eq(entries[0].type_, EntryType::File)
  assert_eq(entries[0].size, 12UL)
  assert_eq(entries[1].name, "sub")
  assert_eq(entries[1].type_, EntryType::Folder)
}

///|
/// `force_list_hidden` sends `LIST -a` and stays on the `LIST` path even when
/// the server advertised `MLST`: the flag exists precisely for the servers
/// whose `MLSD` hides dot files.
async test "list sends LIST -a when force_list_hidden is set" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) +
    "150 Here comes the directory listing.\r\n226 Directory send OK.\r\n"
  let (client, sink) = scripted_client(script, mlst_supported=true)
  client.options.set_force_list_hidden(true)
  let entries = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      serve_payload(
        listener, "drwxr-xr-x    2 0        0            4096 Jan 01 00:00 sub\r\n",
      )
    })
    list(client, "/") catch {
      e => fail("list: \{e}")
    }
  })
  assert_eq(sink.lines, ["EPSV", "LIST -a /"])
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].name, "sub")
  assert_eq(entries[0].type_, EntryType::Folder)
}

///|
/// Without `MLST`, `list` sends a plain `LIST` and reads it with the four
/// parser fallback.
///
/// The `total 1` header is deliberate: real servers emit it, no parser
/// recognises it, and upstream skips unrecognised lines instead of failing the
/// whole listing.
async test "list falls back to LIST and skips unparsable lines" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) +
    "150 Here comes the directory listing.\r\n226 Directory send OK.\r\n"
  let (client, sink) = scripted_client(script)
  let entries = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      serve_payload(
        listener,
        "total 1\r\n" +
        "-rw-r--r--    1 0        0              12 Aug 19  1996 message.ftp\r\n" +
        "this line matches none of the four parsers\r\n",
      )
    })
    list(client, "/") catch {
      e => fail("list: \{e}")
    }
  })
  assert_eq(sink.lines, ["EPSV", "LIST /"])
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].name, "message.ftp")
  assert_eq(entries[0].type_, EntryType::File)
  assert_eq(entries[0].time.year(), 1996)
}

///|
/// A `LIST` reply that is not `150`/`125` must fail the call, and the error
/// must carry the server's own status code rather than a generic parse error.
async test "list raises ServerError when the transfer command is refused" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) + "550 Permission denied.\r\n"
  let (client, _) = scripted_client(script)
  let raised = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      // The data connection is opened before the transfer command, so the
      // server end must be accepted even though the listing will fail.
      let (conn, _) = listener.accept()
      conn.close()
    })
    let result = try {
      ignore(list(client, "/"))
      None
    } catch {
      FtpError::ParseError(msg~) => Some(msg)
      _ => None
    }
    result
  })
  assert_eq(raised, Some("transfer command failed"))
}

///|
/// `EPSV` failing once makes the session fall back to `PASV` for good.
///
/// This is upstream's `skipEPSV`: a server that answers `EPSV` with an error
/// would otherwise pay a failed round trip on every single transfer.
async test "list falls back to PASV after EPSV is refused" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = "502 EPSV not implemented.\r\n" +
    pasv_reply(port) +
    "150 Here comes the directory listing.\r\n226 Directory send OK.\r\n"
  let (client, sink) = scripted_client(script)
  let entries = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      serve_payload(listener, "type=file; hello.txt\r\n")
    })
    list(client, "/") catch {
      e => fail("list: \{e}")
    }
  })
  assert_eq(sink.lines, ["EPSV", "PASV", "LIST /"])
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].name, "hello.txt")
}

///|
/// The `226` that terminates a transfer is read, never requested.
///
/// Sending anything here (an empty line, a `NOOP`) leaves the session one
/// reply behind; the recorded command list is the regression guard.
async test "list reads the 226 instead of sending a command for it" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) +
    "150 Here comes the directory listing.\r\n226 Directory send OK.\r\n"
  let (client, sink) = scripted_client(script)
  ignore(
    @async.with_task_group(async fn(group) {
      group.spawn_bg(no_wait=true, async fn() {
        serve_payload(listener, "-rw-r--r-- 1 0 0 12 Jan 01 00:00 a.txt\r\n")
      })
      list(client, "/") catch {
        e => fail("list: \{e}")
      }
    }),
  )
  assert_eq(sink.lines, ["EPSV", "LIST /"])
  assert_eq(sink.pending, "")
}

///|
/// A `226` is accepted, and so is a `250`; anything else is a server error.
async test "check_data_shut accepts 226 and 250 but rejects others" {
  let ok = scripted_control("226 Directory send OK.\r\n")
  check_data_shut(Session::new(ok.0)) catch {
    e => fail("226 rejected: \{e}")
  }

  let also_ok = scripted_control("250 Requested file action okay.\r\n")
  check_data_shut(Session::new(also_ok.0)) catch {
    e => fail("250 rejected: \{e}")
  }

  let bad = scripted_control("550 Failed to open file.\r\n")
  let raised = try {
    check_data_shut(Session::new(bad.0))
    None
  } catch {
    FtpError::ServerError(code~, msg~) => Some((code, msg))
    _ => None
  }
  assert_eq(raised, Some((550, "Failed to open file.")))
}

///|
/// `get_entry` sends `MLST <path>` and requires the `250` code.
async test "get_entry sends MLST and requires the 250 code" {
  let script = "250-Listing /hello.txt\r\n" +
    " header the caller must not see\r\n" +
    " type=file;size=951; hello.txt\r\n" +
    "250 End\r\n"
  let (client, sink) = scripted_client(script)
  let entry = get_entry(client, "/hello.txt") catch {
    e => fail("get_entry: \{e}")
  }
  assert_eq(sink.lines, ["MLST /hello.txt"])
  assert_eq(entry.name, "hello.txt")
  assert_eq(entry.type_, EntryType::File)
  assert_eq(entry.size, 951UL)
}

///|
/// RFC 3659 allows the facts of a single entry to span several lines, so the
/// middle lines are merged into one entry instead of being read one by one.
///
/// The first line of the body is *skipped*: `read_response` keeps the text of
/// the `250-` framing line, so the body is
/// `<head>\n<facts>...\n<tail>` and the loop starts at index 1 — upstream's
/// `lines[1:lc-1]`. A real server puts a display header there, which is why
/// the value is dropped rather than parsed.
async test "get_entry merges the fact lines of a single entry" {
  let script = "250-Listing /hello.txt\r\n" +
    " .\r\n" +
    " type=file;size=951; hello.txt\r\n" +
    "250 End\r\n"
  let (client, _) = scripted_client(script)
  let entry = get_entry(client, "/hello.txt") catch {
    e => fail("get_entry: \{e}")
  }
  assert_eq(entry.name, "hello.txt")
  assert_eq(entry.size, 951UL)
}

///|
/// A reply with fewer than three lines cannot carry a fact line, so upstream
/// reports it as an invalid response rather than an empty entry.
async test "get_entry rejects a reply with no fact line" {
  let script = "250-Listing /hello.txt\r\n250 End\r\n"
  let (client, _) = scripted_client(script)
  let raised = try {
    ignore(get_entry(client, "/hello.txt"))
    None
  } catch {
    FtpError::ParseError(msg~) => Some(msg)
    _ => None
  }
  assert_eq(raised, Some("invalid response"))
}

///|
/// A framing-only reply is parsed but yields no entry, which surfaces as
/// `UnsupportedListLine` carrying the original body.
async test "get_entry raises UnsupportedListLine when no fact line parses" {
  let script = "250-Listing /hello.txt\r\n" +
    " not a facts line at all\r\n" +
    "250 End\r\n"
  let (client, _) = scripted_client(script)
  let raised = try {
    ignore(get_entry(client, "/hello.txt"))
    None
  } catch {
    FtpError::UnsupportedListLine(_) => Some(true)
    _ => None
  }
  assert_eq(raised, Some(true))
}

///|
/// The `MLST` reply must carry the `250` code; a `450` is a failure.
async test "get_entry requires the 250 status code" {
  let script = "450 File unavailable.\r\n"
  let (client, _) = scripted_client(script)
  let raised = try {
    ignore(get_entry(client, "/hello.txt"))
    None
  } catch {
    FtpError::ServerError(code~, ..) => Some(code)
    _ => None
  }
  assert_eq(raised, Some(450))
}

///|
/// `set_transfer_type` sends the `TYPE` argument from `TransferType`, so the
/// enum and the wire format cannot drift apart.
async test "set_transfer_type sends the TYPE argument" {
  let (client, sink) = scripted_client("200 Switching to Binary mode.\r\n")
  set_transfer_type(client, TransferType::Binary) catch {
    e => fail("TYPE I: \{e}")
  }
  assert_eq(sink.lines, ["TYPE I"])

  let (client, sink) = scripted_client("200 Switching to ASCII mode.\r\n")
  set_transfer_type(client, TransferType::ASCII) catch {
    e => fail("TYPE A: \{e}")
  }
  assert_eq(sink.lines, ["TYPE A"])
}

///|
/// A `TYPE` reply other than `200` is a server error.
async test "set_transfer_type rejects a non 200 reply" {
  let (client, _) = scripted_client("504 Command not implemented.\r\n")
  let raised = try {
    set_transfer_type(client, TransferType::Binary)
    None
  } catch {
    FtpError::ServerError(code~, ..) => Some(code)
    _ => None
  }
  assert_eq(raised, Some(504))
}

///|
/// A `226` that never arrives turns the listing into an error carrying the
/// closing failure, and `NLST` uses the same aggregation as `LIST`.
async test "name_list reports a missing 226" {
  let listener = data_listener()
  let port = listener.addr.port()
  // The data connection delivers a payload but the control channel never
  // answers `226`; the wrap-up read then hits end of input.
  let script = epsv_reply(port) + "150 Here comes the directory listing.\r\n"
  let (client, sink) = scripted_client(script)
  let raised = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      serve_payload(listener, "hello.txt\n")
    })
    try {
      ignore(name_list(client, "/pub"))
      false
    } catch {
      _ => true
    }
  })
  assert_true(raised)
  assert_eq(sink.lines, ["EPSV", "NLST /pub"])
}

///|
/// In `MLSD` mode an unparsable line is *skipped*, not fatal: real servers
/// interleave `total 1` headers and other noise that the RFC 3659 parser does
/// not recognise.
async test "list in MLSD mode skips unparsable lines" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) +
    "150 Here comes the directory listing.\r\n226 Directory send OK.\r\n"
  let (client, sink) = scripted_client(script, mlst_supported=true)
  let entries = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      // A blank line, a `total` header and a real fact line.
      serve_payload(listener, "\ntotal 1\ntype=file;Size=42; hello.txt\n")
    })
    list(client, "/pub") catch {
      _ => fail("list")
    }
  })
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].name, "hello.txt")
  assert_eq(entries[0].size, 42UL)
  assert_eq(sink.lines, ["EPSV", "MLSD /pub"])
}

///|
/// `get_entry` merges a multi line `MLST` reply into one entry, and ignores a
/// blank fact line in the middle — some servers pad the reply.
async test "get_entry merges the fact lines and skips a blank one" {
  let script = "250-File details\r\n" +
    " \r\n" +
    " type=file;Size=1024;Modify=20220813133357; hello.txt\r\n" +
    "250 End\r\n"
  let (client, _) = scripted_client(script)
  let entry = get_entry(client, "/hello.txt") catch { _ => fail("get_entry") }
  assert_eq(entry.name, "hello.txt")
  assert_eq(entry.size, 1024UL)
  assert_eq(entry.type_, EntryType::File)
}

///|
/// A `MLST` reply whose fact lines do not name the same file is a merge
/// failure, not a silently wrong entry.
async test "get_entry rejects mismatched continuation facts" {
  let script = "250-File details\r\n" +
    " type=file;Size=1; a\r\n" +
    " type=file;Size=2; b\r\n" +
    "250 End\r\n"
  let (client, _) = scripted_client(script)
  let raised = try {
    ignore(get_entry(client, "/a"))
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}

///|
/// A `MLST` reply with no fact line at all (just the framing) is rejected: it
/// cannot describe a file.
async test "get_entry rejects an empty fact body" {
  let script = "250-File details\r\n250 End\r\n"
  let (client, _) = scripted_client(script)
  let raised = try {
    ignore(get_entry(client, "/a"))
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}

///|
/// A reply shorter than `<head>\n<facts>\n<tail>` is an invalid response, per
/// upstream's `lc < 3` check.
async test "get_entry rejects a two line reply" {
  let script = "250-Nothing here\r\n250 End\r\n"
  let (client, _) = scripted_client(script)
  let raised = try {
    ignore(get_entry(client, "/a"))
    false
  } catch {
    FtpError::ParseError(msg~) => msg == "invalid response"
    _ => false
  }
  assert_true(raised)
}

///|
/// A broken data connection is recorded and the listing still runs the `226`
/// wrap-up, so the aggregated error names *both* failures — the transfer half
/// and the control half. That is the `errors.Join` shape from upstream.
async test "list aggregates a read failure and the wrap-up failure" {
  let listener = data_listener()
  let port = listener.addr.port()
  // No `226` follows, so the wrap-up read fails too.
  let script = epsv_reply(port) + "150 Here comes the directory listing.\r\n"
  let (client, sink) = scripted_client(script)
  let found = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      // Accept and close immediately: the read then sees a truncated stream
      // rather than a clean end of payload.
      let (conn, _) = listener.accept()
      conn.close()
    })
    try {
      ignore(list(client, "/pub"))
      false
    } catch {
      _ => true
    }
  })
  assert_true(found)
  assert_eq(sink.lines, ["EPSV", "LIST /pub"])
}

///|
/// A `read_payload` failure on `NLST` is reported the same way, and the
/// command still went out with the substituted path.
async test "name_list reports a data connection failure" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) + "150 Here comes the directory listing.\r\n"
  let (client, sink) = scripted_client(script)
  let found = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (conn, _) = listener.accept()
      conn.close()
    })
    try {
      ignore(name_list(client, "/pub"))
      false
    } catch {
      _ => true
    }
  })
  assert_true(found)
  assert_eq(sink.lines, ["EPSV", "NLST /pub"])
}

///|
/// `read_payload` records a read failure and returns the empty payload so the
/// caller can still run the `226` wrap-up: raising here would skip it and
/// desynchronise the session for every later command.
async test "read_payload records a broken reader and returns empty" {
  let errors : Array[Error] = []
  let conn : DataConn = {
    reader: failing_source(),
    writer: NullWriter::{ },
    closer: () => (),
  }
  let payload = read_payload(conn, errors)
  assert_eq(payload, "")
  assert_eq(errors.length(), 1)
}

///|
/// A writer that discards everything, for the `DataConn` fixtures that only
/// ever read.
struct NullWriter {}

///|
impl @io.Writer for NullWriter with fn write_once(
  self : NullWriter,
  buf : Bytes,
  offset~ : Int,
  len~ : Int,
) -> Int {
  ignore(self)
  ignore(buf)
  ignore(offset)
  len
}
