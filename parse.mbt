// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: pure logic — no IO, no `moonbitlang/async` dependency.

// LIST / MLSD line parsers and their shared helpers.
//
// This file merges `parse`, `parse_time` and `scanner`: the whitespace field
// scanner exists only to feed the parsers, and the time-field parser is only
// called from the LIST/MLSD/UNIX paths below. Splitting them meant three files
// that were never read apart, while the fallback chain that ties them together
// was spread across all three.

// The `LIST` / `MLSD` line parsers.
//
// This file merges `parse` (the dispatcher and the shared numeric helpers),
// `parse_rfc3659`, `parse_unix_ls`, `parse_dos_dir` and `parse_hostedftp`.
// They are one unit: `parse_list_line` below is a fixed fallback chain over
// exactly those four formats, and every parser is unreachable except through
// it. Splitting them meant a reader had to open five files to follow one line
// of a directory listing.
//
// The fallback order is load bearing and documented in
// `docs/porting/02-upstream-map.md`; changing it changes which parser wins for
// an ambiguous line.

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
) -> (Entry, ListFormat) raise FtpError {
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
  raise FtpError::UnsupportedListLine(line~)
}

///|
/// Parse a numeric size field the way Go's `strconv.ParseUint(s, 0, 64)` does:
/// an explicit `0x` / `0X` prefix means hex, `0o` / `0O` means octal,
/// a leading `0` means octal, and anything else is decimal.
pub fn set_size(raw : String) -> UInt64 raise FtpError {
  let text = raw.trim().to_owned()
  guard text != "" else { raise FtpError::ParseError(msg="empty size field") }
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
    _ => raise FtpError::ParseError(msg="invalid size field: \{raw}")
  }
}

///|
/// Parse an unsigned 64 bit integer in the given radix, rejecting empty input
/// and overflowing values.
pub fn parse_uint(digits : String, radix : Int) -> UInt64 raise FtpError {
  guard digits != "" else { raise FtpError::ParseError(msg="empty number") }
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
      raise FtpError::ParseError(msg="invalid digit")
    }
    guard digit < radix else { raise FtpError::ParseError(msg="invalid digit") }
    value = value * radix.to_uint64() + digit.to_uint64()
  }
  value
}

///|
/// Parse a single RFC 3659 (`MLSD` / `MLST`) fact line:
///
/// ```text
/// type=file;size=951;modify=20140101000000; welcome.msg
/// ```
///
/// Faithful port of upstream `parseRFC3659ListLine`:
///
/// - the facts are separated by `;`, the last one is followed by the name,
/// - fact keys are matched case-insensitively (`Type=` works as well, which is
///   what WFTPD/Serv-U emit),
/// - `sizd` is accepted as a typo for `size`,
/// - an unrecognised `type=` value is an error, not a fallback,
/// - a line whose last fact is not terminated by `;` is not an RFC 3659 line.
pub fn parse_rfc3659_line(line : String) -> Entry? raise FtpError {
  guard line != "" else { return None }
  let entry = make_entry("", EntryType::File)
  let len = line.length()
  let mut i = 0
  let mut have_facts = false
  while i < len {
    let field_start = i
    // Scan to the next `;`, remembering where the first `=` was.
    let mut eq = -1
    while i < len && line.unsafe_get(i).to_int() != 59 {
      if line.unsafe_get(i).to_int() == 61 && eq < 0 {
        eq = i
      }
      i += 1
    }
    if i >= len {
      // Trailing content without a `;` terminator: the whole line is the
      // "facts" only if everything was consumed; otherwise this is not an
      // RFC 3659 line at all.
      if have_facts == false {
        return None
      }
      break
    }
    let key = line[field_start:if eq >= 0 { eq } else { i }].to_owned()
    let value = if eq >= 0 { line[eq + 1:i].to_owned() } else { "" }
    match key.trim().to_lower() {
      "" => ()
      "type" => {
        let kind = match value.to_lower() {
          "file" => EntryType::File
          "dir" | "cdir" | "pdir" => EntryType::Folder
          "link" => EntryType::Link
          _ => raise FtpError::ParseError(msg="unknown entry type")
        }
        entry.set_type(kind)
      }
      "size" | "sizd" => entry.set_size(set_size(value))
      "modify" =>
        entry.set_time(parse_rfc3659_datetime(value, entry.time.zone()))
      _ => ()
    }
    have_facts = true
    // Consume the separator itself.
    i += 1
    // Everything after the `; ` is the name; stop scanning facts.
    if i < len && line.unsafe_get(i).to_int() == 32 {
      i += 1
      break
    }
  }
  guard have_facts else { return None }
  entry.set_name(line[i:].to_owned())
  Some(entry)
}

