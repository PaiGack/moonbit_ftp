// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

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
  let response = cmd_format(client.session.control(), "USER {}", [user], [
    status_username_ok_need_password, status_user_logged_in_proceed,
  ])
  if response.code() == status_username_ok_need_password {
    ignore(
      cmd_format(client.session.control(), "PASS {}", [password], [
        status_user_logged_in_proceed,
      ]),
    )
  }
  feat(client)
  if client.options.disable_utf8 == false && client.has_feature("UTF8") {
    set_utf8(client) catch {
      _ => ()
    }
  }
  set_transfer_type(client, TransferType::Binary)
  if client.options.tls {
    ignore(cmd_expect(client.session.control(), "PBSZ 0", [status_cmd_ok]))
    ignore(cmd_expect(client.session.control(), "PROT P", [status_cmd_ok]))
  }
}

///|
/// Ask the server for its feature list and cache the capabilities the client
/// cares about.
///
/// A server that answers `FEAT` with anything other than `211` simply has no
/// feature list; that is **not** an error, upstream treats it the same way.
pub async fn feat(client : FTPClient) -> Unit {
  let response = cmd_expect(client.session.control(), "FEAT", [
    status_system_status,
  ]) catch {
    _ => return
  }
  let features = parse_features(response.message())
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
/// Feature lines have the shape ` COMMAND [description]`; only the first token
/// is kept, uppercased.
///
/// The leading space test is not cosmetic: the body carries the text of the
/// `211-Features:` and `211 End` framing lines too (see `read_response`), and
/// once trimmed they would otherwise register as features named `FEATURES:`
/// and `END`. Upstream filters with exactly this test.
pub fn parse_features(body : String) -> Map[String, Bool] {
  let features : Map[String, Bool] = Map([])
  for line in body.split("\n") {
    guard line.length() > 0 && line.unsafe_get(0) == ' ' else { continue }
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
    cmd_expect(client.session.control(), "OPTS UTF8 ON", [
      status_cmd_ok, status_cmd_not_implemented_superfluous, status_syntax_error_unknown_params,
      status_not_implemented_for_param,
    ]),
  )
}
