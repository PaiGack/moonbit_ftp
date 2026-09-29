// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

// Tests for the data transfer wrappers in `transfer.mbt`.
//
// `retr` / `stor` / `append` are one command each, so what is pinned here is
// the contract around them: the command (`RETR` / `STOR` / `APPE` plus the path
// substitution), the optional `REST <offset>` of the resuming variants, the
// `150` validation, the mandatory `226` wrap-up and the error aggregation that
// mirrors Go's `errors.Join`. The scripted control channel and the loopback
// data listener come from `ftp_test_helpers_wbtest.mbt`.

///|
/// `retr` sends `RETR <path>` and hands back a readable `DataResponse`.
async test "retr sends RETR and exposes the payload" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) +
    "150 Opening BINARY mode data connection.\r\n226 Transfer complete.\r\n"
  let (client, sink) = scripted_client(script)
  let payload = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      serve_payload(listener, "hello from the fixture\n")
    })
    let response = retr(client, "/hello.txt") catch { e => fail("retr: \{e}") }
    // `DataResponse::read` drives the same reader the trait exposes; reading
    // into a buffer is the public surface a caller actually uses.
    let buffer : FixedArray[Byte] = FixedArray::make(64, b'\x00')
    let count = response.read(buffer, max_len=64) catch {
      e => fail("read: \{e}")
    }
    let mut payload = ""
    for i = 0; i < count; i = i + 1 {
      payload = payload + buffer[i].to_int().unsafe_to_char().to_string()
    }
    response.close() catch {
      e => fail("close: \{e}")
    }
    payload
  })
  assert_eq(payload, "hello from the fixture\n")
  assert_eq(sink.lines, ["EPSV", "RETR /hello.txt"])
}

///|
/// `retr_from` puts a `REST <offset>` before the `RETR`, which is the whole
/// point of the resuming variants.
async test "retr_from sends REST before RETR" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) +
    "350 Restarting at 1024.\r\n" +
    "150 Opening BINARY mode data connection.\r\n226 Transfer complete.\r\n"
  let (client, sink) = scripted_client(script)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      serve_payload(listener, "rest of the file")
    })
    let response = retr_from(client, "/big.bin", offset=1024) catch {
      e => fail("retr_from: \{e}")
    }
    response.close() catch {
      e => fail("close: \{e}")
    }
    ()
  })
  assert_eq(sink.lines, ["EPSV", "REST 1024", "RETR /big.bin"])
}

///|
/// `retr` without an offset never sends `REST`, so a fresh download cannot be
/// mistaken for a resume.
async test "retr omits REST at offset zero" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) +
    "150 Opening BINARY mode data connection.\r\n226 Transfer complete.\r\n"
  let (client, sink) = scripted_client(script)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() { serve_payload(listener, "x") })
    let response = retr(client, "/a.txt") catch { e => fail("retr: \{e}") }
    response.close() catch {
      e => fail("close: \{e}")
    }
    ()
  })
  assert_eq(sink.lines, ["EPSV", "RETR /a.txt"])
}

///|
/// `REST` must answer `350`; when it does not, the transfer is abandoned
/// instead of silently restarting from zero.
async test "retr_from abandons the transfer when REST fails" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) + "501 Bad restart offset.\r\n"
  let (client, sink) = scripted_client(script)
  let raised = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (conn, _) = listener.accept()
      conn.close()
    })
    try {
      ignore(retr_from(client, "/big.bin", offset=1024))
      None
    } catch {
      FtpError::ParseError(msg~) => Some(msg)
      _ => None
    }
  })
  assert_eq(raised, Some("REST command failed"))
  // `RETR` was never sent: the guard fires before it.
  assert_eq(sink.lines, ["EPSV", "REST 1024"])
}

///|
/// `stor` sends `STOR <path>` and writes the source through the data channel.
async test "stor sends STOR and uploads the source" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) +
    "150 Ok to send data.\r\n226 Transfer complete.\r\n"
  let (client, sink) = scripted_client(script)
  let received = @async.with_task_group(async fn(group) {
    let server = group.spawn(no_wait=true, async fn() {
      let (conn, _) = listener.accept()
      let mut chunks = ""
      while conn.read_some() is Some(chunk) {
        for i = 0; i < chunk.length(); i = i + 1 {
          chunks = chunks +
            chunk.unsafe_get(i).to_int().unsafe_to_char().to_string()
        }
      }
      conn.close()
      chunks
    })
    stor(client, "/up.txt", text_source("uploaded payload")) catch {
      e => fail("stor: \{e}")
    }
    // Joining the server task is what makes the readback deterministic: the
    // payload is still in flight when `stor` returns.
    server.wait()
  })
  assert_eq(sink.lines, ["EPSV", "STOR /up.txt"])
  assert_eq(received, "uploaded payload")
}