///|
/// Parse a `YYYYMMDDHHMMSS` timestamp as used by RFC 3659 `modify=` facts.
/// Falls back to the value already stored in the entry when the shape does not
/// match, which keeps `MLST` output without a `modify` fact usable.
fn parse_rfc3659_datetime(
  value : String,
  zone : @time.Zone,
) -> @time.ZonedDateTime {
  let digits = value.trim().to_owned()
  guard digits.length() >= 14 else { return epoch }
  let year = parse_fixed_digits(digits, 0, 4)
  let month = parse_fixed_digits(digits, 4, 2)
  let day = parse_fixed_digits(digits, 6, 2)
  let hour = parse_fixed_digits(digits, 8, 2)
  let minute = parse_fixed_digits(digits, 10, 2)
  let second = parse_fixed_digits(digits, 12, 2)
  match (year, month, day, hour, minute, second) {
    (Some(year), Some(month), Some(day), Some(hour), Some(minute), Some(second)) =>
      @time.ZonedDateTime::of(year, month, day, hour~, minute~, second~, zone~) catch {
        _ => epoch
      }
    _ => epoch
  }
}

///|
/// Merge the facts of a continuation line into the previous RFC 3659 entry.
/// Some servers answer `MLST` with the same entry spread over several lines;
/// upstream `parseNextRFC3659ListLine` requires the names to match.
pub fn parse_next_rfc3659_line(
  entry : Entry,
  line : String,
) -> Entry raise FtpError {
  let next = parse_rfc3659_line(line)
  guard next is Some(next) else { raise FtpError::UnsupportedListLine(line~) }
  guard next.name == entry.name else {
    raise FtpError::UnsupportedListLine(line~)
  }
  next
}

///|
/// Parse a Unix `ls -l` style line:
///
/// ```text
/// drwxr-xr-x    3 110      1002            3 Dec 02  2009 pub
/// -rw-r--r--   1 marketwired marketwired    12016 Mar 16  2016 newsml
/// drwxr-xr-x               folder        0 Aug 15 05:49 !!!-Tipp des Haus!
/// ```
///
/// Port of upstream `parseLsListLine`:
///
/// - the permission field is 10 bytes, or 11 with an ACL `+` marker,
/// - the type comes from the first character,
/// - the size is the **last** numeric field before the date, which is what
///   makes the `ls -l` and the "no link count" variants both parse,
/// - the date is found by scanning for `MMM DD `, so extra columns do not
///   shift the parse,
/// - the name is the entire remainder, so spaces inside names survive,
/// - a symlink's ` -> ` is split into name and target.
pub fn parse_ls_line(
  line : String,
  now : @time.ZonedDateTime,
) -> Entry? raise FtpError {
  guard line.length() >= 10 else { return None }
  let perms = line[0:10].to_owned()
  let type_ = match perms[0] {
    'd' => EntryType::Folder
    '-' | 'f' => EntryType::File
    'l' => EntryType::Link
    _ => return None
  }
  // An 11th byte is only allowed as the ACL `+` marker or a separator.
  if line.length() > 10 {
    let marker = line.unsafe_get(10).to_int()
    if marker != 43 && marker != 32 && marker != 9 {
      return None
    }
  }
  for i = 1; i < 10; i = i + 1 {
    let c = perms.unsafe_get(i).to_int()
    let ok = c == 114 || // r
      c == 119 || // w
      c == 120 || // x
      c == 115 || // s
      c == 116 || // t
      c == 83 ||
      c == 84 ||
      c == 45 // -
    if ok == false {
      return None
    }
  }
  // The date field is the anchor: everything before it holds the link count,
  // owner, group and size; everything after it is the name.
  let date_start = match find_date_start(line, 10) {
    Some(index) => index
    None => return None
  }
  let head = line[10:date_start].to_owned()
  let size = match last_numeric_field(head) {
    Some(value) => value
    None => return None
  }
  let entry = make_entry("", type_, time=now)
  entry.set_size(size)
  let date_and_name = line[date_start:].to_owned()
  let parsed = parse_ls_time(date_and_name, 0, now)
  guard parsed is Some((timestamp, date_end)) else { return None }
  entry.set_time(timestamp)
  let raw_name = date_and_name[date_end:].to_owned()
  let name = strip_leading_spaces(raw_name)
  guard name != "" else { return None }
  match split_link(name) {
    Some((name, target)) => {
      entry.set_name(name)
      entry.set_target(target)
    }
    None => entry.set_name(name)
  }
  Some(entry)
}

