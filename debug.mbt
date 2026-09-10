// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

///|
/// A reader decorator that mirrors everything it reads into a log writer.
///
/// Wiring is optional: when the caller does not ask for a traffic log the raw
/// connection is used directly and this decorator is never allocated, so the
/// debug support costs nothing in the default configuration.
pub struct TeeReader {
  inner : &@io.Reader
  log : &@io.Writer
}

///|
/// Wrap `inner` so every chunk is also written to `log`.
pub fn TeeReader::new(inner : &@io.Reader, log : &@io.Writer) -> TeeReader {
  { inner, log, }
}

///|
/// Read through to the wrapped reader, echoing the bytes read.
pub async fn TeeReader::read(
  self : TeeReader,
  dst : FixedArray[Byte],
  offset? : Int = 0,
  max_len? : Int = dst.length() - offset,
) -> Int {
  let n = self.inner.read(dst, offset~, max_len~)
  if n > 0 {
    self.log.write(dst.unsafe_reinterpret_as_bytes()[offset:offset + n])
  }
  n
}

///|
/// A writer decorator mirroring everything it writes into a log writer.
pub struct TeeWriter {
  inner : &@io.Writer
  log : &@io.Writer
}

///|
/// Wrap `inner` so every chunk is also written to `log`.
pub fn TeeWriter::new(inner : &@io.Writer, log : &@io.Writer) -> TeeWriter {
  { inner, log, }
}

///|
/// Write through to the wrapped writer, echoing the bytes written.
pub async fn TeeWriter::write(self : TeeWriter, data : &@io.Data) -> Unit {
  ignore(self.log.write(data))
  self.inner.write(data)
}
