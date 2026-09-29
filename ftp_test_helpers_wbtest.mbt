// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
//
// Shared white box fixture for the `list` / `transfer` / `walker` / `commands`
// tests.
//
// Those four files are command wrappers, so the interesting cases are the
// command string they put on the wire, the status code they insist on and the
// payload they turn into entries. All of it is reachable in process:
//
// - an in-memory `Control` supplies the scripted replies, and a `RecordingSink`
//   captures the commands that were actually sent, so the encoding is asserted
//   byte for byte;
// - a real `TcpServer` bound to `127.0.0.1:0` supplies the data connection, so
//   `cmd_data_conn_from` (EPSV/PASV negotiation, `125`/`150` validation) runs
//   for real against a socket instead of a mock FTP daemon.
//
// `FTPClient` is read-only outside the package, so building one around a
// scripted `Control` needs the white box scope. That is the only privilege
// these tests use; nothing here writes a real server's state.

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
  offset~ : Int,
  len~ : Int,
) -> Int {
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
/// A control channel that answers with `script`, plus the sink recording what
/// was sent. The peer is `127.0.0.1`, the address the `PASV` SSRF guard
/// compares against.
fn scripted_control(script : String) -> (Control, RecordingSink) {
  let reader : &@io.Reader = @io.MemoryReader(writer => writer.write(script))
  let sink = recording_sink()
  let writer : &@io.Writer = sink
  (Control::new(reader, writer, "127.0.0.1"), sink)
}

///|
/// Build a client around a scripted control channel and explicit capability
/// flags, so `list` picks `MLSD` or `LIST` deterministically.
fn scripted_client(
  script : String,
  mlst_supported? : Bool = false,
  options? : Options = Options::default(),
  location? : @time.Zone = @time.utc_zone,
  dial_options? : DialOptions = DialOptions::default(),
) -> (FTPClient, RecordingSink) {
  let (control, sink) = scripted_control(script)
  let client : FTPClient = {
    options: dial_options,
    state_options: options,
    session: Session::new(control, options~),
    closed: false,
    host: "127.0.0.1:21",
    mutex: @async.Mutex::Mutex(),
    mlst_supported,
    mfmt_supported: false,
    mdtm_supported: false,
    mdtm_can_write: false,
    location,
    features: {},
  }
  (client, sink)
}

///|
/// A `127.0.0.1` listener on an ephemeral port, used as the server end of a
/// data connection.
async fn data_listener() -> @socket.TcpServer {
  @socket.TcpServer::TcpServer(@socket.Addr::parse("127.0.0.1:0"))
}

///|
/// Accept exactly one data connection, write `payload` and close it.
///
/// One call per data connection the client will open, in whatever order the
/// client opens them — so the calls belong in separate task-group tasks when a
/// test needs more than one.
async fn serve_payload(listener : @socket.TcpServer, payload : String) -> Unit {
  let (conn, _) = listener.accept()
  conn.write(payload)
  conn.close()
}

///|
/// The `EPSV` reply that points a client at `port` on the loopback interface.
fn epsv_reply(port : Int) -> String {
  "229 Entering Extended Passive Mode (|||" + port.to_string() + "|)\r\n"
}

///|
/// The `PASV` reply that points a client at `port` on `127.0.0.1`.
fn pasv_reply(port : Int) -> String {
  let high = port / 256
  let low = port % 256
  "227 Entering Passive Mode (127,0,0,1," +
  high.to_string() +
  "," +
  low.to_string() +
  ")\r\n"
}

///|
/// An in-memory reader over `text`, for feeding an upload.
///
/// `@io.MemoryReader` runs its producer in a background task, so a source that
/// is never drained leaves that task parked and `moon test` reports a deadlock.
/// Tests that deliberately abort a transfer before the payload is read must
/// call `text_source(text).close()` (a `MemoryReader` cancels its producer) or
/// use `failing_source()`.
fn text_source(text : String) -> @io.MemoryReader {
  @io.MemoryReader(writer => writer.write(text))
}

///|
/// A reader that raises as soon as it is read, used to drive the `stor` error
/// aggregation path (`errors.Join` of the read error and the `226` error).
///
/// A `MemoryReader` whose producer fails re-raises that failure from every
/// read, which is exactly the "the source broke mid-transfer" shape — and it
/// needs no hand written `Reader` impl (whose `_get_internal_buffer` would
/// trip `--deny-warn` on `alert_internal`).
fn failing_source() -> &@io.Reader {
  @io.MemoryReader(writer => {
    ignore(writer)
    raise Failure::Failure("source is broken")
  })
}

///|
/// The empty payload, used where a failed read has to be turned back into a
/// value of the same type as the successful one.
fn empty_data() -> &@io.Data {
  ""
}

///|
/// A `Session` over a scripted control channel, plus the sink recording what
/// was sent. Used by the data channel tests, which need a session but no
/// `FTPClient`.
fn scripted_session(
  script : String,
  options? : Options = Options::default(),
) -> (Session, RecordingSink) {
  let (control, sink) = scripted_control(script)
  (Session::new(control, options~), sink)
}
