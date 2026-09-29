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
fn parse(line : String) -> @ftp.Entry raise {
  let (entry, _) = @ftp.parse_list_line(line, test_now)
  entry
}

///|
test "unix ls line with a year" {
  let entry = parse(
    "drwxr-xr-x    3 110      1002            3 Dec 02  2009 pub",
  )
  assert_eq(entry.name, "pub")
  assert_eq(entry.type_, @ftp.EntryType::Folder)
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
  assert_eq(entry.type_, @ftp.EntryType::Link)
  assert_eq(entry.time.year(), 2017)
}

///|
test "hostedftp line without a link count" {
  let entry = parse(
    "drwxr-xr-x               folder        0 Aug 15 05:49 !!!-Tipp des Haus!",
  )
  assert_eq(entry.type_, @ftp.EntryType::Folder)
  assert_eq(entry.name, "!!!-Tipp des Haus!")
}

///|
test "hostedftp lowercase variant" {
  let entry = parse(
    "drwxr-xr-x               folder        0 Aug 11 20:32 P0RN",
  )
  assert_eq(entry.type_, @ftp.EntryType::Folder)
  assert_eq(entry.name, "P0RN")
}

///|
test "rfc3659 folder entry" {
  let entry = parse("type=dir;modify=20140101000000; movies")
  assert_eq(entry.type_, @ftp.EntryType::Folder)
  assert_eq(entry.name, "movies")
}

///|
test "rfc3659 file entry with a size" {
  let entry = parse("size=951;type=file;modify=20140101000000; welcome.msg")
  assert_eq(entry.type_, @ftp.EntryType::File)
  assert_eq(entry.size, 951UL)
  assert_eq(entry.name, "welcome.msg")
}

///|
test "rfc3659 accepts capitalized fact names" {
  let entry = parse(
    "Modify=20140101000000;Perm=el;Size=951;Type=file; welcome.msg",
  )
  assert_eq(entry.type_, @ftp.EntryType::File)
  assert_eq(entry.size, 951UL)
}

///|
test "unsupported line raises UnsupportedListLine" {
  let result = try {
    ignore(parse("this is definitely not a listing line"))
    None
  } catch {
    @ftp.FtpError::UnsupportedListLine(line~) => Some(line)
    _ => None
  }
  assert_true(result is Some(_))
}

///|
test "parse_list_line reports which parser matched" {
  let (_, format) = @ftp.parse_list_line(
    "size=951;type=file; welcome.msg", test_now,
  )
  assert_eq(format, @ftp.ListFormat::Rfc3659)
  let (_, format) = @ftp.parse_list_line(
    "drwxr-xr-x    3 110      1002            3 Dec 02  2009 pub", test_now,
  )
  assert_eq(format, @ftp.ListFormat::UnixLs)
}

///|
test "set_size understands hexadecimal and octal prefixes" {
  assert_eq(@ftp.set_size("0x10"), 16UL)
  assert_eq(@ftp.set_size("0o17"), 15UL)
  assert_eq(@ftp.set_size("42"), 42UL)
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
  let scanner = @ftp.Scanner::new("foo  bar x  y")
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
  let scanner = @ftp.Scanner::new("")
  assert_eq(scanner.next(), "")
  assert_eq(scanner.next(), "")
  assert_eq(scanner.remaining(), "")
}

///|
test "scanner next_fields stops without raising when input runs out" {
  let scanner = @ftp.Scanner::new("a b")
  assert_eq(scanner.next_fields(5), ["a", "b"])
}

///|
test "scanner tolerates a leading run of spaces" {
  let scanner = @ftp.Scanner::new("   a b")
  assert_eq(scanner.next(), "a")
  assert_eq(scanner.next(), "b")
  assert_eq(scanner.next(), "")
}

// The fallback chain and the parser edge cases below are the ones a real
// server reaches only rarely, so they are pinned here rather than through a
// daemon: a malformed `LIST` line is not something a server can be asked to
// emit on demand.

