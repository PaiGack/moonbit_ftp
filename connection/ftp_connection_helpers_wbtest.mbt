// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Package: `PaiGack/ftp/connection`.
//
// The white box fixtures that talk to `@connection.Control` and `@connection.DataConn` directly: a
// recording sink for the command encoding, a scripted control channel, and a
// loopback listener standing in for the server end of a data connection.
//
// `@connection.Control` is buildable from outside the package (`@connection.Control::new` takes a
// reader/writer pair), so these are ordinary builders, not white box tricks.
// The client-level fixtures (`scripted_client`) live in the root package.
//
// Every `@io.MemoryReader` here is built by the test that uses it and closed
// there: its producer runs in a background task that only `close` stops.

///|
/// A writer that decodes every byte to ASCII and records each CRLF-terminated
/// line, which is how the command encoding is asserted.
///
/// `write_once` receives a `BytesView`, whose `to_string` renders the debug
/// form (`b"NOOP\x0d\x0a"`), so the bytes are decoded one by one instead.
struct RecordingSink {
  lines : Array[String]
  mut pending : String
}

///|
/// An empty recording sink.
fn recording_sink() -> RecordingSink {
  { lines: [], pending: "", }
}

///|
impl @io.Writer for RecordingSink with fn write_once(
  self : RecordingSink,
  buf : Bytes,
  offset~ : Int32,
  len~ : Int32,
) -> Int32 {
  let mut decoded = ""
  for i = offset; i < offset + len; i = i + 1 {
    decoded = decoded + buf[i].to_int().unsafe_to_char().to_string()
  }
  self.pending = self.pending + decoded
  while true {
    let index = match self.pending.find("\r\n") {
      Some(index) => index
      None => break
    }
    self.lines.push(self.pending[0:index].to_owned())
    self.pending = self.pending[index + 2:].to_owned()
  }
  len
}

///|
/// A control channel over `reader` plus the sink recording what was sent, with
/// a traffic log installed.
///
/// The reader is taken as a parameter, not built here, on purpose: an
/// `@io.MemoryReader` owns a background producer task that only
/// `MemoryReader::close` stops, so whoever builds it must also close it (the
/// rule in AGENTS.md). This stays a plain builder; the tests close their own
/// reader.
fn logged_control(
  reader : &@io.Reader,
  log : &@io.Writer?,
) -> (@connection.Control, RecordingSink) raise @core.FtpError {
  let sink = recording_sink()
  let writer : &@io.Writer = sink
  let control = @connection.Control::new(reader, writer, "127.0.0.1")
  control.set_debug(
    match log {
      None => None
      Some(sink) => Some(@debug.DebugLog::new(sink))
    },
  )
  (control, sink)
}

///|
/// A control channel that answers with `script`, plus the sink recording what
/// was sent. The peer is `127.0.0.1`, the address the `PASV` SSRF guard
/// compares against.
fn scripted_control(
  script : String,
) -> (Control, RecordingSink) raise @core.FtpError {
  let reader = @io.MemoryReader(writer => writer.write(script))
  let reader_ref : &@io.Reader = reader
  logged_control(reader_ref, None)
}

///|
/// A `127.0.0.1` listener on an ephemeral port, used as the server end of a
/// data connection.
async fn data_listener() -> @socket.TcpServer {
  @socket.TcpServer::TcpServer(@socket.Addr::parse("127.0.0.1:0"))
}

///|
/// The `EPSV` reply that points a client at `port` on the loopback interface.
fn epsv_reply(port : Int32) -> String {
  "229 Entering Extended Passive Mode (|||" + port.to_string() + "|)\r\n"
}

///|
/// The `PASV` reply that points a client at `port` on `127.0.0.1`.
fn pasv_reply(port : Int32) -> String {
  let high = port / 256
  let low = port % 256
  "227 Entering Passive Mode (127,0,0,1," +
  high.to_string() +
  "," +
  low.to_string() +
  ")\r\n"
}
