// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

// The thin one-command-per-function wrappers: navigation, file operations and
// session lifecycle.
//
// This file merges `nav`, `fsops` and `lifecycle`: every block here is the same
// shape — lock the client, send one (or two) commands through
// `cmd_expect` / `cmd_format`, check the expected status code — so three files
// of 50-65 lines each only made the same pattern look like three separate
// features. `extract_quoted` stays next to `current_dir`, its only caller.

///|
/// `CWD <path>`, expecting `250`.
pub async fn change_dir(client : FTPClient, dir : String) -> Unit {
  client.lock()
  defer client.unlock()
  ignore(
    cmd_format(client.session.control(), "CWD {}", [dir], [
      status_file_action_ok,
    ]),
  )
}

///|
/// `CDUP`, expecting `250`.
pub async fn change_dir_to_parent(client : FTPClient) -> Unit {
  client.lock()
  defer client.unlock()
  ignore(cmd_expect(client.session.control(), "CDUP", [status_file_action_ok]))
}

///|
/// `PWD`, returning the path inside the quoted part of the `257` reply.
pub async fn current_dir(client : FTPClient) -> String {
  client.lock()
  defer client.unlock()
  let response = cmd_expect(client.session.control(), "PWD", [status_dir_create])
  match extract_quoted(response.message()) {
    Some(path) => path
    None => raise FtpError::ParseError(msg="invalid PWD response")
  }
}

///|
/// Extract the substring between the first pair of double quotes, which is how
/// `257 "/incoming" created.` encodes the path.
pub fn extract_quoted(message : String) -> String? {
  let start = match message.find("\"") {
    Some(start) => start
    None => return None
  }
  let tail = message[start + 1:].to_owned()
  let end = match tail.find("\"") {
    Some(end) => end
    None => return None
  }
  Some(tail[0:end].to_owned())
}

///|
/// `MKD <path>`, expecting `257`.
pub async fn make_dir(client : FTPClient, dir : String) -> Unit {
  client.lock()
  defer client.unlock()
  ignore(
    cmd_format(client.session.control(), "MKD {}", [dir], [status_dir_create]),
  )
}

///|
/// `RMD <path>`, expecting `250`.
pub async fn remove_dir(client : FTPClient, dir : String) -> Unit {
  client.lock()
  defer client.unlock()
  ignore(
    cmd_format(client.session.control(), "RMD {}", [dir], [
      status_file_action_ok,
    ]),
  )
}

///|
/// `DELE <path>`, expecting `250`.
pub async fn delete(client : FTPClient, path : String) -> Unit {
  client.lock()
  defer client.unlock()
  ignore(
    cmd_format(client.session.control(), "DELE {}", [path], [
      status_file_action_ok,
    ]),
  )
}

///|
/// Rename in two steps, `RNFR` -> `350` then `RNTO` -> `250`.
pub async fn rename(client : FTPClient, from : String, to : String) -> Unit {
  client.lock()
  defer client.unlock()
  ignore(
    cmd_format(client.session.control(), "RNFR {}", [from], [
      status_file_action_pending_further_info,
    ]),
  )
  ignore(
    cmd_format(client.session.control(), "RNTO {}", [to], [
      status_file_action_ok,
    ]),
  )
}

///|
/// `NOOP`, expecting `200`.
pub async fn no_op(client : FTPClient) -> Unit {
  client.lock()
  defer client.unlock()
  ignore(cmd_expect(client.session.control(), "NOOP", [status_cmd_ok]))
}

///|
/// `REIN`, expecting `220`: drops the authentication state but keeps the
/// control connection.
pub async fn logout(client : FTPClient) -> Unit {
  client.lock()
  defer client.unlock()
  ignore(
    cmd_expect(client.session.control(), "REIN", [
      status_service_ready_for_new_user,
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
  let response = cmd_expect(client.session.control(), "QUIT", [
    status_closing_control_connection, status_cmd_ok, status_service_ready_for_new_user,
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
  match join_errors(errors) {
    Some(err) => raise err
    None => ()
  }
}

///|
/// Whether the client already sent `QUIT`.
pub fn FTPClient::is_closed(self : FTPClient) -> Bool {
  self.closed
}
