// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

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
