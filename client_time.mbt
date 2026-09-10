// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

///|
/// `SIZE <path>`, expecting `213`.
pub async fn file_size(client : FTPClient, path : String) -> UInt64 {
  client.lock()
  defer client.unlock()
  let response = cmd_format(client.session.control(), "SIZE {}", [path], [
    status_file_status,
  ])
  let text = response.message().trim().to_owned()
  parse_uint(text, 10) catch {
    _ => raise FtpError::ParseError(msg="invalid SIZE response: \{text}")
  }
}

///|
/// `MDTM <path>`, expecting `213` and a `yyyyMMddHHmmss` UTC timestamp.
pub async fn get_time(client : FTPClient, path : String) -> @time.ZonedDateTime {
  client.lock()
  defer client.unlock()
  let response = cmd_format(client.session.control(), "MDTM {}", [path], [
    status_file_status,
  ])
  parse_mdtm(response.message().trim().to_owned())
}

///|
/// Parse a `yyyyMMddHHmmss` timestamp as UTC.
pub fn parse_mdtm(text : String) -> @time.ZonedDateTime raise FtpError {
  guard text.length() >= 14 else {
    raise FtpError::ParseError(msg="invalid MDTM response: \{text}")
  }
  let year = digit_field(text, 0, 4)
  let month = digit_field(text, 4, 2)
  let day = digit_field(text, 6, 2)
  let hour = digit_field(text, 8, 2)
  let minute = digit_field(text, 10, 2)
  let second = digit_field(text, 12, 2)
  @time.ZonedDateTime::of(
    year,
    month,
    day,
    hour~,
    minute~,
    second~,
    zone=@time.utc_zone,
  ) catch {
    _ => raise FtpError::ParseError(msg="invalid MDTM response: \{text}")
  }
}

///|
/// Read a fixed width decimal field or raise.
fn digit_field(src : String, start : Int, width : Int) -> Int raise FtpError {
  guard start + width <= src.length() else {
    raise FtpError::ParseError(msg="invalid date field")
  }
  let mut value = 0
  for i = start; i < start + width; i = i + 1 {
    let c = src.unsafe_get(i).to_int()
    guard c >= 48 && c <= 57 else {
      raise FtpError::ParseError(msg="invalid date field")
    }
    value = value * 10 + (c - 48)
  }
  value
}

///|
/// Set the modification time of `path`.
///
/// `MFMT` is tried first; when the server only advertises `MDTM` and
/// `writing_mdtm` is set, the VsFtpd quirk `MDTM <time> <path>` is used
/// instead. When neither is available the call raises `ServerError` with
/// code `502`, matching upstream's "not implemented" behaviour.
pub async fn set_file_time(
  client : FTPClient,
  path : String,
  timestamp : @time.ZonedDateTime,
) -> Unit {
  client.lock()
  defer client.unlock()
  let encoded = format_mdtm(timestamp)
  if client.mfmt_supported {
    ignore(
      cmd_format(client.session.control(), "MFMT {} {}", [encoded, path], [
        status_file_status,
      ]),
    )
    return
  }
  if client.mdtm_supported && client.mdtm_can_write {
    ignore(
      cmd_format(client.session.control(), "MDTM {} {}", [encoded, path], [
        status_file_status,
      ]),
    )
    return
  }
  raise FtpError::ServerError(
    code=status_not_implemented,
    msg="server does not support setting modification time",
  )
}

///|
/// Render a timestamp as `yyyyMMddHHmmss` in UTC.
pub fn format_mdtm(timestamp : @time.ZonedDateTime) -> String {
  let utc = timestamp.to_plain_date_time()
  pad(utc.year(), 4) +
  pad(utc.month(), 2) +
  pad(utc.day(), 2) +
  pad(utc.hour(), 2) +
  pad(utc.minute(), 2) +
  pad(utc.second(), 2)
}

///|
/// Left-pad `value` with zeros to `width` digits.
fn pad(value : Int, width : Int) -> String {
  let text = value.to_string()
  let missing = width - text.length()
  guard missing > 0 else { return text }
  let prefix = StringBuilder()
  for i = 0; i < missing; i = i + 1 {
    prefix.write_char('0')
  }
  prefix.to_string() + text
}
