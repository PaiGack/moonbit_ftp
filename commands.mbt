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
/// Delete a non-empty directory recursively, the port of upstream
/// `RemoveDirRecur`.
///
/// The sequence is upstream's, and it is a `cd`-in / `cd ..`-out dance rather
/// than a walk of the tree, because a plain FTP server has no way to name a
/// child relative to a directory the client is not currently *in*: every
/// `LIST` / `RMD` argument is resolved against the session's working directory.
///
/// 1. `CWD path`, then `PWD` to learn the absolute name the server assigned —
///    not the caller's string, which may be relative or a symlink.
/// 2. `LIST` that absolute path and recurse into every folder child, `DELE`
///    every file child. `.` and `..` are skipped.
/// 3. `CDUP` out, then `RMD` the directory itself — bottom up, so a directory
///    is only removed once it is empty.
///
/// The client lock is deliberately **not** held across the recursion: `list` /
/// `delete` / `remove_dir` each take it themselves and the lock is not
/// reentrant, so wrapping the body would deadlock on the first child.
pub async fn remove_dir_recur(client : FTPClient, path : String) -> Unit {
  change_dir(client, path)
  let current_dir = current_dir(client)
  let entries = list(client, current_dir)
  for entry in entries {
    if entry.name == "." || entry.name == ".." {
      continue
    }
    if entry.type_ is EntryType::Folder {
      remove_dir_recur(client, current_dir + "/" + entry.name)
    } else {
      // A bare name is enough: the recursion just `CWD`-ed into
      // `current_dir`, and upstream relies on that too.
      delete(client, entry.name)
    }
  }
  change_dir_to_parent(client)
  remove_dir(client, current_dir)
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
/// `QUIT` and mark the connection as closed.
///
/// The socket is **not** closed here: `Control` has no `close`, and no path in
/// this module calls `@socket.Tcp::close` (see the "connection and shutdown
/// semantics" note in `README.mbt.md`). Upstream's `Quit` closes `c.conn`
/// explicitly and joins that error with the command's, which is why the shape
/// below -- collect into `errors`, then `finish_quit` -- survives even though
/// only the command can fail. Sending `QUIT` therefore does not make the next
/// read observe EOF; the server closing its side and this process releasing
/// the handle do.
///
/// A second call is a no-op, visible through `is_closed`.
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
/// Raise the errors collected by `quit` as one `FtpErrors::MultipleErrors`,
/// or return normally when there are none.
///
/// The list is always empty or a single `QUIT` failure today -- there is no
/// socket to close, so there is no second error to join. It stays a list
/// because that is upstream's `errors.Join` shape and because the error
/// aggregation rule (`docs/porting.md` section 1.4 point 3) applies to it as
/// soon as a second step appears.
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
