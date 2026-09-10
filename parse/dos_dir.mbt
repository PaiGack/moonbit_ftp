// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

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
) -> @types.Entry? raise @error.FtpError {
  guard line != "" else { return None }
  let scanner = @scanner.Scanner::new(line)
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
  let entry = @types.make_entry("", @types.EntryType::File, time=timestamp)
  if size_field == "<DIR>" {
    entry.set_type(@types.EntryType::Folder)
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
) -> @time.ZonedDateTime? raise @error.FtpError {
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
) -> @time.ZonedDateTime raise @error.FtpError {
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
