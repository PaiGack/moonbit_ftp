// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

///|
/// An FTP control connection: a line buffered reader/writer pair over the
/// underlying socket, plus the debug hooks.
///
/// The reader and the writer are kept as trait objects so the same code drives
/// a plain `Tcp` socket and a `Tls` connection after `AUTH TLS`.
pub struct Control {
  mut reader : &@io.Reader
  mut writer : &@io.Writer
  /// Address of the peer we are talking to; the `PASV` SSRF guard trusts this
  /// one, not the address the server advertises.
  host : String
  /// Optional traffic log, wired by `dial` when `debug_log~` is set.
  debug : &@io.Writer?
}

///|
/// Wrap an already connected reader/writer pair.
pub fn Control::new(
  reader : &@io.Reader,
  writer : &@io.Writer,
  host : String,
  debug~ : &@io.Writer?,
) -> Control {
  { reader, writer, host, debug, }
}

///|
/// Wrap an already connected reader/writer pair without a traffic log.
pub fn Control::without_debug(
  reader : &@io.Reader,
  writer : &@io.Writer,
  host : String,
) -> Control {
  { reader, writer, host, debug: None, }
}

///|
/// The peer address of the control connection.
pub fn Control::host(self : Control) -> String {
  self.host
}

///|
/// Replace the underlying reader/writer, used when the connection is upgraded
/// to TLS after `AUTH TLS`.
pub fn Control::upgrade(
  self : Control,
  reader : &@io.Reader,
  writer : &@io.Writer,
) -> Unit {
  self.reader = reader
  self.writer = writer
}

///|
/// Write `line` followed by CRLF.
pub async fn Control::send_line(self : Control, line : String) -> Unit {
  match self.debug {
    Some(log) => log.write("@ S: \{line}\r\n")
    None => ()
  }
  self.writer.write(line + "\r\n")
}

///|
/// Read one line, without its trailing CRLF. Raises `ReaderClosed` when the
/// connection was closed before a complete line arrived.
pub async fn Control::read_line(self : Control) -> String {
  match self.reader.read_until("\r\n") {
    Some(line) => {
      match self.debug {
        Some(log) => log.write("@ R: \{line}\r\n")
        None => ()
      }
      line
    }
    None => raise @io.ReaderClosed
  }
}
