// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

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
pub fn parse_rfc3659_line(line : String) -> @types.Entry? raise @error.FtpError {
  guard line != "" else { return None }
  let entry = @types.make_entry("", @types.EntryType::File)
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
          "file" => @types.EntryType::File
          "dir" | "cdir" | "pdir" => @types.EntryType::Folder
          "link" => @types.EntryType::Link
          _ => raise @error.FtpError::ParseError(msg="unknown entry type")
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
  guard digits.length() >= 14 else { return @types.epoch }
  let year = parse_fixed_digits(digits, 0, 4)
  let month = parse_fixed_digits(digits, 4, 2)
  let day = parse_fixed_digits(digits, 6, 2)
  let hour = parse_fixed_digits(digits, 8, 2)
  let minute = parse_fixed_digits(digits, 10, 2)
  let second = parse_fixed_digits(digits, 12, 2)
  match (year, month, day, hour, minute, second) {
    (Some(year), Some(month), Some(day), Some(hour), Some(minute), Some(second)) =>
      @time.ZonedDateTime::of(year, month, day, hour~, minute~, second~, zone~) catch {
        _ => @types.epoch
      }
    _ => @types.epoch
  }
}

///|
/// Merge the facts of a continuation line into the previous RFC 3659 entry.
/// Some servers answer `MLST` with the same entry spread over several lines;
/// upstream `parseNextRFC3659ListLine` requires the names to match.
pub fn parse_next_rfc3659_line(
  entry : @types.Entry,
  line : String,
) -> @types.Entry raise @error.FtpError {
  let next = parse_rfc3659_line(line)
  guard next is Some(next) else {
    raise @error.FtpError::UnsupportedListLine(line~)
  }
  guard next.name == entry.name else {
    raise @error.FtpError::UnsupportedListLine(line~)
  }
  next
}