///|
/// Index of the first `MMM DD ` date field at or after `start`.
pub fn find_date_start_pub(line : String, start : Int) -> Int? {
  find_date_start(line, start)
}

///|
fn find_date_start(line : String, start : Int) -> Int? {
  let mut i = start
  while i + 7 <= line.length() {
    if parse_month(line[i:i + 3].to_owned()) is Some(_) &&
      line.unsafe_get(i + 3).to_int() == 32 &&
      is_digit_at(line, i + 4) {
      return Some(i)
    }
    i += 1
  }
  None
}

///|
/// The last whitespace separated field before the date that looks like a size:
/// a plain number, a `0x` / `0o` prefixed number, or the `folder` marker that
/// some servers emit in place of a size.
fn last_numeric_field(head : String) -> UInt64? {
  let scanner = Scanner::new(head)
  let mut found : UInt64? = None
  while true {
    let field = scanner.next()
    if field == "" {
      break
    }
    if field == "folder" {
      found = Some(0UL)
    } else if is_unsigned_number(field) {
      found = Some(set_size(field) catch { _ => 0UL })
    }
  }
  found
}

///|
/// Whether `value` looks like a number accepted by `set_size`.
fn is_unsigned_number(value : String) -> Bool {
  guard value != "" else { return false }
  let mut start = 0
  if value.length() > 2 && (value[0:2] == "0x" || value[0:2] == "0o") {
    start = 2
  }
  guard start < value.length() else { return false }
  for i = start; i < value.length(); i = i + 1 {
    let c = value.unsafe_get(i).to_int()
    if c < 48 || c > 57 {
      return false
    }
  }
  true
}

///|
/// Whether `src[i]` is an ASCII digit.
fn is_digit_at(src : String, i : Int) -> Bool {
  guard i < src.length() else { return false }
  let code = src.unsafe_get(i).to_int()
  code >= 48 && code <= 57
}

///|
/// Offset of the first non-space byte at or after `start`.
fn leading_field_offset(src : String, start : Int) -> Int {
  let mut i = start
  while i < src.length() && src.unsafe_get(i).to_int() == 32 {
    i += 1
  }
  i
}

///|
/// Drop leading spaces from `src`.
fn strip_leading_spaces(src : String) -> String {
  src[leading_field_offset(src, 0):].to_owned()
}

///|
/// Split `name -> target` on the **first** ` -> ` occurrence, as upstream does
/// with `strings.SplitN(..., " -> ", 2)`.
fn split_link(name : String) -> (String, String)? {
  let marker = " -> "
  let mut i = 0
  while i + marker.length() <= name.length() {
    if name[i:i + marker.length()] == marker {
      return Some((name[0:i].to_owned(), name[i + marker.length():].to_owned()))
    }
    i += 1
  }
  None
}

///|
/// Parse a MS-DOS / Windows `DIR` style line:
///
/// ```text
/// 07-27-17  04:50PM              1264086 File.txt
/// 11-06-16  09:31AM       <DIR>          Softlib
/// ```
///
/// Faithful port of upstream `parseDirListLine`:
///
/// - the first field is the date and is tried against four layouts
///   (`01-02-06  03:04PM` with one or two digit month/day/year, and the
///   `01-02-06  15:04` 24 hour variant),
/// - `<DIR>` switches the type to folder and the size to 0,
/// - anything else must be a plain decimal size.
pub fn parse_dos_dir_line(
  line : String,
  now : @time.ZonedDateTime,
) -> Entry? raise FtpError {
  guard line != "" else { return None }
  let scanner = Scanner::new(line)
  let date_field = scanner.next()
  guard date_field != "" else { return None }
  let time_field = scanner.next()
  guard time_field != "" else { return None }
  let parsed = parse_dos_date(date_field, time_field, now)
  guard parsed is Some(timestamp) else { return None }
  let size_field = scanner.next()
  guard size_field != "" else { return None }
  let rest = strip_leading_spaces(scanner.remaining())
  guard rest != "" else { return None }
  let entry = make_entry("", EntryType::File, time=timestamp)
  if size_field == "<DIR>" {
    entry.set_type(EntryType::Folder)
    entry.set_size(0)
  } else {
    guard is_unsigned_number(size_field) else { return None }
    entry.set_size(set_size(size_field))
  }
  entry.set_name(rest)
  Some(entry)
}