///|
/// `stor_from` resumes an upload with `REST <offset>` before `STOR`.
async test "stor_from sends REST before STOR" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) +
    "350 Restarting at 7.\r\n150 Ok to send data.\r\n226 Transfer complete.\r\n"
  let (client, sink) = scripted_client(script)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (conn, _) = listener.accept()
      ignore(conn.read_all() catch { _ => empty_data() })
      conn.close()
    })
    stor_from(client, "/up.txt", text_source("tail"), offset=7L) catch {
      e => fail("stor_from: \{e}")
    }
    ()
  })
  assert_eq(sink.lines, ["EPSV", "REST 7", "STOR /up.txt"])
}

///|
/// `append` sends `APPE <path>` and never a `REST`, because appending has no
/// offset to resume from.
async test "append sends APPE without REST" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) +
    "150 Ok to send data.\r\n226 Transfer complete.\r\n"
  let (client, sink) = scripted_client(script)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (conn, _) = listener.accept()
      ignore(conn.read_all() catch { _ => empty_data() })
      conn.close()
    })
    append(client, "/log.txt", text_source("more log lines")) catch {
      e => fail("append: \{e}")
    }
    ()
  })
  assert_eq(sink.lines, ["EPSV", "APPE /log.txt"])
}

///|
/// A transfer command that is not answered with `150`/`125` fails, and the
/// data connection is closed instead of being leaked.
///
/// `cmd_data_conn_from` refuses the transfer *before* the socket is written
/// to, so the listener never sees a connection: the way to observe the guard
/// is the raised error plus the command list, and the absent peer is itself
/// the proof that the data connection was torn down.
async test "stor raises when the transfer command is refused" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) + "550 Not enough space.\r\n"
  let (client, _) = scripted_client(script)
  // The transfer command is refused before any payload, so `stor` must close
  // the data connection itself — which is why the listener never has to
  // accept, and why a pending accept would be a leaked task.
  let raised = try {
    // `failing_source()` rather than a `MemoryReader`: the payload is never
    // read on this path, and a producer left parked would deadlock the test
    // runner.
    stor(client, "/up.txt", failing_source())
    None
  } catch {
    FtpError::ParseError(msg~) => Some(msg)
    FtpError::ServerError(code~, ..) => Some("http \{code}")
    // `cmd_data_conn_from` reports a refused command as one of the two above;
    // anything else would be a regression worth seeing.
    _ => None
  }
  listener.close()
  assert_eq(raised, Some("transfer command failed"))
}

///|
/// The `226` read after a transfer must not send anything: an empty command
/// would desynchronise the session and real servers answer it with `500`.
async test "transfer wrap-up does not put an empty line on the wire" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) +
    "150 Ok to send data.\r\n226 Transfer complete.\r\n"
  let (client, sink) = scripted_client(script)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (conn, _) = listener.accept()
      ignore(conn.read_all() catch { _ => empty_data() })
      conn.close()
    })
    stor(client, "/up.txt", text_source("body")) catch {
      e => fail("stor: \{e}")
    }
    ()
  })
  assert_eq(sink.lines, ["EPSV", "STOR /up.txt"])
  assert_eq(sink.pending, "")
}

///|
/// `DataResponse::close` is idempotent: a second call must not try to read a
/// second `226`, which would block until the control channel timed out.
async test "DataResponse close is idempotent" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) +
    "150 Opening BINARY mode data connection.\r\n226 Transfer complete.\r\n"
  let (client, sink) = scripted_client(script)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      serve_payload(listener, "payload")
    })
    let response = retr(client, "/a.txt") catch { e => fail("retr: \{e}") }
    response.close() catch {
      e => fail("first close: \{e}")
    }
    // The control channel is exhausted; a second read would raise
    // `ReaderClosed`, so a non-raising second call proves the guard.
    response.close() catch {
      e => fail("second close: \{e}")
    }
    ()
  })
  assert_eq(sink.lines, ["EPSV", "RETR /a.txt"])
}

///|
/// `stor` with a source that fails mid-transfer still runs the `226` wrap-up
/// and reports both problems, matching upstream's `errors.Join`.
async test "stor aggregates the read error and the wrap-up error" {
  let listener = data_listener()
  let port = listener.addr.port()
  // The wrap-up is a `550`, so `check_data_shut` fails too.
  let script = epsv_reply(port) +
    "150 Ok to send data.\r\n550 Transfer failed.\r\n"
  let (client, _) = scripted_client(script)
  let raised = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (conn, _) = listener.accept()
      conn.close()
    })
    try {
      stor(client, "/up.txt", failing_source())
      None
    } catch {
      e => Some(flatten_errors(e).length())
    }
  })
  // One error from the source, one from the `226` read.
  assert_eq(raised, Some(2))
}