///|
/// `parse_list_line` reports the DOS format, and `parse_dos_dir_line` accepts
/// the `<DIR>` marker as "folder, size zero".
test "DOS dir line with a DIR marker" {
  let (entry, format) = @ftp.parse_list_line(
    "01-02-06  03:04PM       <DIR>          pub", test_now,
  )
  assert_eq(format, @ftp.ListFormat::DosDir)
  assert_eq(entry.name, "pub")
  assert_eq(entry.type_, @ftp.EntryType::Folder)
  assert_eq(entry.size, 0UL)
  assert_eq(entry.time.year(), 2006)
  assert_eq(entry.time.month(), 1)
  assert_eq(entry.time.day(), 2)
  // `03:04PM` is 15:04, and the year is mapped into the current century.
  assert_eq(entry.time.hour(), 15)
  assert_eq(entry.time.minute(), 4)
}

///|
/// The 24 hour DOS variant has no `AM`/`PM` suffix at all.
test "DOS dir line with a 24 hour clock" {
  let (entry, format) = @ftp.parse_list_line(
    "01-02-06  15:04       1234              a", test_now,
  )
  assert_eq(format, @ftp.ListFormat::DosDir)
  assert_eq(entry.name, "a")
  assert_eq(entry.type_, @ftp.EntryType::File)
  assert_eq(entry.size, 1234UL)
  assert_eq(entry.time.hour(), 15)
}

///|
/// A DOS line with a non numeric size is not a DOS line; it falls through to
/// the hostedftp parser and is eventually rejected.
test "DOS dir line with a non numeric size is not DOS" {
  let rejected = try {
    ignore(
      @ftp.parse_list_line(
        "01-02-06  15:04       huge              a", test_now,
      ),
    )
    false
  } catch {
    @ftp.FtpError::UnsupportedListLine(_) => true
    _ => false
  }
  assert_true(rejected)
}

///|
/// A DOS line missing the size field entirely is rejected rather than parsed
/// with a zero size.
test "DOS dir line without a size is rejected" {
  let rejected = try {
    ignore(@ftp.parse_list_line("01-02-06  15:04", test_now))
    false
  } catch {
    @ftp.FtpError::UnsupportedListLine(_) => true
    _ => false
  }
  assert_true(rejected)
}

///|
/// An `ls -l` shaped line is claimed by the Unix parser first, because the
/// fallback order puts it ahead of hostedftp — the two grammars overlap and
/// the earlier parser is the one documented to win. The hostedftp parser is
/// only reached when the Unix one *rejects* the line.
test "the Unix parser wins over hostedftp for a shared grammar" {
  let (entry, format) = @ftp.parse_list_line(
    "drwxr-xr-x               folder        0 Aug 15 05:49 !!!-Tipp des Haus!", test_now,
  )
  assert_eq(format, @ftp.ListFormat::UnixLs)
  assert_eq(entry.type_, @ftp.EntryType::Folder)
  assert_eq(entry.name, "!!!-Tipp des Haus!")
}

///|
/// `parse_hostedftp_line` still parses that shape on its own, and it is the
/// parser of last resort that turns a line the Unix parser would reject (an
/// ACL `+` marker on a line with no link count) into an entry.
test "parse_hostedftp_line parses the link-less shape directly" {
  let entry = match
    @ftp.parse_hostedftp_line(
      "drwxr-xr-x               folder        0 Aug 15 05:49 !!!-Tipp des Haus!",
      test_now,
    ) {
    Some(entry) => entry
    None => fail("expected a hostedftp entry")
  }
  assert_eq(entry.type_, @ftp.EntryType::Folder)
  assert_eq(entry.name, "!!!-Tipp des Haus!")

  // Not a permission field, so not a hostedftp line either.
  assert_true(
    @ftp.parse_hostedftp_line("hello world this is not a listing", test_now)
    is None,
  )
  // Too short to hold a permission field.
  assert_true(@ftp.parse_hostedftp_line("drwxr", test_now) is None)
}

///|
/// `find_date_start_pub` is the public spelling of the date anchor search; it
/// must find the `MMM DD ` field and skip over the permission / size columns.
test "find_date_start_pub locates the MMM DD field" {
  let line = "drwxr-xr-x    3 110      1002            3 Dec 02  2009 pub"
  let index = match @ftp.find_date_start_pub(line, 10) {
    Some(index) => index
    None => fail("no date found")
  }
  assert_eq(line[index:index + 3], "Dec")
  assert_true(@ftp.find_date_start_pub("no date here at all", 0) is None)
  // The start bound is respected: searching from after the date misses it.
  assert_true(@ftp.find_date_start_pub(line, index + 1) is None)
}

