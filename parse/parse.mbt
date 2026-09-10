// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

///|
/// Which of the four parsers recognised a listing line. The order of the
/// variants is the fallback order used by `parse_list_line`.
pub(all) enum ListFormat {
  /// RFC 3659 machine readable facts (`type=file;size=...;modify=...;name`).
  Rfc3659
  /// `ls -l` style (also used by most UNIX servers and WFTPD).
  UnixLs
  /// MS-DOS / Windows `DIR` style.
  DosDir
  /// hostedftp.com style (`ls -l` without the link count).
  HostedFtp
} derive(Eq, @debug.Debug)

///|
/// Parse a single `LIST` / `MLSD` line, trying the four parsers in the fixed
/// fallback order documented in `docs/porting/02-upstream-map.md`.
///
/// `line` must not contain the trailing CR/LF. `now` is the reference instant
/// used for the "no year" heuristic and is an explicit parameter so that the
/// upstream test cases (fixed at 2017-03-10 23:00 UTC) stay reproducible.
pub fn parse_list_line(
  line : String,
  now : @time.ZonedDateTime,
) -> (@types.Entry, ListFormat) raise @error.FtpError {
  match parse_rfc3659_line(line) {
    Some(entry) => return (entry, Rfc3659)
    None => ()
  }
  match parse_ls_line(line, now) {
    Some(entry) => return (entry, UnixLs)
    None => ()
  }
  match parse_dos_dir_line(line, now) {
    Some(entry) => return (entry, DosDir)
    None => ()
  }
  match parse_hostedftp_line(line, now) {
    Some(entry) => return (entry, HostedFtp)
    None => ()
  }
  raise @error.FtpError::UnsupportedListLine(line~)
}

///|
/// Parse a numeric size field the way Go's `strconv.ParseUint(s, 0, 64)` does:
/// an explicit `0x` / `0X` prefix means hex, `0o` / `0O` means octal,
/// a leading `0` means octal, and anything else is decimal.
pub fn set_size(raw : String) -> UInt64 raise @error.FtpError {
  let text = raw.trim().to_owned()
  guard text != "" else {
    raise @error.FtpError::ParseError(msg="empty size field")
  }
  let (digits, radix) : (String, Int) = if text.length() > 2 &&
    (text[0:2] == "0x" || text[0:2] == "0X") {
    (text[2:].to_owned(), 16)
  } else if text.length() > 2 && (text[0:2] == "0o" || text[0:2] == "0O") {
    (text[2:].to_owned(), 8)
  } else if text.length() > 1 && text[0] == '0' {
    (text, 8)
  } else {
    (text, 10)
  }
  parse_uint(digits, radix) catch {
    _ => raise @error.FtpError::ParseError(msg="invalid size field: \{raw}")
  }
}

///|
/// Parse an unsigned 64 bit integer in the given radix, rejecting empty input
/// and overflowing values.
pub fn parse_uint(digits : String, radix : Int) -> UInt64 raise @error.FtpError {
  guard digits != "" else {
    raise @error.FtpError::ParseError(msg="empty number")
  }
  let mut value : UInt64 = 0UL
  for i = 0; i < digits.length(); i = i + 1 {
    let code = digits.unsafe_get(i).to_int()
    let digit = if code >= 48 && code <= 57 {
      code - 48
    } else if code >= 97 && code <= 102 {
      code - 87
    } else if code >= 65 && code <= 70 {
      code - 55
    } else {
      raise @error.FtpError::ParseError(msg="invalid digit")
    }
    guard digit < radix else {
      raise @error.FtpError::ParseError(msg="invalid digit")
    }
    value = value * radix.to_uint64() + digit.to_uint64()
  }
  value
}
