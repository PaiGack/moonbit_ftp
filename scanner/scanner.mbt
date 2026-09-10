// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

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