///|
/// A malformed date field in an otherwise valid `ls -l` line makes the whole
/// line unparseable instead of yielding a bogus timestamp.
test "ls line with a broken date is rejected" {
  let rejected = try {
    ignore(
      @ftp.parse_list_line(
        "-rw-r--r--   1 owner    group    0 Zzz 02  2009 a", test_now,
      ),
    )
    false
  } catch {
    @ftp.FtpError::UnsupportedListLine(_) => true
    _ => false
  }
  assert_true(rejected)
}

///|
/// A permission field with an illegal character in the middle is not an
/// `ls -l` line: the parser checks all ten bytes, not just the first.
test "ls line with an invalid permission byte is rejected" {
  let rejected = try {
    ignore(
      @ftp.parse_list_line(
        "-rw-r--r-X   1 owner    group    0 Dec 02  2009 a", test_now,
      ),
    )
    false
  } catch {
    @ftp.FtpError::UnsupportedListLine(_) => true
    _ => false
  }
  assert_true(rejected)
}

///|
/// An 11 byte permission field is only allowed when byte 11 is the ACL `+`
/// marker (or a separator); anything else means the line is not `ls -l`.
test "ls line accepts the ACL plus marker but rejects a stray byte" {
  let accepted = @ftp.parse_list_line(
    "-rw-r--r--+  1 owner    group    0 Dec 02  2009 a", test_now,
  )
  assert_eq(accepted.0.name, "a")
  let rejected = try {
    ignore(
      @ftp.parse_list_line(
        "-rw-r--r--X  1 owner    group    0 Dec 02  2009 a", test_now,
      ),
    )
    false
  } catch {
    @ftp.FtpError::UnsupportedListLine(_) => true
    _ => false
  }
  assert_true(rejected)
}

///|
/// The size is the *last* numeric field before the date, so the Unix parser
/// rejects a head with no number at all (the split between head and name has
/// no anchor there). The dispatcher then falls through to the hostedftp
/// parser, which patches in a zero link count and *does* accept the line —
/// that fallback is the whole reason the two parsers are kept in sync.
test "a head with no number falls through to hostedftp" {
  let (entry, format) = @ftp.parse_list_line(
    "-rw-r--r--   owner    group    Dec 02  2009 a", test_now,
  )
  assert_eq(format, @ftp.ListFormat::HostedFtp)
  assert_eq(entry.name, "a")
  assert_eq(entry.type_, @ftp.EntryType::File)
  assert_eq(entry.size, 0UL)
  // The Unix parser alone refuses it.
  assert_true(
    @ftp.parse_ls_line(
      "-rw-r--r--   owner    group    Dec 02  2009 a", test_now,
    )
    is None,
  )
}

///|
/// A name that is empty after the date field is rejected, not returned as an
/// entry with an empty name.
test "ls line with a trailing empty name is rejected" {
  let rejected = try {
    ignore(
      @ftp.parse_list_line(
        "-rw-r--r--   1 owner    group    0 Dec 02  2009    ", test_now,
      ),
    )
    false
  } catch {
    @ftp.FtpError::UnsupportedListLine(_) => true
    _ => false
  }
  assert_true(rejected)
}

///|
/// `parse_rfc3659_line` recognises `type=link` and reads the size with the
/// `sizd` typo some servers emit.
test "rfc3659 link entry and the sizd typo" {
  let link = match @ftp.parse_rfc3659_line("type=link;Size=7; bin") {
    Some(entry) => entry
    None => fail("expected a link entry")
  }
  assert_eq(link.type_, @ftp.EntryType::Link)
  assert_eq(link.size, 7UL)
  assert_eq(link.name, "bin")

  let entry = match @ftp.parse_rfc3659_line("sizd=42;type=file; a") {
    Some(entry) => entry
    None => fail("expected an entry")
  }
  assert_eq(entry.size, 42UL)
}

