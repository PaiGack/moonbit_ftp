// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
//
// Ported from jlaffaye/ftp `parse_test.go`. The upstream suite pins "now" to
// 2017-03-10 23:00 UTC so that the half-year rule assertions are stable; the
// same instant is used here.

///|
let test_now : @time.ZonedDateTime = @time.ZonedDateTime::of(
  2017,
  3,
  10,
  hour=23,
  minute=0,
  second=0,
  zone=@time.utc_zone,
) catch {
  _ => panic()
}

///|
fn parse(line : String) -> Entry raise {
  let (entry, _) = parse_list_line(line, test_now)
  entry
}

///|
test "unix ls line with a year" {
  let entry = parse(
    "drwxr-xr-x    3 110      1002            3 Dec 02  2009 pub",
  )
  assert_eq(entry.name, "pub")
  assert_eq(entry.type_, EntryType::Folder)
  assert_eq(entry.time.year(), 2009)
  assert_eq(entry.time.month(), 12)
  assert_eq(entry.time.day(), 2)
}

///|
test "unix ls line keeps spaces inside the name" {
  let entry = parse(
    "drwxr-xr-x    3 110      1002            3 Dec 02  2009 p u b",
  )
  assert_eq(entry.name, "p u b")
}

///|
test "unix ls line with a large size does not overflow" {
  let entry = parse(
    "-rw-r--r--        0   18446744073709551615 18446744073709551615 Nov 16  2006 VIDEO_TS.VOB",
  )
  assert_eq(entry.name, "VIDEO_TS.VOB")
  assert_eq(entry.size, 18446744073709551615UL)
}

///|
test "unix ls line with a symlink splits name and target" {
  let entry = parse(
    "lrwxrwxrwx   1 root     other          7 Jan 25 00:17 bin -> usr/bin",
  )
  assert_eq(entry.name, "bin")
  assert_eq(entry.target, "usr/bin")
  assert_eq(entry.type_, EntryType::Link)
  assert_eq(entry.time.year(), 2017)
}

///|
test "hostedftp line without a link count" {
  let entry = parse(
    "drwxr-xr-x               folder        0 Aug 15 05:49 !!!-Tipp des Haus!",
  )
  assert_eq(entry.type_, EntryType::Folder)
  assert_eq(entry.name, "!!!-Tipp des Haus!")
}

///|
test "hostedftp lowercase variant" {
  let entry = parse(
    "drwxr-xr-x               folder        0 Aug 11 20:32 P0RN",
  )
  assert_eq(entry.type_, EntryType::Folder)
  assert_eq(entry.name, "P0RN")
}

///|
test "rfc3659 folder entry" {
  let entry = parse("type=dir;modify=20140101000000; movies")
  assert_eq(entry.type_, EntryType::Folder)
  assert_eq(entry.name, "movies")
}

///|
test "rfc3659 file entry with a size" {
  let entry = parse("size=951;type=file;modify=20140101000000; welcome.msg")
  assert_eq(entry.type_, EntryType::File)
  assert_eq(entry.size, 951UL)
  assert_eq(entry.name, "welcome.msg")
}

///|
test "rfc3659 accepts capitalized fact names" {
  let entry = parse(
    "Modify=20140101000000;Perm=el;Size=951;Type=file; welcome.msg",
  )
  assert_eq(entry.type_, EntryType::File)
  assert_eq(entry.size, 951UL)
}

///|
test "unsupported line raises UnsupportedListLine" {
  let result = try {
    ignore(parse("this is definitely not a listing line"))
    None
  } catch {
    FtpError::UnsupportedListLine(line~) => Some(line)
    _ => None
  }
  assert_true(result is Some(_))
}

///|
test "parse_list_line reports which parser matched" {
  let (_, format) = parse_list_line("size=951;type=file; welcome.msg", test_now)
  assert_eq(format, ListFormat::Rfc3659)
  let (_, format) = parse_list_line(
    "drwxr-xr-x    3 110      1002            3 Dec 02  2009 pub", test_now,
  )
  assert_eq(format, ListFormat::UnixLs)
}

///|
test "set_size understands hexadecimal and octal prefixes" {
  assert_eq(set_size("0x10"), 16UL)
  assert_eq(set_size("0o17"), 15UL)
  assert_eq(set_size("42"), 42UL)
}

///|
/// Half-year rule boundary: `Sep 10 22:59` is less than six months ahead of
/// `now` (2017-03-10 23:00), so it stays in the current year.
test "half-year rule keeps a timestamp just under six months ahead" {
  let entry = parse(
    "-rw-r--r--   1 owner    group               0 Sep 10 22:59 a",
  )
  assert_eq(entry.time.year(), 2017)
  assert_eq(entry.time.month(), 9)
  assert_eq(entry.time.day(), 10)
  assert_eq(entry.time.hour(), 22)
  assert_eq(entry.time.minute(), 59)
}

///|
/// `Sep 10 23:00` is exactly six months ahead, which is *not earlier than*
/// `now + 6 months`, so the year is decremented.
test "half-year rule decrements at the exact six month boundary" {
  let entry = parse(
    "-rw-r--r--   1 owner    group               0 Sep 10 23:00 a",
  )
  assert_eq(entry.time.year(), 2016)
}

///|
test "half-year rule keeps a past timestamp in the current year" {
  let entry = parse(
    "-rw-r--r--   1 owner    group               0 Feb 10 23:00 a",
  )
  assert_eq(entry.time.year(), 2017)
}

///|
test "a four digit year is used verbatim" {
  let entry = parse(
    "-rwxrwxrwx   1 noone    nogroup      322 Aug 19  1996 message.ftp",
  )
  assert_eq(entry.time.year(), 1996)
  assert_eq(entry.time.month(), 8)
  assert_eq(entry.time.day(), 19)
  assert_eq(entry.name, "message.ftp")
}

// Scanner cases (the scanner is part of `parse.mbt`, ported from
// upstream `scanner_test.go`).

///|
test "scanner walks fields and keeps the separator in remaining" {
  let scanner = Scanner::new("foo  bar x  y")
  assert_eq(scanner.next(), "foo")
  assert_eq(scanner.remaining(), " bar x  y")
  assert_eq(scanner.next(), "bar")
  assert_eq(scanner.remaining(), "x  y")
  assert_eq(scanner.next(), "x")
  assert_eq(scanner.remaining(), " y")
  assert_eq(scanner.next(), "y")
  assert_eq(scanner.next(), "")
  assert_eq(scanner.remaining(), "")
}

///|
test "scanner on an empty input yields empty fields" {
  let scanner = Scanner::new("")
  assert_eq(scanner.next(), "")
  assert_eq(scanner.next(), "")
  assert_eq(scanner.remaining(), "")
}

///|
test "scanner next_fields stops without raising when input runs out" {
  let scanner = Scanner::new("a b")
  assert_eq(scanner.next_fields(5), ["a", "b"])
}

///|
test "scanner tolerates a leading run of spaces" {
  let scanner = Scanner::new("   a b")
  assert_eq(scanner.next(), "a")
  assert_eq(scanner.next(), "b")
  assert_eq(scanner.next(), "")
}
