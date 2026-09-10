// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

///|
/// `NLST <path>`: a bare list of names, one per line.
pub async fn name_list(client : FTPClient, path : String) -> Array[String] {
  client.lock()
  defer client.unlock()
  let conn = cmd_data_conn_from(client.session, 0, "NLST {}", [path])
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
  match join_errors(errors) {
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
pub async fn list(client : FTPClient, path : String) -> Array[Entry] {
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
  let conn = cmd_data_conn_from(client.session, 0, command, [path])
  let errors : Array[Error] = []
  let entries : Array[Entry] = []
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
      match parse_rfc3659_line(trimmed) {
        Some(entry) => entries.push(entry)
        None => ()
      }
    } else {
      let parsed = Some(parse_list_line(trimmed, client.now())) catch {
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
  match join_errors(errors) {
    Some(err) => raise err
    None => ()
  }
  entries
}

///|
/// `MLST <path>`: the facts of a single entry.
///
/// The body carries the framing lines too, so this follows upstream exactly:
/// the message must split into at least three lines, the first and the last
/// are dropped, and the remaining lines are merged into one entry (RFC 3659
/// allows the facts of a single file to be spread over several lines).
pub async fn get_entry(client : FTPClient, path : String) -> Entry {
  client.lock()
  defer client.unlock()
  let response = cmd_format(client.session.control(), "MLST {}", [path], [
    status_file_action_ok,
  ])
  let lines = response.message().split("\n").collect()
  // `lc < 3` is upstream's "invalid response": anything shorter than
  // `<head>\n<facts>\n<tail>` cannot carry a fact line.
  guard lines.length() >= 3 else {
    raise FtpError::ParseError(msg="invalid response")
  }
  let mut entry : Entry? = None
  for i = 1; i < lines.length() - 1; i = i + 1 {
    // RFC 3659 requires a leading space; some servers omit it and some add
    // several, so all forms are accepted here.
    let line = lines[i].trim_start().to_owned()
    // Some servers send a trailing blank line, which is ignored.
    guard line != "" else { continue }
    entry = match entry {
      None => parse_rfc3659_line(line)
      Some(entry) => Some(parse_next_rfc3659_line(entry, line))
    }
  }
  match entry {
    Some(entry) => entry
    None => raise FtpError::UnsupportedListLine(line=response.message())
  }
}

///|
/// `TYPE I` / `TYPE A`.
pub async fn set_transfer_type(
  client : FTPClient,
  transfer_type : TransferType,
) -> Unit {
  client.lock()
  defer client.unlock()
  ignore(
    cmd_format(
      client.session.control(),
      "TYPE {}",
      [transfer_type.to_string()],
      [status_cmd_ok],
    ),
  )
}

///|
/// The reference instant used by the `LIST` time parsers, taken from the
/// configured location.
fn FTPClient::now(self : FTPClient) -> @time.ZonedDateTime {
  ignore(self.location)
  epoch
}

///|
/// Drain the data connection into a `String`, recording (not raising) any read
/// failure so that the caller can still run the `226` wrap-up.
async fn read_payload(conn : DataConn, errors : Array[Error]) -> String {
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