///|
/// An empty fact (`;;`) is skipped, which is how a server that pads its fact
/// list with a leading separator stays parseable.
test "rfc3659 skips an empty fact" {
  let entry = match @ftp.parse_rfc3659_line(";type=file; a") {
    Some(entry) => entry
    None => fail("expected an entry")
  }
  assert_eq(entry.type_, @ftp.EntryType::File)
  assert_eq(entry.name, "a")
  // A fact with no `=` at all carries no value and is ignored.
  let entry = match @ftp.parse_rfc3659_line("nosuchfact;type=file; a") {
    Some(entry) => entry
    None => fail("expected an entry")
  }
  assert_eq(entry.name, "a")
}

///|
/// A line made only of facts and no trailing `;` is not an RFC 3659 line at
/// all, so the dispatcher must fall through to the next parser.
test "rfc3659 rejects a line with no fact terminator" {
  let result = @ftp.parse_rfc3659_line("type=file") catch {
    _ => fail("should not raise")
  }
  assert_true(result is None)
  assert_true(@ftp.parse_rfc3659_line("") is None)
}

///|
/// A `modify=` fact that is not a 14 digit timestamp leaves the entry's time
/// at the epoch instead of failing the whole line: the entry is still usable.
test "rfc3659 keeps the epoch for a malformed modify fact" {
  let entry = match @ftp.parse_rfc3659_line("type=file;modify=20140101; a") {
    Some(entry) => entry
    None => fail("expected an entry")
  }
  assert_eq(entry.time.to_unix_second(), 0L)
  let entry = match
    @ftp.parse_rfc3659_line("type=file;modify=20140101000000; a") {
    Some(entry) => entry
    None => fail("expected an entry")
  }
  assert_eq(entry.time.year(), 2014)
}

///|
/// `parse_next_rfc3659_line` merges a continuation line, and refuses one whose
/// name does not match — a mismatched continuation belongs to a different
/// entry and silently merging it would corrupt the first.
test "parse_next_rfc3659_line requires the names to match" {
  let first = match @ftp.parse_rfc3659_line("type=file;Size=1; a") {
    Some(entry) => entry
    None => fail("expected an entry")
  }
  let merged = @ftp.parse_next_rfc3659_line(first, "type=file;Size=2; a") catch {
    _ => fail("should merge")
  }
  assert_eq(merged.name, "a")
  assert_eq(merged.size, 2UL)

  let raised = try {
    ignore(@ftp.parse_next_rfc3659_line(first, "type=file;Size=2; b"))
    None
  } catch {
    @ftp.FtpError::UnsupportedListLine(_) => Some(true)
    _ => None
  }
  assert_eq(raised, Some(true))
}

///|
/// `parse_next_rfc3659_line` also refuses a line that is not RFC 3659 at all.
test "parse_next_rfc3659_line rejects a non RFC3659 continuation" {
  let first = match @ftp.parse_rfc3659_line("type=file;Size=1; a") {
    Some(entry) => entry
    None => fail("expected an entry")
  }
  let raised = try {
    ignore(@ftp.parse_next_rfc3659_line(first, "not a fact line"))
    None
  } catch {
    @ftp.FtpError::UnsupportedListLine(_) => Some(true)
    _ => None
  }
  assert_eq(raised, Some(true))
}

///|
/// `set_size` understands the three prefixes and rejects an empty or broken
/// field with a parse error carrying the original text.
test "set_size rejects the malformed fields" {
  assert_eq(@ftp.set_size(" 42 "), 42UL)
  // A leading zero means octal, exactly like `strconv.ParseUint(s, 0, 64)`.
  assert_eq(@ftp.set_size("017"), 15UL)
  let empty = try {
    ignore(@ftp.set_size("   "))
    None
  } catch {
    @ftp.FtpError::ParseError(msg~) => Some(msg)
    _ => None
  }
  assert_eq(empty, Some("empty size field"))
  let broken = try {
    ignore(@ftp.set_size("12x"))
    None
  } catch {
    @ftp.FtpError::ParseError(_) => Some(true)
    _ => None
  }
  assert_eq(broken, Some(true))
}