///|
/// `check_data_shut` accepts `226` (closing data connection) and `250` (file
/// action ok) and rejects every other code, carrying the server's message.
async test "check_data_shut rejects a code other than 226 and 250" {
  let bad = scripted_control("451 Local error in processing.\r\n")
  let raised = try {
    check_data_shut(Session::new(bad.0))
    None
  } catch {
    FtpError::ServerError(code~, msg~) => Some((code, msg))
    _ => None
  }
  assert_eq(raised, Some((451, "Local error in processing.")))
}

///|
/// `shut_timeout_ms` wraps the closing `226` read in a timeout. The wrap is
/// best effort — a timeout is swallowed, because the transfer itself already
/// succeeded and dropping the client over a late reply would be worse than
/// leaving one stale reply in the channel.
async test "DataResponse::close tolerates a timeout on the 226 read" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) + "150 Opening BINARY mode data connection.\r\n"
  // No `226` follows, so the wrap-up read will hit the timeout.
  let (client, _) = scripted_client(script)
  client.options.shut_timeout_ms = 30
  @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      serve_payload(listener, "payload")
    })
    let response = retr(client, "/a.txt") catch { _ => fail("retr") }
    // Draining the payload is not required; `close` resets the data channel.
    response.close() catch {
      e => fail("close should swallow the timeout: \{e}")
    }
    // A second close is a no-op, not a second wrap-up read.
    response.close() catch {
      e => fail("second close: \{e}")
    }
    ()
  })
}

///|
/// A zero byte upload over a TLS-configured client is the ProFTPD case: the
/// data connection was opened but never written to, so the TLS handshake never
/// happened and the server answers `Unable to build data connection`. The
/// explicit no-op keeps that from being an error.
async test "stor_from accepts a zero byte TLS upload" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) +
    "150 Ok to send data.\r\n226 Transfer complete.\r\n"
  let (client, sink) = scripted_client(script)
  // TLS on the options makes the zero byte branch reachable without a real
  // TLS handshake: the branch is `written == 0 && options.tls`.
  client.options.tls = true
  @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (conn, _) = listener.accept()
      ignore(conn.read_all() catch { _ => empty_data() })
      conn.close()
    })
    stor_from(client, "/empty.bin", text_source("")) catch {
      e => fail("stor_from: \{e}")
    }
    ()
  })
  assert_eq(sink.lines, ["EPSV", "STOR /empty.bin"])
}

///|
/// `append` aggregates the read error and the `226` error the same way `stor`
/// does, so a broken source is reported instead of being swallowed.
async test "append reports a broken source" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) +
    "150 Ok to send data.\r\n226 Transfer complete.\r\n"
  let (client, sink) = scripted_client(script)
  let raised = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (conn, _) = listener.accept()
      ignore(conn.read_all() catch { _ => empty_data() })
      conn.close()
    })
    try {
      append(client, "/log.txt", failing_source())
      false
    } catch {
      _ => true
    }
  })
  assert_true(raised)
  assert_eq(sink.lines, ["EPSV", "APPE /log.txt"])
}

///|
/// `append` keeps the `226` failure *and* the transfer result: the wrap-up
/// error is aggregated rather than replacing the outcome, matching upstream's
/// `errors.Join`. A refused `226` (a `5xx` instead of `226`) is the reachable
/// shape.
async test "append aggregates a refused 226" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) +
    "150 Ok to send data.\r\n550 Transfer refused.\r\n"
  let (client, sink) = scripted_client(script)
  let code = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (conn, _) = listener.accept()
      ignore(conn.read_all() catch { _ => empty_data() })
      conn.close()
    })
    try {
      append(client, "/log.txt", text_source("line\n"))
      -1
    } catch {
      FtpError::ServerError(code~, ..) => code
      _ => -2
    }
  })
  assert_eq(code, 550)
  assert_eq(sink.lines, ["EPSV", "APPE /log.txt"])
}

///|
/// The same aggregation on `stor`: a refused `226` is reported instead of
/// being treated as a successful upload.
async test "stor aggregates a refused 226" {
  let listener = data_listener()
  let port = listener.addr.port()
  let script = epsv_reply(port) +
    "150 Ok to send data.\r\n550 Transfer refused.\r\n"
  let (client, sink) = scripted_client(script)
  let code = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (conn, _) = listener.accept()
      ignore(conn.read_all() catch { _ => empty_data() })
      conn.close()
    })
    try {
      stor(client, "/up.txt", text_source("payload"))
      -1
    } catch {
      FtpError::ServerError(code~, ..) => code
      _ => -2
    }
  })
  assert_eq(code, 550)
  assert_eq(sink.lines, ["EPSV", "STOR /up.txt"])
}