///|
/// Try the four DOS date/time layouts upstream accepts. Returns `None` when
/// none of them matches, which lets `parse_list_line` fall through to the
/// hostedftp parser (or to `UnsupportedListLine`).
fn parse_dos_date(
  date_field : String,
  time_field : String,
  now : @time.ZonedDateTime,
) -> @time.ZonedDateTime? raise FtpError {
  // Layout A: "01-02-06  03:04PM"
  match parse_dos_parts(date_field, time_field, true) {
    Some((month, day, year, hour, minute)) =>
      return Some(resolve_dos_year(month, day, year, hour, minute, now))
    None => ()
  }
  match parse_dos_parts(date_field, time_field, false) {
    Some((month, day, year, hour, minute)) =>
      return Some(resolve_dos_year(month, day, year, hour, minute, now))
    None => ()
  }
  None
}

///|
/// DOS dates carry a two digit year. Upstream maps them into the current
/// century by adding 2000, which is what every server in the wild does.
fn resolve_dos_year(
  month : Int,
  day : Int,
  year : Int,
  hour : Int,
  minute : Int,
  now : @time.ZonedDateTime,
) -> @time.ZonedDateTime raise FtpError {
  let full_year = if year < 100 { year + 2000 } else { year }
  new_datetime(full_year, month, day, hour, minute, now.zone())
}

///|
/// Split `MM-DD-YY` and `HH:MM[AP]M` into numbers. When `require_ampm` is set
/// the time field must carry the `AM`/`PM` suffix (which is then applied).
fn parse_dos_parts(
  date_field : String,
  time_field : String,
  require_ampm : Bool,
) -> (Int, Int, Int, Int, Int)? {
  let mut i = 0
  let month = parse_digits(date_field, i, 2)
  guard month is Some((month, next)) else { return None }
  guard next < date_field.length() && date_field.unsafe_get(next).to_int() == 45 else {
    return None
  }
  i = next + 1
  let day = parse_digits(date_field, i, 2)
  guard day is Some((day, next)) else { return None }
  guard next < date_field.length() && date_field.unsafe_get(next).to_int() == 45 else {
    return None
  }
  i = next + 1
  let year = parse_digits(date_field, i, 4)
  guard year is Some((year, next)) else { return None }
  guard next == date_field.length() else { return None }
  let hour = parse_digits(time_field, 0, 2)
  guard hour is Some((hour, next)) else { return None }
  guard next < time_field.length() && time_field.unsafe_get(next).to_int() == 58 else {
    return None
  }
  let minute = parse_digits(time_field, next + 1, 2)
  guard minute is Some((minute, next)) else { return None }
  let suffix = time_field[next:].to_owned().trim().to_upper()
  let hour = if suffix == "PM" {
    if hour == 12 {
      12
    } else {
      hour + 12
    }
  } else if suffix == "AM" {
    if hour == 12 {
      0
    } else {
      hour
    }
  } else if require_ampm || suffix != "" {
    return None
  } else {
    hour
  }
  guard month >= 1 && month <= 12 && day >= 1 && day <= 31 else { return None }
  Some((month, day, year, hour, minute))
}

///|
/// Parse a hostedftp.com style line, which is `ls -l` without the link count:
///
/// ```text
/// drwxr-xr-x               folder        0 Aug 15 05:49 !!!-Tipp des Haus!
/// ```
///
/// Upstream `parseHostedFTPLine` rewrites the first field by appending a
/// space and the literal link count `0`, then delegates to the Unix `ls`
/// parser. Keeping that trick means the two parsers stay in sync.
pub fn parse_hostedftp_line(
  line : String,
  now : @time.ZonedDateTime,
) -> Entry? raise FtpError {
  guard line.length() >= 10 else { return None }
  // The first field must be a valid permission string; otherwise this is not
  // a hostedftp line and we let the caller fall through.
  guard is_permission_field(line, 0) else { return None }
  let patched = line[0:10].to_owned() + " 0 " + line[10:].to_owned()
  parse_ls_line(patched, now)
}

