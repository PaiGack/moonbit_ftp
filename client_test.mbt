// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// The pure half of `client.mbt`: the `MDTM` timestamp codec, the `DialOptions`
// defaults and the projection onto `Options`.
//
// `file_size` / `get_time` / `set_file_time` need a control channel, but the
// two functions they share — `parse_mdtm` and `format_mdtm` — are pure and are
// the ones a wrong answer would silently corrupt: a mistyped `mode` in a
// timestamp is invisible until a file's date changes for no reason. They get
// their own table here.

///|
test "parse_mdtm reads the yyyyMMddHHmmss shape as UTC" {
  let timestamp = @ftp.parse_mdtm("20220813133357") catch {
    _ => fail("parse_mdtm raised")
  }
  assert_eq(timestamp.year(), 2022)
  assert_eq(timestamp.month(), 8)
  assert_eq(timestamp.day(), 13)
  assert_eq(timestamp.hour(), 13)
  assert_eq(timestamp.minute(), 33)
  assert_eq(timestamp.second(), 57)
}

///|
test "parse_mdtm rejects a short field" {
  let raised = try {
    ignore(@ftp.parse_mdtm("2022081313"))
    None
  } catch {
    @ftp.FtpError::ParseError(msg~) => Some(msg)
    _ => None
  }
  assert_true(raised is Some(_))
}

///|
test "parse_mdtm rejects a non numeric field" {
  let raised = try {
    ignore(@ftp.parse_mdtm("2022081313335x"))
    None
  } catch {
    @ftp.FtpError::ParseError(_) => Some(true)
    _ => None
  }
  assert_eq(raised, Some(true))
}

///|
/// A field of the right shape but an impossible calendar date (`Feb 30`) is a
/// parse error, not a silently truncated timestamp.
test "parse_mdtm rejects an impossible calendar date" {
  let raised = try {
    ignore(@ftp.parse_mdtm("20230230000000"))
    None
  } catch {
    @ftp.FtpError::ParseError(_) => Some(true)
    _ => None
  }
  assert_eq(raised, Some(true))
}

///|
/// `format_mdtm` is the inverse of `parse_mdtm`, and it must zero-pad every
/// field: `2022-08-03 04:05:06` loses the leading zeros on the month, day,
/// hour, minute and second without it.
test "format_mdtm zero pads every field" {
  let timestamp = @ftp.parse_mdtm("20220803040506") catch {
    _ => fail("parse_mdtm raised")
  }
  assert_eq(@ftp.format_mdtm(timestamp), "20220803040506")
}

///|
test "format_mdtm round trips a modern timestamp" {
  let timestamp = @ftp.parse_mdtm("20140101000000") catch {
    _ => fail("parse_mdtm raised")
  }
  assert_eq(@ftp.format_mdtm(timestamp), "20140101000000")
}

///|
/// The `format_mdtm` -> `parse_mdtm` round trip is the property `set_file_time`
/// depends on: it formats to send and the server echoes the same shape back.
test "the MDTM codec round trips through the wire format" {
  for text in ["19700101000000", "20301231235959", "20240229010203"] {
    let timestamp = @ftp.parse_mdtm(text) catch { _ => fail("parse: \{text}") }
    assert_eq(@ftp.format_mdtm(timestamp), text)
  }
}

///|
/// Only the first 14 bytes are read, so a *trailing* junk suffix is ignored —
/// some servers append a `;` or a zone suffix after the timestamp. What must
/// not be ignored is a non digit *inside* the 14 bytes.
test "parse_mdtm reads exactly the first fourteen bytes" {
  let timestamp = @ftp.parse_mdtm("20240102030405;extra") catch {
    _ => fail("parse_mdtm raised")
  }
  assert_eq(@ftp.format_mdtm(timestamp), "20240102030405")
}

///|
/// A non digit inside the leading fourteen bytes is a parse error, not a
/// silently wrong timestamp.
test "parse_mdtm rejects a non digit inside the field" {
  let raised = try {
    ignore(@ftp.parse_mdtm("2024-102030405"))
    None
  } catch {
    @ftp.FtpError::ParseError(_) => Some(true)
    _ => None
  }
  assert_eq(raised, Some(true))
}
