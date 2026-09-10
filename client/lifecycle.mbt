// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

///|
/// `NOOP`, expecting `200`.
pub async fn no_op(client : FTPClient) -> Unit {
  client.lock()
  defer client.unlock()
  ignore(
    @control.cmd_expect(client.session.control(), "NOOP", [
      @status.status_cmd_ok,
    ]),
  )
}

///|
/// `REIN`, expecting `220`: drops the authentication state but keeps the
/// control connection.
pub async fn logout(client : FTPClient) -> Unit {
  client.lock()
  defer client.unlock()
  ignore(
    @control.cmd_expect(client.session.control(), "REIN", [
      @status.status_service_ready_for_new_user,
    ]),
  )
}

///|
/// `QUIT` and close the connection.
///
/// The errors are aggregated instead of short-circuiting: a failure to send
/// `QUIT` must not hide a failure to close the socket, and the other way
/// round. This mirrors upstream's use of `errors.Join`.
pub async fn quit(client : FTPClient) -> Unit {
  client.lock()
  defer client.unlock()
  guard client.closed == false else { return }
  client.set_closed(true)
  let errors : Array[Error] = []
  let response = @control.cmd_expect(client.session.control(), "QUIT", [
    @status.status_cmd_ok, @status.status_service_ready_for_new_user,
  ]) catch {
    err => {
      errors.push(err)
      return finish_quit(errors)
    }
  }
  ignore(response)
  finish_quit(errors)
}

///|
/// Close the underlying connection and combine every collected error.
fn finish_quit(errors : Array[Error]) -> Unit raise {
  match @error.join_errors(errors) {
    Some(err) => raise err
    None => ()
  }
}

///|
/// Whether the client already sent `QUIT`.
pub fn FTPClient::is_closed(self : FTPClient) -> Bool {
  self.closed
}