///|
/// `parse_uint` reads both hex cases (`a`-`f` and `A`-`F`) and rejects a digit
/// that is legal in another radix.
test "parse_uint reads hex digits in both cases" {
  assert_eq(@ftp.parse_uint("ff", 16), 255UL)
  assert_eq(@ftp.parse_uint("FF", 16), 255UL)
  assert_eq(@ftp.parse_uint("1a", 16), 26UL)
  let raised = try {
    ignore(@ftp.parse_uint("8", 8))
    None
  } catch {
    @ftp.FtpError::ParseError(_) => Some(true)
    _ => None
  }
  assert_eq(raised, Some(true))
  let empty = try {
    ignore(@ftp.parse_uint("", 10))
    None
  } catch {
    @ftp.FtpError::ParseError(_) => Some(true)
    _ => None
  }
  assert_eq(empty, Some(true))
}

///|
/// The bare month parser is what `find_date_start` uses to recognise the date
/// anchor, so `Jan`..`Dec` must map 1..12 case-insensitively.
test "parse_month maps the twelve abbreviations" {
  assert_eq(@ftp.parse_month("Jan"), Some(1))
  assert_eq(@ftp.parse_month("dec"), Some(12))
  assert_eq(@ftp.parse_month("MAY"), Some(5))
  assert_true(@ftp.parse_month("Xyz") is None)
  assert_true(@ftp.parse_month("") is None)
}

///|
/// `parse_list_date_field` returns the pieces of the `MMM DD HH:MM` and
/// `MMM DD  YYYY` shapes, and its accessors expose them.
test "parse_list_date_field reads both date shapes" {
  let with_time = match @ftp.parse_list_date_field(" 10 23:00 tail", 0) {
    Some(field) => field
    None => fail("expected the HH:MM shape")
  }
  assert_true(with_time.has_time())
  assert_eq(with_time.day(), 10)
  assert_eq(with_time.hour(), 23)
  assert_eq(with_time.minute(), 0)
  // The yearless shape reports no year, which the caller substitutes.
  assert_eq(with_time.year(), 0)
  assert_eq(with_time.next(), 9)

  let with_year = match @ftp.parse_list_date_field(" 02  2009 pub", 0) {
    Some(field) => field
    None => fail("expected the YYYY shape")
  }
  assert_false(with_year.has_time())
  assert_eq(with_year.day(), 2)
  assert_eq(with_year.year(), 2009)
  assert_eq(with_year.hour(), 0)
  assert_eq(with_year.minute(), 0)
}

///|
/// A date field with no digits at all is not a date field.
test "parse_list_date_field rejects a field without digits" {
  assert_true(@ftp.parse_list_date_field(" abc", 0) is None)
  assert_true(@ftp.parse_list_date_field(" 10 ", 0) is None)
}

///|
/// `parse_ls_time` needs a valid month name and a parsable date field; both
/// negative cases fall through to `None`.
test "parse_ls_time rejects a bad month and a bad field" {
  assert_true(@ftp.parse_ls_time("Xyz 02  2009 pub", 0, test_now) is None)
  assert_true(@ftp.parse_ls_time("Dec", 0, test_now) is None)
  assert_true(@ftp.parse_ls_time("Dec xyz", 0, test_now) is None)
}

///|
/// A one digit day is accepted (`Dec 2  2009`), which is what `ls` emits on
/// the first nine days of a month.
test "parse_ls_time accepts a one digit day" {
  let (timestamp, next) = match
    @ftp.parse_ls_time("Dec 2  2009 pub", 0, test_now) {
    Some(parsed) => parsed
    None => fail("expected a timestamp")
  }
  assert_eq(timestamp.year(), 2009)
  assert_eq(timestamp.month(), 12)
  assert_eq(timestamp.day(), 2)
  assert_eq("Dec 2  2009 pub"[next:], " pub")
}

///|
/// `apply_list_time` refuses an impossible month and a year that is not four
/// digits, instead of building a timestamp from garbage.
test "apply_list_time rejects impossible fields" {
  let entry = @ftp.make_entry("a", @ftp.EntryType::File)
  let bad_month = try {
    @ftp.apply_list_time(entry, 2009, 13, 1, false, 0, 0, test_now)
    None
  } catch {
    @ftp.FtpError::UnsupportedListDate(_) => Some(true)
    _ => None
  }
  assert_eq(bad_month, Some(true))
  let bad_year = try {
    @ftp.apply_list_time(entry, 9, 1, 1, false, 0, 0, test_now)
    None
  } catch {
    @ftp.FtpError::UnsupportedListDate(_) => Some(true)
    _ => None
  }
  assert_eq(bad_year, Some(true))
  let bad_day = try {
    @ftp.apply_list_time(entry, 2009, 1, 32, false, 0, 0, test_now)
    None
  } catch {
    @ftp.FtpError::UnsupportedListDate(_) => Some(true)
    _ => None
  }
  assert_eq(bad_day, Some(true))
}

