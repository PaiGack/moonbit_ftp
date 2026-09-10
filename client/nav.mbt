// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

///|
/// `CWD <path>`, expecting `250`.
pub async fn change_dir(client : FTPClient, dir : String) -> Unit {
  client.lock()
  defer client.unlock()
  ignore(
    @control.cmd_format(client.session.control(), "CWD {}", [dir], [
      @status.status_file_action_ok,
    ]),
  )
}

///|
/// `CDUP`, expecting `250`.
pub async fn change_dir_to_parent(client : FTPClient) -> Unit {
  client.lock()
  defer client.unlock()
  ignore(
    @control.cmd_expect(client.session.control(), "CDUP", [
      @status.status_file_action_ok,
    ]),
  )
}

///|
/// `PWD`, returning the path inside the quoted part of the `257` reply.
pub async fn current_dir(client : FTPClient) -> String {
  client.lock()
  defer client.unlock()
  let response = @control.cmd_expect(client.session.control(), "PWD", [
    @status.status_dir_create,
  ])
  match extract_quoted(response.message) {
    Some(path) => path
    None => raise @error.FtpError::ParseError(msg="invalid PWD response")
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