///|
/// Whether the 10 (or 11, with an ACL `+`) bytes at `start` are a plausible
/// permission field.
fn is_permission_field(src : String, start : Int) -> Bool {
  guard start + 10 <= src.length() else { return false }
  let first = src.unsafe_get(start).to_int()
  guard first == 100 || first == 45 || first == 108 else { return false }
  guard start + 11 <= src.length() else { return true }
  let marker = src.unsafe_get(start + 10).to_int()
  marker == 43 || marker == 32
}

///|
/// The English month abbreviations accepted in `LIST` output, in calendar
/// order (`Jan` == 1).
pub let month_names : Array[String] = [
  "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
]

///|
/// Parse a three letter month name case-insensitively, returning 1..12.
pub fn parse_month(name : String) -> Int? {
  let lower = name.to_lower()
  for i = 0; i < month_names.length(); i = i + 1 {
    if month_names[i] == lower {
      return Some(i + 1)
    }
  }
  None
}

///|
/// Parse a strictly fixed-width decimal field. `width` is the expected number
/// of digits; anything shorter is padded from the left, anything longer makes
/// the whole date unrecognised.
fn parse_fixed_digits(src : String, start : Int, width : Int) -> Int? {
  guard start >= 0 && start + width <= src.length() else { return None }
  let mut value = 0
  for i = start; i < start + width; i = i + 1 {
    let code = src.unsafe_get(i).to_int()
    guard code >= 48 && code <= 57 else { return None }
    value = value * 10 + (code - 48)
  }
  Some(value)
}

///|
/// Parse a decimal field of 1..`max_width` digits starting at `start`,
/// returning the value and the position right after the last digit.
fn parse_digits(src : String, start : Int, max_width : Int) -> (Int, Int)? {
  let mut i = start
  let mut value = 0
  let mut digits = 0
  while i < src.length() && digits < max_width {
    let code = src.unsafe_get(i).to_int()
    if code < 48 || code > 57 {
      break
    }
    value = value * 10 + (code - 48)
    digits += 1
    i += 1
  }
  if digits == 0 {
    None
  } else {
    Some((value, i))
  }
}

///|
/// Interpret the `MMM DD HH:MM` / `MMM DD YYYY` time field of a `LIST` line.
///
/// This is upstream's `setTime` including the **six month rule** from
/// `info ls` 10.1.6:
///
/// - when the field contains `:` there is no year, so the current year is
///   assumed; if the resulting instant is not before `now + 6 months`, the
///   year is decremented,
/// - when the field has no `:` the year must be exactly four digits, a
///   malformed year is an error (not a fallback),
/// - a missing time (`HH:MM`) defaults to midnight.
pub fn apply_list_time(
  entry : Entry,
  year : Int,
  month : Int,
  day : Int,
  has_time : Bool,
  hour : Int,
  minute : Int,
  now : @time.ZonedDateTime,
) -> Unit raise FtpError {
  guard month >= 1 && month <= 12 else {
    raise FtpError::UnsupportedListDate(field="\{month}")
  }
  let mut resolved_year = year
  if has_time == false && year < 1000 {
    // Missing year, e.g. the "MMM DD HH:MM" form is handled below; a numeric
    // year field must be exactly 4 digits.
    raise FtpError::UnsupportedListDate(field="\{year}")
  }
  if has_time {
    // No year in the field: assume the current year, then apply the half-year
    // rule. The whole comparison is done on the wall-clock fields of `now`
    // and the candidate, which is what upstream does.
    let candidate = new_datetime(
      resolved_year,
      month,
      day,
      hour,
      minute,
      now.zone(),
    )
    // Half-year rule: a candidate that is not earlier than `now` plus six
    // months must belong to the previous year. The boundary is exact to the
    // minute, hence `>=`, not `>`.
    let now_plus_six_months = now.add_months(6) catch {
      _ => raise FtpError::UnsupportedListDate(field="\{month}/\{day}")
    }
    if candidate.to_unix_second() >= now_plus_six_months.to_unix_second() {
      resolved_year -= 1
    }
  }
  guard day >= 1 &&
    day <= 31 &&
    hour >= 0 &&
    hour <= 23 &&
    minute >= 0 &&
    minute <= 59 else {
    raise FtpError::UnsupportedListDate(field="\{day} \{hour}:\{minute}")
  }
  let timestamp = new_datetime(
    resolved_year,
    month,
    day,
    hour,
    minute,
    now.zone(),
  )
  entry.set_time(timestamp)
}