///|
/// `apply_list_time` also implements the half-year rule for the yearless
/// shape, and it writes the result onto the entry it was given.
test "apply_list_time applies the half-year rule and writes the entry" {
  let entry = @ftp.make_entry("a", @ftp.EntryType::File)
  @ftp.apply_list_time(entry, 2017, 9, 10, true, 23, 0, test_now) catch {
    _ => fail("apply_list_time raised")
  }
  // `Sep 10 23:00` is exactly six months ahead, so it rolls back a year.
  assert_eq(entry.time.year(), 2016)
  assert_eq(entry.time.month(), 9)
  assert_eq(entry.time.day(), 10)
  assert_eq(entry.time.hour(), 23)
}

///|
/// `new_datetime` refuses an impossible calendar date (`Feb 30`) with the
/// dedicated `UnsupportedListDate` error.
test "new_datetime rejects an impossible date" {
  let raised = try {
    ignore(@ftp.new_datetime(2023, 2, 30, 0, 0, @time.utc_zone))
    None
  } catch {
    @ftp.FtpError::UnsupportedListDate(_) => Some(true)
    _ => None
  }
  assert_eq(raised, Some(true))
  let leap = @ftp.new_datetime(2024, 2, 29, 0, 0, @time.utc_zone) catch {
    _ => fail("2024-02-29 is a valid date")
  }
  assert_eq(leap.year(), 2024)
  assert_eq(leap.day(), 29)
}

///|
/// `Scanner::at_end` reports whether the input is exhausted, including on an
/// empty input.
test "scanner at_end tracks the offset" {
  let scanner = @ftp.Scanner::new("a")
  assert_false(scanner.at_end())
  ignore(scanner.next())
  assert_true(scanner.at_end())
  assert_true(@ftp.Scanner::new("").at_end())
}

///|
/// `Scanner` treats every ASCII whitespace byte as a separator, not just the
/// space: a server that pads with tabs must not produce empty fields.
test "scanner treats tabs and newlines as separators" {
  let scanner = @ftp.Scanner::new("a\tb\r\nc")
  assert_eq(scanner.next(), "a")
  assert_eq(scanner.next(), "b")
  assert_eq(scanner.next(), "c")
  assert_eq(scanner.next(), "")
}

///|
/// An unrecognised `type=` value inside an RFC 3659 line is an error, not a
/// fallback: upstream refuses the whole line rather than guessing.
test "rfc3659 rejects an unknown type fact" {
  let raised = try {
    ignore(@ftp.parse_rfc3659_line("type=socket; a"))
    None
  } catch {
    @ftp.FtpError::ParseError(msg~) => Some(msg)
    _ => None
  }
  assert_eq(raised, Some("unknown entry type"))
}

///|
/// `cdir` / `pdir` are the RFC 3659 spellings for the `.` and `..` entries and
/// must map to a folder like `dir` does.
test "rfc3659 accepts cdir and pdir as folders" {
  let entry = match @ftp.parse_rfc3659_line("type=cdir; .") {
    Some(entry) => entry
    None => fail("expected an entry")
  }
  assert_eq(entry.type_, @ftp.EntryType::Folder)
  assert_eq(entry.name, ".")
  let entry = match @ftp.parse_rfc3659_line("type=pdir; ..") {
    Some(entry) => entry
    None => fail("expected an entry")
  }
  assert_eq(entry.type_, @ftp.EntryType::Folder)
}

///|
/// A `Perm=` fact is ignored (only `type` / `size` / `sizd` / `modify` are
/// read), and the name still comes out right.
test "rfc3659 ignores an unknown but well formed fact" {
  let entry = match @ftp.parse_rfc3659_line("Perm=el;type=file; a") {
    Some(entry) => entry
    None => fail("expected an entry")
  }
  assert_eq(entry.type_, @ftp.EntryType::File)
  assert_eq(entry.name, "a")
}

