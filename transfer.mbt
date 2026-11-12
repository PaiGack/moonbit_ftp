// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Package: `PaiGack/ftp` -- the public client API. Layers below it live in
// `core/` (values), `connection/` (control + data channel) and `debug/` (traffic log).

///|
/// A data transfer in progress, returned by `retr` / `retr_from`.
///
/// `DataResponse::read` is this type's own method, not an `@io.Reader` impl:
/// the reader half of the `@io.Reader` trait needs a `ReaderBuffer` that only
/// `moonbitlang/async/io` can mint, so the method reads *through* the wrapped
/// reader rather than claiming the trait. Callers that need the trait (a
/// `read_all`, a copy helper, a function taking `&@io.Reader`) should take
/// `retr`'s underlying reader instead of assuming `DataResponse` is one -- it
/// is not, and a doc comment is not an `impl`.
///
/// `close()` is idempotent and performs the mandatory `226` wrap-up read.
pub struct DataResponse {
  reader : &@io.Reader
  /// Set once `close()` ran, so a second call is a no-op.
  mut closed : Bool
  session : Session
  /// The client whose lock this response still owns until `close()`.
  ///
  /// `retr` releases the lock before it returns, because a transfer outlives
  /// the call, so the lock used to be free while the payload was still
  /// arriving: any other operation -- a `cwd`, a second `retr` -- then ran
  /// *during* the transfer, on the same control channel, and took the
  /// transfer's replies. `close` takes the lock again for the closing `226`,
  /// and `read_all` / `read_to` do the same around the reads they own, so the
  /// session is owned for exactly the span of the transfer and not one reply
  /// longer.
  client : FTPClient
  /// Pushes the control connection deadline before the `226` read when the
  /// caller configured `shut_timeout_ms`.
  shut_timeout_ms : Int32
}

///|
/// Read up to `max_len` bytes of the transfer.
///
/// Does **not** take the session lock: it reads *through* a handle that can be
/// held across a long transfer, and taking the lock here would let a second
/// operation in between two reads and mix the two transfers' replies. The
/// calls that run the transfer to completion (`read_all`, `read_to`) take the
/// lock for their own duration, and `close` takes it for the wrap-up `226`;
/// a caller that reads with `read` must not issue other operations until it
/// closes.
pub async fn DataResponse::read(
  self : DataResponse,
  dst : FixedArray[Byte],
  offset~ : Int32 = 0,
  max_len~ : Int32 = dst.length() - offset,
) -> Int32 {
  self.reader.read(dst, offset~, max_len~)
}

///|
/// Release the data connection and read the closing `226`.
///
/// This is upstream's `checkDataShut` plus `Close`: dropping it would leave
/// the trailing `226` in the control channel and desynchronise the next
/// command. Errors from the two phases are aggregated.
pub async fn DataResponse::close(self : DataResponse) -> Unit {
  guard !self.closed else { return }
  // One attempt only: a `close()` that raised would leave the lock held and
  // the session unusable for everything after it, and the `226` it failed to
  // read is the same reply the next command would trip over anyway.
  self.closed = true
  self.client.with_lock(async fn() {
    if self.shut_timeout_ms > 0 {
      ignore(
        @async.with_timeout(self.shut_timeout_ms, async fn() {
          check_data_shut(self.session) catch {
            _ => ()
          }
        }),
      )
    } else {
      check_data_shut(self.session) catch {
        _ => ()
      }
    }
  })
}

///|
/// Stream the whole transfer into `sink` and close it -- one call, so the
/// response (and the session lock it holds) cannot be left behind.
///
/// A read or write failure is still followed by `close`, which drains the
/// data socket and reads the `226`; the original failure is what raises.
pub async fn DataResponse::read_to(
  self : DataResponse,
  sink : &@io.Writer,
) -> Unit {
  let failure = try {
    while true {
      let mut chunk : Bytes? = None
      self.client.with_lock(async fn() { chunk = self.reader.read_some() })
      match chunk {
        None => break
        Some(bytes) => sink.write(bytes)
      }
    }
    None
  } catch {
    err => Some(err)
  }
  self.close()
  match failure {
    Some(err) => raise err
    None => ()
  }
}

///|
/// Consume the transfer into memory and close it.
pub async fn DataResponse::read_all(self : DataResponse) -> Bytes {
  // `Bytes` is immutable, so the chunks are collected and joined once. Nothing
  // here takes the session lock twice: `read_to` holds it per read and closes
  // the response at the end.
  let chunks : Array[Bytes] = []
  let failure = try {
    while true {
      let mut chunk : Bytes? = None
      self.client.with_lock(async fn() { chunk = self.reader.read_some() })
      match chunk {
        None => break
        Some(bytes) => chunks.push(bytes)
      }
    }
    None
  } catch {
    err => Some(err)
  }
  self.close()
  match failure {
    Some(err) => raise err
    None => ()
  }
  let out = FixedArray::make(
    chunks.fold(init=0, (n, c) => n + c.length()),
    (0 : Byte),
  )
  let mut offset = 0
  for chunk in chunks {
    out.blit_from_bytes(offset, chunk, 0, chunk.length())
    offset += chunk.length()
  }
  out.unsafe_reinterpret_as_bytes()
}

