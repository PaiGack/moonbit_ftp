// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: pure logic — no IO, no `moonbitlang/async` dependency.

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
