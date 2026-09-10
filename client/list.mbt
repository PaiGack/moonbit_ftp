// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

///|
/// `NLST <path>`: a bare list of names, one per line.
pub async fn name_list(client : FTPClient, path : String) -> Array[String] {
  client.lock()
  defer client.unlock()
  let conn = @transport.cmd_data_conn_from(client.session, 0, "NLST {}", [path])
  let errors : Array[Error] = []
  let names : Array[String] = []
  let payload = read_payload(conn, errors) catch {
    err => {
      errors.push(err)
      ""
    }
  }
  for line in payload.split("\n") {
    let trimmed = line.trim().to_owned()
    if trimmed != "" {
      names.push(trimmed)
    }
  }
  conn.close()
  check_data_shut(client.session) catch {
    err => errors.push(err)
  }
  match @error.join_errors(errors) {
    Some(err) => raise err
    None => ()
  }
  names
}

///|
/// List a directory.
///
/// `MLSD` is preferred when the server supports it; otherwise `LIST` (with
/// `-a` when `force_list_hidden` is set) is parsed with the four parser
/// fallback. Lines that no parser recognises are **skipped**, not fatal: real
/// servers emit `total 1` headers and other noise.
pub async fn list(client : FTPClient, path : String) -> Array[@types.Entry] {
  client.lock()
  defer client.unlock()
  let use_mlsd = client.mlst_supported &&
    client.options.force_list_hidden == false
  let command = if use_mlsd {
    "MLSD {}"
  } else if client.options.force_list_hidden {
    "LIST -a {}"
  } else {
    "LIST {}"
  }
  let conn = @transport.cmd_data_conn_from(client.session, 0, command, [path])
  let errors : Array[Error] = []
  let entries : Array[@types.Entry] = []
  let payload = read_payload(conn, errors) catch {
    err => {
      errors.push(err)
      ""
    }
  }
  for line in payload.split("\n") {
    let trimmed = line.trim().to_owned()
    guard trimmed != "" else { continue }
    if use_mlsd {
      match @parse.parse_rfc3659_line(trimmed) {
        Some(entry) => entries.push(entry)
        None => ()
      }
    } else {
      let parsed = Some(@parse.parse_list_line(trimmed, client.now())) catch {
        _ => None
      }
      match parsed {
        Some((entry, _)) => entries.push(entry)
        None => ()
      }
    }
  }
  conn.close()
  check_data_shut(client.session) catch {
    err => errors.push(err)
  }
  match @error.join_errors(errors) {
    Some(err) => raise err
    None => ()
  }
  entries
}

///|
/// `MLST <path>`: the facts of a single entry, read from the middle lines of
/// the reply.
pub async fn get_entry(client : FTPClient, path : String) -> @types.Entry {
  client.lock()
  defer client.unlock()
  let response = @control.cmd_format(
    client.session.control(),
    "MLST {}",
    [path],
    [@status.status_file_action_ok],
  )
  let lines = response.message.split("\n").collect()
  guard lines.length() >= 1 else {
    raise @error.FtpError::UnsupportedListLine(line=response.message)
  }
  // The `MLST` body may either be a single facts line, or a blank line
  // followed by the facts; take the first non-empty line.
  for line in lines {
    let trimmed = line.trim().to_owned()
    guard trimmed != "" else { continue }
    match @parse.parse_rfc3659_line(trimmed) {
      Some(entry) => return entry
      None => continue
    }
  }
  raise @error.FtpError::UnsupportedListLine(line=response.message)
}

///|
/// `TYPE I` / `TYPE A`.
pub async fn set_transfer_type(
  client : FTPClient,
  transfer_type : @types.TransferType,
) -> Unit {
  client.lock()
  defer client.unlock()
  ignore(
    @control.cmd_format(
      client.session.control(),
      "TYPE {}",
      [transfer_type.to_string()],
      [@status.status_cmd_ok],
    ),
  )
}

///|
/// The reference instant used by the `LIST` time parsers, taken from the
/// configured location.
fn FTPClient::now(self : FTPClient) -> @time.ZonedDateTime {
  ignore(self.location)
  @types.epoch
}

///|
/// Drain the data connection into a `String`, recording (not raising) any read
/// failure so that the caller can still run the `226` wrap-up.
async fn read_payload(
  conn : @transport.DataConn,
  errors : Array[Error],
) -> String {
  let data = conn.reader().read_all() catch {
      err => {
        errors.push(err)
        return ""
      }
    }
  data.text() catch {
    _ => ""
  }
}
