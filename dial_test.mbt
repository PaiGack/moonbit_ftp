// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
//
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// The pure half of `dial.mbt`: address splitting, decimal parsing, `FEAT`
// parsing and the negotiated capability flags.
//
// `dial` itself needs a server, but everything it decides *after* the socket is
// open lives here: which port a bare host defaults to, which capability flags a
// `FEAT` body turns on, and which commands the `AUTH TLS` step puts on the
// wire. Those are the parts a caller sees, and they are reachable in process.

///|
test "split_addr defaults the port when none is given" {
  assert_eq(@ftp.split_addr("example.com", 21), ("example.com", 21))
  assert_eq(@ftp.split_addr("example.com", 990), ("example.com", 990))
}

///|
test "split_addr reads an explicit port" {
  assert_eq(@ftp.split_addr("127.0.0.1:2121", 21), ("127.0.0.1", 2121))
  assert_eq(@ftp.split_addr("example.com:990", 21), ("example.com", 990))
}

///|
/// A malformed port falls back to the default instead of raising: the caller
/// asked for `host:port`, and a non numeric tail is treated as "no port".
test "split_addr falls back on a non numeric port" {
  assert_eq(@ftp.split_addr("example.com:abc", 21), ("example.com", 21))
  assert_eq(@ftp.split_addr("example.com:", 21), ("example.com", 21))
  assert_eq(@ftp.split_addr("example.com:21x", 21), ("example.com", 21))
}

///|
test "parse_decimal accepts digits and rejects everything else" {
  assert_eq(@ftp.parse_decimal("0"), Some(0))
  assert_eq(@ftp.parse_decimal("21"), Some(21))
  assert_eq(@ftp.parse_decimal("2121"), Some(2121))
  assert_true(@ftp.parse_decimal("") is None)
  assert_true(@ftp.parse_decimal("2a") is None)
  assert_true(@ftp.parse_decimal("-1") is None)
  assert_true(@ftp.parse_decimal(" 21") is None)
}

///|
/// The feature list decides `MLSD` / `MFMT` / `MDTM` / `PRET`, so a missed
/// name silently changes which command the client sends.
test "parse_features caches the capabilities the client asks for" {
  let features = @ftp.parse_features(
    "Features:\n MLST\n MDTM\n MFMT\n PRET\n UTF8\nEnd",
  )
  assert_true(features.contains("MLST"))
  assert_true(features.contains("MDTM"))
  assert_true(features.contains("MFMT"))
  assert_true(features.contains("PRET"))
  assert_true(features.contains("UTF8"))
  assert_eq(features.length(), 5)
}

///|
/// A feature line with no description is cached under its own name; the
/// uppercase form is what `has_feature` looks up.
test "parse_features uppercases a bare feature name" {
  let features = @ftp.parse_features("Features:\n mlst\nEnd")
  assert_true(features.contains("MLST"))
  assert_false(features.contains("mlst"))
}

///|
/// A continuation line holding only a space trims to nothing and must be
/// dropped instead of cached as an empty feature name.
test "parse_features drops a whitespace-only feature line" {
  let features = @ftp.parse_features("Features:\n \n MLST\nEnd")
  assert_true(features.contains("MLST"))
  assert_false(features.contains(""))
  assert_eq(features.length(), 1)
}