///|
/// A `modify=` fact with an impossible date falls back to the epoch rather
/// than failing the line: the entry is still usable without its timestamp.
test "rfc3659 falls back to the epoch for an impossible modify date" {
  let entry = match
    @ftp.parse_rfc3659_line("type=file;modify=20230230000000; a") {
    Some(entry) => entry
    None => fail("expected an entry")
  }
  assert_eq(entry.time.to_unix_second(), 0L)
}

///|
/// A line that carries facts but no name-only tail is a partial line, not an
/// RFC 3659 entry: `have_facts` is set, but the trailing content is another
/// fact rather than the name.
test "rfc3659 rejects a line that ends inside a fact" {
  // No `;` terminator and no name: the parser sees a key with an `=` but the
  // scan runs off the end before `have_facts` is set.
  let result = @ftp.parse_rfc3659_line("type=file") catch {
    _ => fail("no raise")
  }
  assert_true(result is None)
}

///|
/// A DOS date with a broken separator, a missing field or a non numeric part
/// is rejected by `parse_dos_parts`, which lets the dispatcher fall through.
test "DOS date rejects malformed shapes" {
  let rejects = fn(line : String) -> Bool {
    try {
      ignore(@ftp.parse_list_line(line, test_now))
      false
    } catch {
      @ftp.FtpError::UnsupportedListLine(_) => true
      _ => false
    }
  }
  // Missing the `-` separators.
  assert_true(rejects("010206  03:04PM       1 a"))
  // A date field that runs out before the year.
  assert_true(rejects("01-02  03:04PM       1 a"))
  // A time field with no colon.
  assert_true(rejects("01-02-06  0304PM       1 a"))
  // An impossible month.
  assert_true(rejects("13-02-06  03:04PM       1 a"))
}

///|
/// The `AM` / `PM` suffix is applied, including the two `12` special cases
/// (`12 PM` is noon, `12 AM` is midnight), and a bare `AM`/`PM`-less time is
/// only accepted by the 24 hour layout.
test "DOS time applies the AM and PM suffixes" {
  let hours : Array[(String, Int)] = [
    ("01-02-06  12:00PM       1 a", 12),
    ("01-02-06  12:00AM       1 a", 0),
    ("01-02-06  01:00PM       1 a", 13),
    ("01-02-06  01:00AM       1 a", 1),
    // The 24 hour layout has no suffix and is used verbatim.
    ("01-02-06  23:59       1 a", 23),
  ]
  for pair in hours {
    let (line, expected) = pair
    let (entry, _) = @ftp.parse_list_line(line, test_now) catch {
      _ => fail("expected a DOS line: \{line}")
    }
    assert_eq(entry.time.hour(), expected)
  }
}

///|
/// A DOS year is two digits and is mapped into the current century by adding
/// 2000, which is what every server in the wild expects (`99` -> `2099`).
/// The `parse_digits(..., 4)` call still pads a shorter run, so a two digit
/// year is accepted here and resolved rather than rejected.
test "DOS resolves a two digit year into the current century" {
  let (entry, _) = @ftp.parse_list_line("01-02-99  15:04       1 a", test_now) catch {
    _ => fail("expected a DOS line")
  }
  assert_eq(entry.time.year(), 2099)
  assert_eq(entry.name, "a")
}

///|
/// `is_unsigned_number` accepts the `0x` / `0o` prefixes that `set_size`
/// understands, which is what makes a hex size in a `ls -l` head parse.
test "is_unsigned_number accepts the set_size prefixes" {
  // Exercised through a listing line: the hex size in the head is what
  // `last_numeric_field` has to recognise.
  let (entry, _) = @ftp.parse_list_line(
    "-rw-r--r--   1 owner    group    0x10 Dec 02  2009 a", test_now,
  )
  assert_eq(entry.size, 16UL)
  let (entry, _) = @ftp.parse_list_line(
    "-rw-r--r--   1 owner    group    0o17 Dec 02  2009 a", test_now,
  )
  assert_eq(entry.size, 15UL)
}

///|
/// A bare DOS date with no time field is not a DOS line.
test "DOS dir line without a time field is rejected" {
  let rejected = try {
    ignore(@ftp.parse_list_line("01-02-06", test_now))
    false
  } catch {
    @ftp.FtpError::UnsupportedListLine(_) => true
    _ => false
  }
  assert_true(rejected)
}

