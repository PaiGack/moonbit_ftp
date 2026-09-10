// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

///|
/// The data connection used for one transfer.
pub struct DataConn {
  /// Reads the payload coming from the server.
  reader : &@io.Reader
  /// Writes the payload going to the server.
  writer : &@io.Writer
  /// Closes the socket, keeping the raw connection alive for the 226 read.
  closer : () -> Unit
}

///|
/// The readable end of the data connection.
pub fn DataConn::reader(self : DataConn) -> &@io.Reader {
  self.reader
}

///|
/// The writable end of the data connection.
pub fn DataConn::writer(self : DataConn) -> &@io.Writer {
  self.writer
}

///|
/// Close the data connection without touching the control channel.
pub fn DataConn::close(self : DataConn) -> Unit {
  (self.closer)()
}

///|
/// Get the port to connect to, preferring `EPSV` and permanently falling back
/// to `PASV` after the first failure.
///
/// The "EPSV failed once, never try again" behaviour is a deliberate upstream
/// design choice: some servers answer `EPSV` with an error but also with a
/// malformed `PASV` reply, and retrying `EPSV` on every transfer turns a fast
/// failure into a timeout per file.
pub async fn get_data_port(session : @state.Session) -> (String, Int) {
  if session.options().disable_epsv() == false && session.skip_epsv() == false {
    let port = epsv(session) catch {
      _ => {
        session.set_skip_epsv(true)
        return pasv(session)
      }
    }
    return (session.control().host(), port)
  }
  let (ip, port) = pasv(session)
  // SSRF guard: use the control connection IP unless the caller explicitly
  // trusts the server's answer *and* the answer is not obviously bogus.
  if session.options().trust_pasv_ip() &&
    is_bogus_data_ip(session.control().host(), ip) == false {
    return (ip, port)
  }
  (session.control().host(), port)
}

///|
/// Open the passive data connection.
///
/// With TLS the socket is connected but the handshake is deferred to the first
/// read/write: ProFTPD and PureFTPD both refuse a data connection that starts
/// its handshake before the transfer command was answered.
pub async fn open_data_conn(session : @state.Session) -> DataConn {
  let (ip, port) = get_data_port(session)
  let addr = @socket.Addr::parse("\{ip}:\{port}") catch {
    _ =>
      raise @error.FtpError::ParseError(
        msg="invalid data connection address: \{ip}:\{port}",
      )
  }
  let tcp = @async.with_timeout(session.options().timeout_ms(), async fn() {
    @socket.Tcp::connect(addr)
  })
  if session.options().tls() {
    let tls = @tls.Tls::client(
      tcp,
      host=session.control().host(),
      trust=session.options().trust(),
    )
    return { reader: tls, writer: tls, closer: () => tls.close(), }
  }
  { reader: tcp, writer: tcp, closer: () => tcp.close(), }
}

///|
/// Open a data connection and start a transfer command on it.
///
/// This is the heart of the data channel and follows upstream
/// `cmdDataConnFrom` step by step:
///
/// 1. `PRET <cmd>` first when the server advertised `PRET`,
/// 2. open the data connection,
/// 3. `REST <offset>` when a resume offset was given, expecting `350`,
/// 4. send the transfer command, expecting `125` or `150`,
/// 5. on a non 2xx answer, close the data connection before raising.
pub async fn cmd_data_conn_from(
  session : @state.Session,
  offset : Int64,
  cmd : String,
  args : Array[String],
) -> DataConn {
  if session.use_pret() {
    let _ = try {
      ignore(
        @control.cmd_expect(session.control(), "PRET \{cmd}", [
          @status.status_cmd_ok, @status.status_file_action_pending_further_info,
        ]),
      )
      true
    } catch {
      _ => false
    }
  }
  let conn = open_data_conn(session)
  if offset != 0 {
    let ok = try {
      ignore(
        @control.cmd_format(session.control(), "REST {}", ["\{offset}"], [
          @status.status_file_action_pending_further_info,
        ]),
      )
      true
    } catch {
      _ => false
    }
    guard ok else {
      conn.close()
      raise @error.FtpError::ParseError(msg="REST command failed")
    }
  }
  let response = @control.cmd_format(session.control(), cmd, args, [
    @status.status_data_conn_already_in_use, 150,
  ]) catch {
    _ => {
      conn.close()
      raise @error.FtpError::ParseError(msg="transfer command failed")
    }
  }
  guard @status.is_positive_completion(response.code) else {
    conn.close()
    raise @error.FtpError::ServerError(code=response.code, msg=response.message)
  }
  conn
}
