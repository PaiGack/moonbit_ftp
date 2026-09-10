// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

///|
/// Authenticate with `USER` / `PASS`, then negotiate capabilities.
///
/// The sequence matches upstream `Login`:
/// `USER` -> `331` -> `PASS` -> `230`, then `FEAT`, then `TYPE I`, then
/// optionally `OPTS UTF8 ON`, and for implicit TLS `PBSZ 0` / `PROT P`.
pub async fn login(
  client : FTPClient,
  user : String,
  password : String,
) -> Unit {
  client.lock()
  defer client.unlock()
  let response = @control.cmd_format(
    client.session.control(),
    "USER {}",
    [user],
    [
      @status.status_username_ok_need_password, @status.status_user_logged_in_proceed,
    ],
  )
  if response.code == @status.status_username_ok_need_password {
    ignore(
      @control.cmd_format(client.session.control(), "PASS {}", [password], [
        @status.status_user_logged_in_proceed,
      ]),
    )
  }
  feat(client)
  if client.options.disable_utf8 == false && client.has_feature("UTF8") {
    set_utf8(client) catch {
      _ => ()
    }
  }
  set_transfer_type(client, @types.TransferType::Binary)
  if client.options.tls {
    ignore(
      @control.cmd_expect(client.session.control(), "PBSZ 0", [
        @status.status_cmd_ok,
      ]),
    )
    ignore(
      @control.cmd_expect(client.session.control(), "PROT P", [
        @status.status_cmd_ok,
      ]),
    )
  }
}

///|
/// Ask the server for its feature list and cache the capabilities the client
/// cares about.
///
/// A server that answers `FEAT` with anything other than `211` simply has no
/// feature list; that is **not** an error, upstream treats it the same way.
pub async fn feat(client : FTPClient) -> Unit {
  let response = @control.cmd_expect(client.session.control(), "FEAT", [
    @status.status_system_status,
  ]) catch {
    _ => return
  }
  let features = parse_features(response.message)
  client.set_features(features)
  client.set_mlst_supported(
    client.options.disable_mlsd == false && features.contains("MLST"),
  )
  client.set_mfmt_supported(features.contains("MFMT"))
  client.set_mdtm_supported(features.contains("MDTM"))
  client.set_mdtm_can_write(client.options.writing_mdtm)
  client.session.set_use_pret(features.contains("PRET"))
}

///|
/// Parse a `FEAT` body into a set of command names.
///
/// Every line has the shape ` COMMAND [description]`; only the first token is
/// kept, uppercased.
pub fn parse_features(body : String) -> Map[String, Bool] {
  let features : Map[String, Bool] = Map([])
  for line in body.split("\n") {
    let trimmed = line.trim()
    guard trimmed != "" else { continue }
    let name = match trimmed.find(" ") {
      Some(index) => trimmed[0:index].to_owned()
      None => trimmed.to_owned()
    }
    features[name.to_upper()] = true
  }
  features
}

///|
/// Send `OPTS UTF8 ON`. Servers that do not implement it answer `501`, `504`
/// or `202`; all three are acceptable per upstream.
async fn set_utf8(client : FTPClient) -> Unit {
  ignore(
    @control.cmd_expect(client.session.control(), "OPTS UTF8 ON", [
      @status.status_cmd_ok, @status.status_cmd_not_implemented_superfluous, @status.status_syntax_error_unknown_params,
      @status.status_not_implemented_for_param,
    ]),
  )
}
