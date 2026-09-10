// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

///|
/// A data transfer in progress, returned by `retr` / `retr_from`.
///
/// It implements `@io.Reader`; `close()` is idempotent and performs the
/// mandatory `226` wrap-up read.
pub struct DataResponse {
  reader : &@io.Reader
  /// Set once `close()` ran, so a second call is a no-op.
  mut closed : Bool
  session : Session
  /// Pushes the control connection deadline before the `226` read when the
  /// caller configured `shut_timeout_ms`.
  shut_timeout_ms : Int
}

///|
/// Read up to `max_len` bytes of the transfer.
pub async fn DataResponse::read(
  self : DataResponse,
  dst : FixedArray[Byte],
  offset? : Int = 0,
  max_len? : Int = dst.length() - offset,
) -> Int {
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
  self.closed = true
  if self.shut_timeout_ms > 0 {
    ignore(
      @async.with_timeout(self.shut_timeout_ms, async fn() {
        check_data_shut(self.session) catch {
          _ => ()
        }
      }),
    )
  } else {
    check_data_shut(self.session)
  }
}

///|
/// Read the `226` (or `250`) that terminates a transfer. Must always run
/// before the next command is sent.
pub async fn check_data_shut(session : Session) -> Unit {
  ignore(
    cmd_expect(session.control(), "", [
      status_closing_data_connection, status_file_action_ok,
    ]),
  )
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
  offset? : Int64 = 0,
) -> DataResponse {
  client.lock()
  defer client.unlock()
  let conn = cmd_data_conn_from(client.session, offset, "RETR {}", [path])
  {
    reader: conn.reader(),
    closed: false,
    session: client.session,
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
pub async fn stor_from(
  client : FTPClient,
  path : String,
  source : &@io.Reader,
  offset? : Int64 = 0,
) -> Unit {
  client.lock()
  defer client.unlock()
  let conn = cmd_data_conn_from(client.session, offset, "STOR {}", [path])
  let errors : Array[Error] = []
  let written = stream(source, conn.writer()) catch {
    err => {
      errors.push(err)
      0
    }
  }
  if written == 0 && client.options.tls {
    ignore(written)
  }
  conn.close()
  check_data_shut(client.session) catch {
    err => errors.push(err)
  }
  match join_errors(errors) {
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
  let conn = cmd_data_conn_from(client.session, 0, "APPE {}", [path])
  let errors : Array[Error] = []
  ignore(
    stream(source, conn.writer()) catch {
      err => {
        errors.push(err)
        0
      }
    },
  )
  conn.close()
  check_data_shut(client.session) catch {
    err => errors.push(err)
  }
  match join_errors(errors) {
    Some(err) => raise err
    None => ()
  }
}

///|
/// Copy everything from `source` to `sink`, returning the number of bytes
/// written.
async fn stream(source : &@io.Reader, sink : &@io.Writer) -> Int {
  let mut total = 0
  while source.read_some() is Some(chunk) {
    sink.write(chunk)
    total += chunk.length()
  }
  total
}
