// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

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
) -> @types.Entry? raise @error.FtpError {
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
