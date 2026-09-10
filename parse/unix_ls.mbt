// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

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
) -> @types.Entry? raise @error.FtpError {
  guard line.length() >= 10 else { return None }
  let perms = line[0:10].to_owned()
  let type_ = match perms[0] {
    'd' => @types.EntryType::Folder
    '-' | 'f' => @types.EntryType::File
    'l' => @types.EntryType::Link
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
  let entry = @types.make_entry("", type_, time=now)
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
  let scanner = @scanner.Scanner::new(head)
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