///|
/// Read the `226` (or `250`) that terminates a transfer. Must always run
/// before the next command is sent.
pub async fn check_data_shut(session : Session) -> Unit {
  // The wrap-up reply is *read*, never requested: sending an empty command
  // here (`@connection.cmd_expect(control, "", ...)`) puts a stray CRLF on the wire and
  // real servers answer `500 Command "" not understood.`, leaving the session
  // one reply behind.
  let response = @connection.read_response(session.control())
  guard response.code() == @core.status_closing_data_connection ||
    response.code() == @core.status_file_action_ok else {
    raise @core.FtpError::ServerError(
      code=response.code(),
      msg=response.message(),
    )
  }
}

///|
/// `RETR <path>`, returning a readable `DataResponse`.
pub async fn retr(client : FTPClient, path : String) -> DataResponse {
  retr_from(client, path, offset=0)
}

///|
/// `RETR <path>` after `REST <offset>`, i.e. a resumed download.
pub async fn retr_from(
  client : FTPClient,
  path : String,
  offset~ : Int64 = 0,
) -> DataResponse {
  client.lock()
  defer client.unlock()
  let conn = @connection.cmd_data_conn_from(
    client.session.control(),
    offset,
    "RETR {}",
    [path],
    options=client.session.conn_options(),
  )
  {
    reader: conn.reader(),
    closed: false,
    session: client.session,
    client,
    shut_timeout_ms: client.options.shut_timeout_ms,
  }
}

///|
/// `STOR <path>`, uploading from `source`.
pub async fn stor(
  client : FTPClient,
  path : String,
  source : &@io.Reader,
) -> Unit {
  stor_from(client, path, source, offset=0)
}

///|
/// `STOR <path>` after `REST <offset>`, i.e. a resumed upload.
///
/// The zero-byte TLS case is handled explicitly: ProFTPD answers
/// `Unable to build data connection` when the data connection was never
/// written to, because the TLS handshake never happened. Uploading nothing
/// while triggering the handshake explicitly keeps the server happy.
///
/// See `@connection.DataConn::start_tls` for why the trigger is a real call here rather
/// than a poke at a session that already exists: Go's `tls.Conn` handshakes
/// lazily, `@tls.Tls::client` handshakes while it is being built.
pub async fn stor_from(
  client : FTPClient,
  path : String,
  source : &@io.Reader,
  offset~ : Int64 = 0,
) -> Unit {
  client.lock()
  defer client.unlock()
  let conn = @connection.cmd_data_conn_from(
    client.session.control(),
    offset,
    "STOR {}",
    [path],
    options=client.session.conn_options(),
  )
  let errors : Array[Error] = []
  let written = stream(source, conn.writer()) catch {
    err => {
      errors.push(err)
      0
    }
  }
  // Gate on the *folded* TLS flag (`DialOptions::to_state_options`), not on
  // `options.tls` alone: that one is false for explicit TLS (`AUTH TLS`), and
  // `@connection.DataConn::start_tls` -- the call this branch exists to mirror -- is gated
  // on the folded value for exactly that reason.
  if written == 0 && client.state_options.tls() {
    // The upstream workaround, spelled as the call it always described: an
    // explicit handshake. Go's `tls.Conn` handshakes lazily on the first read
    // or write, so an upload that moved no bytes never touches the session and
    // the server never sees a `ClientHello`; upstream therefore calls
    // `Handshake()` here. `@tls.Tls::client` handshakes while it is being
    // *built*, which `@connection.cmd_data_conn_from` already did right after the `150`, so
    // on the happy path this call is a no-op rather than a second handshake.
    // It stays because it is what makes the promise local: remove the handshake
    // from `@connection.cmd_data_conn_from` and this is the line that still satisfies it.
    ignore(
      conn.start_tls(
        client.session.control().server_name(),
        client.state_options.trust(),
        client.state_options.timeout_ms(),
        true,
      ),
    ) catch {
      err => errors.push(err)
    }
  }
  conn.close(timeout_ms=client.options.shut_timeout_ms)
  check_data_shut(client.session) catch {
    err => errors.push(err)
  }
  match @core.join_errors(errors) {
    Some(err) => raise err
    None => ()
  }
}

///|
/// `APPE <path>`, appending a file.
pub async fn append(
  client : FTPClient,
  path : String,
  source : &@io.Reader,
) -> Unit {
  client.lock()
  defer client.unlock()
  let conn = @connection.cmd_data_conn_from(
    client.session.control(),
    0,
    "APPE {}",
    [path],
    options=client.session.conn_options(),
  )
  let errors : Array[Error] = []
  ignore(
    stream(source, conn.writer()) catch {
      err => {
        errors.push(err)
        0
      }
    },
  )
  conn.close(timeout_ms=client.options.shut_timeout_ms)
  check_data_shut(client.session) catch {
    err => errors.push(err)
  }
  match @core.join_errors(errors) {
    Some(err) => raise err
    None => ()
  }
}

///|
/// Copy everything from `source` to `sink`, returning the number of bytes
/// written.
async fn stream(source : &@io.Reader, sink : &@io.Writer) -> Int32 {
  let mut total = 0
  while source.read_some() is Some(chunk) {
    sink.write(chunk)
    total += chunk.length()
  }
  total
}

///|

///|
