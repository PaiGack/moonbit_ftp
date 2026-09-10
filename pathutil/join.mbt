// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

///|
/// Join two remote path fragments the way Go's `path.Join` does: the result
/// is always cleaned (`.` dropped, `..` resolved, no empty segment, no
/// trailing slash), using `/` as separator. A leading `/` in the inputs is
/// significant only for the first non-empty segment, matching `path.Join`.
///
/// ```text
/// join("root/", "lo")   == "root/lo"
/// join("root", "a")     == "root/a"
/// join("root", "..")    == "."
/// join("", "a")         == "a"
/// ```
pub fn join(base : String, name : String) -> String {
  join_all([base, name])
}

///|
/// Whether the joined path should keep a leading slash, i.e. the first
/// non-empty part started with `/`.
fn starts_absolute(parts : Array[String]) -> Bool {
  for part in parts {
    guard part != "" else { continue }
    return part.has_prefix("/")
  }
  false
}

///|
/// Variadic form of `join`, equivalent to `path.Join(parts...)`.
pub fn join_all(parts : Array[String]) -> String {
  let segments : Array[String] = []
  for i = 0; i < parts.length(); i = i + 1 {
    for segment in split_slashes(parts[i]) {
      match segment {
        "" | "." => ()
        ".." =>
          // `..` pops the previous real segment, or is kept when the result
          // would escape the root — same rule as Go's path.Clean.
          if segments.length() > 0 && segments[segments.length() - 1] != ".." {
            ignore(segments.pop())
          } else {
            segments.push("..")
          }
        _ => segments.push(segment)
      }
    }
  }
  let joined = match segments {
    [] => "."
    _ => segments.join("/")
  }
  if joined != "." && starts_absolute(parts) {
    "/" + joined
  } else {
    joined
  }
}

///|
/// Split on `/` keeping empty segments, so that `a//b` collapses correctly
/// inside `join_all` (empty segments are simply skipped there).
fn split_slashes(src : String) -> Array[String] {
  let parts : Array[String] = []
  let current = StringBuilder()
  for ch in src {
    if ch == '/' {
      parts.push(current.to_string())
      current.reset()
    } else {
      current.write_char(ch)
    }
  }
  parts.push(current.to_string())
  parts
}