///|
/// Build a `ZonedDateTime` in `zone`, raising `UnsupportedListDate` when the
/// calendar fields are not a valid date (e.g. Feb 30).
pub fn new_datetime(
  year : Int,
  month : Int,
  day : Int,
  hour : Int,
  minute : Int,
  zone : @time.Zone,
) -> @time.ZonedDateTime raise FtpError {
  @time.ZonedDateTime::of(year, month, day, hour~, minute~, second=0, zone~) catch {
    _ => raise FtpError::UnsupportedListDate(field="\{year}-\{month}-\{day}")
  }
}

///|
/// Parse the two year-dependent shapes used by the `LIST` time field, given
/// the `MMM DD ` prefix has already been consumed.
///
/// Returns `(year, month, day, has_time, hour, minute, next_index)`. `year` is
/// `0` when the field carried no year at all (the `HH:MM` shape), the caller
/// substitutes the current year.
pub fn parse_list_date_field(src : String, start : Int) -> ListDateField? {
  // The month name is followed by one or more spaces before the day.
  let day_start = skip_spaces(src, start)
  let first = parse_digits(src, day_start, 2)
  guard first is Some((day, after_day)) else { return None }
  let i = skip_spaces(src, after_day)
  guard i < src.length() else { return None }
  // Shape "DD HH:MM": no year at all.
  if is_digit(src, i) {
    match parse_hh_mm(src, i) {
      Some((hour, minute, next)) =>
        return Some({ year: 0, day, has_time: true, hour, minute, next, })
      None => ()
    }
  }
  // Shape "DD YYYY".
  let year = parse_digits(src, i, 4)
  guard year is Some((y, after_year)) else { return None }
  Some({ year: y, day, has_time: false, hour: 0, minute: 0, next: after_year, })
}

///|
/// The pieces of a `LIST` date field: `MMM` is consumed by the caller.
struct ListDateField {
  /// The year, or `0` when the field carried none.
  year : Int
  /// Day of month.
  day : Int
  /// Whether the field used the `HH:MM` shape (and therefore has no year).
  has_time : Bool
  /// Hour, `0` when absent.
  hour : Int
  /// Minute, `0` when absent.
  minute : Int
  /// Index right after the field.
  next : Int
}

///|
/// The year of a parsed date field, `0` when the field carried none.
pub fn ListDateField::year(self : ListDateField) -> Int {
  self.year
}

///|
/// The day of month of a parsed date field.
pub fn ListDateField::day(self : ListDateField) -> Int {
  self.day
}

///|
/// Whether the field used the yearless `HH:MM` shape.
pub fn ListDateField::has_time(self : ListDateField) -> Bool {
  self.has_time
}

///|
/// The hour, `0` when the field carried none.
pub fn ListDateField::hour(self : ListDateField) -> Int {
  self.hour
}

///|
/// The minute, `0` when the field carried none.
pub fn ListDateField::minute(self : ListDateField) -> Int {
  self.minute
}

///|
/// The index right after the parsed date field.
pub fn ListDateField::next(self : ListDateField) -> Int {
  self.next
}

///|
/// Offset of the first non-space byte at or after `start`.
fn skip_spaces(src : String, start : Int) -> Int {
  let mut i = start
  while i < src.length() && src.unsafe_get(i).to_int() == 32 {
    i += 1
  }
  i
}

///|
/// Whether `src[i]` is an ASCII digit.
fn is_digit(src : String, i : Int) -> Bool {
  guard i < src.length() else { return false }
  let code = src.unsafe_get(i).to_int()
  code >= 48 && code <= 57
}

///|
/// Parse a strict `HH:MM` field. Returns `None` when the field is not exactly
/// two digits, colon, two digits.
fn parse_hh_mm(src : String, start : Int) -> (Int, Int, Int)? {
  guard start + 5 <= src.length() else { return None }
  let hour = parse_fixed_digits(src, start, 2)
  guard hour is Some(hour) else { return None }
  guard src.unsafe_get(start + 2).to_int() == 58 else { return None }
  let minute = parse_fixed_digits(src, start + 3, 2)
  guard minute is Some(minute) else { return None }
  Some((hour, minute, start + 5))
}