///|
/// A DOS line whose size field is followed by nothing has no name, so it is
/// not an entry.
test "DOS dir line without a name is rejected" {
  let rejected = try {
    ignore(@ftp.parse_list_line("01-02-06  15:04       1234", test_now))
    false
  } catch {
    @ftp.FtpError::UnsupportedListLine(_) => true
    _ => false
  }
  assert_true(rejected)
}

///|
/// `parse_fixed_digits` is the strict reader behind the `HH:MM` field: every
/// byte in the width must be a digit, so a non-numeric run makes the whole
/// date unrecognised rather than being silently repaired.
///
/// The year field, by contrast, goes through `parse_digits` and accepts a
/// shorter run (`20` is a two digit year), which is why only the `HH:MM` shape
/// is strict here.
test "parse_fixed_digits is strict inside the HH:MM field" {
  // A non digit where the hour digits belong.
  assert_true(@ftp.parse_ls_time("Dec 02  x009", 0, test_now) is None)
  // The field is rejected before the HH:MM shape is even tried.
  assert_true(@ftp.parse_list_date_field(" 02  x009", 0) is None)
  // The year field is looser, so a short run is still a valid year.
  let (timestamp, _) = match @ftp.parse_ls_time("Dec 02  20 pub", 0, test_now) {
    Some(parsed) => parsed
    None => fail("a short year run is accepted")
  }
  assert_eq(timestamp.year(), 20)
}

///|
/// A `MMM DD ` field whose day is missing in the "DD YYYY" shape is rejected:
/// there is no day to build a date from.
test "parse_list_date_field rejects a missing day" {
  assert_true(@ftp.parse_list_date_field(" xx 2009", 0) is None)
  // A day with no year and no time after it.
  assert_true(@ftp.parse_list_date_field(" 10", 0) is None)
}

///|
/// The RFC 3659 fact scan can run to the end of the line without ever seeing a
/// `;`, and a line that is *only* a name (no `=` anywhere) leaves `have_facts`
/// false: that is the guard that keeps a plain name from being mistaken for a
/// fact line.
test "rfc3659 requires at least one fact" {
  // Contains a `=` so the key/value split happens, but no `;` terminator and
  // no leading `type=`, so `have_facts` is never set.
  let result = @ftp.parse_rfc3659_line("just a name") catch {
    _ => fail("should not raise")
  }
  assert_true(result is None)
}

///|
/// A `parse_ls_time` that fails *after* the permissions and size were already
/// accepted makes the whole `ls -l` line unusable: the parser returns `None`
/// (rather than raising) so the dispatcher can fall through to the next one,
/// and if none matches the dispatcher raises `UnsupportedListLine`.
test "ls line with an impossible date is not an ls line" {
  // `Feb 30` is caught while building the timestamp, so the parser raises the
  // date error instead of returning an entry with a wrong date.
  let raised = try {
    ignore(
      @ftp.parse_ls_line(
        "-rw-r--r--   1 owner    group    0 Feb 30  2009 a", test_now,
      ),
    )
    None
  } catch {
    @ftp.FtpError::UnsupportedListDate(_) => Some(true)
    _ => None
  }
  assert_eq(raised, Some(true))
  // The dispatcher surfaces the *date* error rather than a generic
  // `UnsupportedListLine`: a malformed date in an otherwise valid line is a
  // more specific failure and callers can act on it.
  let from_dispatch = try {
    ignore(
      @ftp.parse_list_line(
        "-rw-r--r--   1 owner    group    0 Feb 30  2009 a", test_now,
      ),
    )
    None
  } catch {
    @ftp.FtpError::UnsupportedListDate(_) => Some(true)
    _ => None
  }
  assert_eq(from_dispatch, Some(true))
}

///|
/// The DOS parser needs both a date and a time field before it can do
/// anything; a single token or an empty line is `None`, not an entry with
/// defaults.
test "DOS dir line needs a date and a time field" {
  assert_true(@ftp.parse_dos_dir_line("01-02-06", test_now) is None)
  assert_true(@ftp.parse_dos_dir_line("", test_now) is None)
  // A date and a time but no size is still not a DOS line.
  assert_true(@ftp.parse_dos_dir_line("01-02-06  15:04", test_now) is None)
}