///|
/// Parse an `ls -l` time field: `MMM DD HH:MM` or `MMM DD  YYYY`.
///
/// Returns the resolved time and the index right after the field.
pub fn parse_ls_time(
  src : String,
  start : Int,
  now : @time.ZonedDateTime,
) -> (@time.ZonedDateTime, Int)? raise FtpError {
  guard start + 3 <= src.length() else { return None }
  let month = parse_month(src[start:start + 3].to_owned())
  guard month is Some(month) else { return None }
  let parsed = parse_list_date_field(src, start + 3)
  guard parsed is Some(field) else { return None }
  let resolved_year = if field.has_time {
    probe_year(month, field.day, field.hour, field.minute, now)
  } else {
    field.year
  }
  let timestamp = new_datetime(
    resolved_year,
    month,
    field.day,
    field.hour,
    field.minute,
    now.zone(),
  )
  Some((timestamp, field.next))
}

///|
/// Apply the six month rule and return the year to use for a yearless
/// `MMM DD HH:MM` field.
fn probe_year(
  month : Int,
  day : Int,
  hour : Int,
  minute : Int,
  now : @time.ZonedDateTime,
) -> Int {
  let candidate = @time.ZonedDateTime::of(
    now.year(),
    month,
    day,
    hour~,
    minute~,
    second=0,
    zone=now.zone(),
  ) catch {
    _ => return now.year()
  }
  let now_plus_six_months = now.add_months(6) catch { _ => return now.year() }
  // The candidate is "in the future beyond the six month window" when it is
  // not earlier than now + 6 months; such a timestamp must be from last year.
  if candidate.to_unix_second() >= now_plus_six_months.to_unix_second() {
    now.year() - 1
  } else {
    now.year()
  }
}

///|
/// A whitespace separated field scanner, a faithful port of upstream
/// `scanner.go`.
///
/// The position semantics are *not* intuitive and upstream has a dedicated
/// test for them, so they are spelled out here:
///
/// ```text
/// new Scanner("foo  bar x  y")
///   .next()      -> "foo", position stops *after* the run of spaces
///   .remaining() -> " bar x  y"   // the leading space is kept
///   .next()      -> "bar"
///   .remaining() -> "x  y"
/// ```
///
/// In other words `next()` consumes the field **and exactly one following
/// space**. Everything after that stays in `remaining()`.
pub struct Scanner {
  src : String
  /// Byte offset of the next character to read.
  mut offset : Int
}

///|
/// Create a scanner over `src`.
pub fn Scanner::new(src : String) -> Scanner {
  { src, offset: 0, }
}

///|
/// Whether all input has been consumed.
pub fn Scanner::at_end(self : Scanner) -> Bool {
  self.offset >= self.src.length()
}

///|
/// The not-yet-consumed tail of the input.
pub fn Scanner::remaining(self : Scanner) -> String {
  guard self.offset <= self.src.length() else { return "" }
  self.src[self.offset:].to_owned()
}

///|
/// Consume and return the next whitespace separated field.
///
/// Returns `""` at end of input. As in upstream, an empty field is only
/// produced at the end — runs of spaces never yield empty fields.
pub fn Scanner::next(self : Scanner) -> String {
  let len = self.src.length()
  // Skip the separator left over from the previous call.
  while self.offset < len &&
        is_space_byte(self.src.unsafe_get(self.offset).to_int()) {
    self.offset += 1
  }
  guard self.offset < len else { return "" }
  let start = self.offset
  while self.offset < len &&
        is_space_byte(self.src.unsafe_get(self.offset).to_int()) == false {
    self.offset += 1
  }
  let field = self.src[start:self.offset].to_owned()
  // Consume exactly one trailing space, as upstream does.
  if self.offset < len &&
    is_space_byte(self.src.unsafe_get(self.offset).to_int()) {
    self.offset += 1
  }
  field
}

///|
/// Read up to `count` consecutive fields. Stops early (without raising) when
/// the input is exhausted, exactly like upstream `nextFields`.
pub fn Scanner::next_fields(self : Scanner, count : Int) -> Array[String] {
  let fields : Array[String] = []
  for i = 0; i < count; i = i + 1 {
    let field = self.next()
    if field == "" {
      break
    }
    fields.push(field)
  }
  fields
}

///|
/// Whether `byte` is one of the ASCII whitespace characters used by FTP
/// directory listings (` `, `\t`, `\r`, `\n`).
fn is_space_byte(byte : Int) -> Bool {
  byte == 32 || byte == 9 || byte == 13 || byte == 10
}
