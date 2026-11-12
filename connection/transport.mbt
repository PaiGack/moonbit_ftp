// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

// The data channel: everything between "a transfer was requested" and "the
// socket is open".
//
// This file merges what used to be three files (`transport_pasv`,
// `transport_epsv`, `transport_dataconn`). They were always one concern —
// opening the passive data connection — and were only split by which RFC the
// command came from, which is a poor reason to make a reader jump between
// files. `get_data_port` below is the seam that ties `PASV` and `EPSV`
// together, and `open_data_conn` / `cmd_data_conn_from` are its only callers.

///|
/// Send `PASV` and return the `(ip, port)` pair the server advertises.
///
/// `227 Entering Passive Mode (127,0,0,1,196,6)`
pub async fn pasv(control : Control) -> (String, Int32) {
  let response = cmd_expect(control, "PASV", [@core.status_enter_passive_mode])
  parse_pasv(response.message())
}

///|
/// Parse the six comma separated numbers of a `PASV` reply into an IP and a
/// port (`port = p1 * 256 + p2`). Fewer than six numbers is an error.
pub fn parse_pasv(line : String) -> (String, Int32) raise @core.FtpError {
  let open = match line.find("(") {
    Some(open) => open
    None =>
      raise @core.FtpError::ParseError(msg="invalid PASV response: \{line}")
  }
  // The closing bracket has to be searched for *after* the opening one: a line
  // that puts `)` first (`") (1,2,3,4,5,6"`) would otherwise slice backwards
  // from `open + 1` to a `close` before it, which is a trap rather than a parse
  // error, and the six numbers would come from the wrong place.
  let close = match line[open + 1:].find(")") {
    Some(offset) => open + 1 + offset
    None =>
      raise @core.FtpError::ParseError(msg="invalid PASV response: \{line}")
  }
  guard close > open + 1 else {
    raise @core.FtpError::ParseError(msg="invalid PASV response: \{line}")
  }
  let inner = line[open + 1:close].to_owned()
  let parts = inner.split(",").collect()
  guard parts.length() >= 6 else {
    raise @core.FtpError::ParseError(msg="invalid PASV response: \{line}")
  }
  let numbers : Array[Int32] = []
  for i = 0; i < 6; i = i + 1 {
    let text = parts[i].trim().to_owned()
    guard is_all_digits(text) else {
      raise @core.FtpError::ParseError(msg="invalid PASV response: \{line}")
    }
    let value = match parse_octet(text) {
      Some(value) => value
      None =>
        raise @core.FtpError::ParseError(msg="invalid PASV response: \{line}")
    }
    numbers.push(value)
  }
  let ip = "\{numbers[0]}.\{numbers[1]}.\{numbers[2]}.\{numbers[3]}"
  let port = numbers[4] * 256 + numbers[5]
  (ip, port)
}

///|
/// Decide whether the IP returned by `PASV` may be used as the data
/// destination.
///
/// Upstream's rule, kept verbatim: the address is bogus when it is multicast,
/// or when its "privateness" differs from the control connection, or when its
/// loopback-ness differs. This is what makes a server that answers
/// `PASV ... (10,0,0,1,...)` from a public IP unusable unless the caller opts
/// in with `trust_pasv_ip`.
pub fn is_bogus_data_ip(cmd_ip : String, data_ip : String) -> Bool {
  if is_multicast(data_ip) {
    return true
  }
  if is_private(data_ip) != is_private(cmd_ip) {
    return true
  }
  if is_loopback(data_ip) != is_loopback(cmd_ip) {
    return true
  }
  false
}

///|
/// Parse a decimal byte value (0..255), returning `None` otherwise.
pub fn parse_octet(text : String) -> Int32? {
  guard text != "" && text.length() <= 3 else { return None }
  let mut value = 0
  for i = 0; i < text.length(); i = i + 1 {
    let c = text.unsafe_get(i).to_int()
    guard c >= 48 && c <= 57 else { return None }
    value = value * 10 + (c - 48)
  }
  guard value <= 255 else { return None }
  Some(value)
}

///|
/// Whether `ip` is a private (RFC 1918 / link local / ULA) address.
pub fn is_private(ip : String) -> Bool {
  match ip_segments(ip) {
    Some(s) =>
      s[0] == 10 ||
      (s[0] == 172 && s[1] >= 16 && s[1] <= 31) ||
      (s[0] == 192 && s[1] == 168) ||
      (s[0] == 169 && s[1] == 254) ||
      (s[0] == 100 && s[1] >= 64 && s[1] <= 127)
    None => ip.to_lower().has_prefix("fc") || ip.to_lower().has_prefix("fd")
  }
}

///|
/// Whether `ip` is a loopback address (`127.0.0.0/8` or `::1`).
pub fn is_loopback(ip : String) -> Bool {
  match ip_segments(ip) {
    Some(s) => s[0] == 127
    None => ip == "::1" || ip.to_lower() == "::1"
  }
}

///|
/// Whether `ip` is a multicast address (`224.0.0.0/4` or `ff00::/8`).
pub fn is_multicast(ip : String) -> Bool {
  match ip_segments(ip) {
    Some(s) => s[0] >= 224 && s[0] <= 239
    None => ip.to_lower().has_prefix("ff")
  }
}

///|
/// Split a dotted quad into four integers, returning `None` for IPv6 or a
/// malformed input.
fn ip_segments(ip : String) -> Array[Int32]? {
  let parts = ip.split(".").collect()
  guard parts.length() == 4 else { return None }
  let out : Array[Int32] = []
  for part in parts {
    let part = part.to_owned()
    guard is_all_digits(part) else { return None }
    let value = match parse_octet(part) {
      Some(value) => value
      None => return None
    }
    out.push(value)
  }
  Some(out)
}

///|
/// Send `EPSV` (RFC 2428) and return the data port the server opened.
///
/// `229 Entering Extended Passive Mode (|||6446|)`
pub async fn epsv(control : Control) -> Int32 {
  let response = cmd_expect(control, "EPSV", [
    @core.status_enter_extended_passive_mode,
  ])
  parse_epsv(response.message())
}

///|
/// Extract the port from an `EPSV` reply body.
///
/// The body is expected to contain `|||` followed by the port and a closing
/// `|`. A malformed reply raises `ParseError` instead of silently using port
/// 0, which would otherwise hang the connect.
pub fn parse_epsv(line : String) -> Int32 raise @core.FtpError {
  let marker = match line.find("|||") {
    Some(marker) => marker
    None =>
      raise @core.FtpError::ParseError(msg="invalid EPSV response: \{line}")
  }
  let start = marker + 3
  let tail = line[start:].to_owned()
  let end = match tail.find("|") {
    Some(end) => end
    None =>
      raise @core.FtpError::ParseError(msg="invalid EPSV response: \{line}")
  }
  guard end > 0 else {
    raise @core.FtpError::ParseError(msg="invalid EPSV response: \{line}")
  }
  let digits = tail[0:end].to_owned()
  guard is_all_digits(digits) else {
    raise @core.FtpError::ParseError(msg="invalid EPSV response: \{line}")
  }
  match parse_port(digits) {
    Some(port) => port
    None =>
      raise @core.FtpError::ParseError(msg="invalid EPSV response: \{line}")
  }
}

///|
/// Whether every byte of `src` is an ASCII digit.
pub fn is_all_digits(src : String) -> Bool {
  guard src != "" else { return false }
  for i = 0; i < src.length(); i = i + 1 {
    let c = src.unsafe_get(i).to_int()
    if c < 48 || c > 57 {
      return false
    }
  }
  true
}

///|
/// Parse a non-empty decimal string into an `Int`, returning `None` on any
/// non-digit byte or on overflow.
pub fn parse_port(digits : String) -> Int32? {
  guard digits != "" else { return None }
  let mut value = 0
  for i = 0; i < digits.length(); i = i + 1 {
    let c = digits.unsafe_get(i).to_int()
    if c < 48 || c > 57 {
      return None
    }
    value = value * 10 + (c - 48)
    if value > 65535 {
      return None
    }
  }
  Some(value)
}

///|
/// The data connection used for one transfer.
///
/// The socket is always a raw `Tcp` at first, even for FTPS: the TLS handshake
/// is deferred until `start_tls` runs, which happens only *after* the server
/// answered the transfer command with `150`. `reader` / `writer` are the trait
/// objects the transfer code actually uses; before `start_tls` they point at
/// the socket, after it they point at the `Tls` session.
pub struct DataConn {
  /// The raw data socket. Kept so `start_tls` can wrap it and so the plain
  /// path can close it.
  socket : @socket.Tcp
  /// Reads the payload coming from the server.
  mut reader : &@io.Reader
  /// Writes the payload going to the server.
  mut writer : &@io.Writer
  /// The TLS session, once `start_tls` ran. `None` in the clear and for an
  /// FTPS connection whose handshake has not started yet.
  mut tls : @tls.Tls?
}

///|
/// Build a data connection over an already connected socket with a caller
/// chosen reader/writer pair.
///
/// Only for tests: the production paths build the struct from `open_data_conn`
/// so the reader and the writer are always the socket (or its TLS session).
pub fn DataConn::from_parts(
  socket : @socket.Tcp,
  reader : &@io.Reader,
  writer : &@io.Writer,
) -> DataConn {
  { socket, reader, writer, tls: None, }
}

///|
/// The readable end of the data connection.
pub fn DataConn::reader(self : DataConn) -> &@io.Reader {
  self.reader
}

///|
/// The writable end of the data connection.
pub fn DataConn::writer(self : DataConn) -> &@io.Writer {
  self.writer
}

///|
/// Start the TLS handshake on an already connected data socket.
///
/// The timing is the whole point of this function, and it is why the handshake
/// is *not* done in `open_data_conn`:
///
/// RFC 4217 starts the data-channel TLS session **after** the server accepted
/// the transfer command. The server does not read the data socket until it has
/// answered `150` on the control channel, so a client that connects and
/// handshakes earlier writes a `ClientHello` into a socket nobody is reading
/// yet -- and the server, when it later accepts the connection, sees the bytes
/// of a handshake it never invited. vsftpd and proftpd answer
/// `425 Unable to build data connection` (or simply drop it) and the transfer
/// dies; a lenient server may let it slide, which is exactly the "green but
/// wrong" state a stub server used to hide.
///
/// Doing it here also keeps the plain path untouched: `start_tls` is a no-op
/// when `Options::tls` is off, so a plaintext transfer connects no differently
/// than before.
///
/// The call is idempotent (`self.tls is None` is the guard), because
/// `stor_from` calls it again for a zero-byte upload -- the one case where
/// nothing else would have driven the handshake. See that call site.
///
/// `server_name` is the name from the control connection, and `None` there is
/// the normal case for a plaintext session. On a TLS session there is no safe
/// default to fall back to -- verifying against the peer address when the
/// caller meant a name is how a certificate check gets silently weakened -- so
/// a missing name raises instead of handshaking.
pub async fn DataConn::start_tls(
  self : DataConn,
  server_name : String?,
  trust : @tls.TrustedRoot,
  timeout_ms : Int32,
  tls : Bool,
) -> Unit {
  if tls == false {
    return
  }
  // Idempotent: `cmd_data_conn_from` already ran it right after the `150`, so
  // the zero-byte `STOR` workaround in `stor_from` calls it a second time.
  // Without this guard that would open a *new* TLS session over a socket whose
  // peer is already mid-session, and the transfer would fail with a handshake
  // error instead of the "nothing to upload" success it is meant to produce.
  guard self.tls is None else { return }
  let name = match server_name {
    Some(name) => name
    None =>
      raise @core.FtpError::ParseError(
        msg="TLS data connection without a server name",
      )
  }
  // A hang here would be indistinguishable from a stalled transfer, so the
  // handshake gets the same connect timeout as the socket itself.
  let session = @async.with_timeout(timeout_ms, async fn() {
    @tls.Tls::client(self.socket, host=name, trust~)
  })
  self.tls = Some(session)
  self.reader = session
  self.writer = session
}

///|
/// Close the data connection without touching the control channel.
///
/// For a TLS data connection the `close_notify` is sent first. This is not
/// politeness: a server that reads the upload until EOF waits for the record
/// layer to say "no more data", and a bare socket close (which is all
/// `Tls::close` does -- it frees the OpenSSL handle, the graceful half is the
/// async `Tls::shutdown`) leaves the server without its EOF, so it never
/// writes the `226` and the very next control read blocks forever. In the
/// clear the socket close *is* the EOF, so nothing extra is needed there.
///
/// The bound on that shutdown is the caller's `shut_timeout_ms`, or the
/// connection timeout when it is unset. It used to be a hard-coded 5s: an
/// upload loop against a half-dead server then paid 5 seconds *per file* that
/// no configuration could shorten, which is also a slow-rejection amplifier.
pub async fn DataConn::close(
  self : DataConn,
  timeout_ms~ : Int32 = @core.default_dial_timeout_ms,
) -> Unit {
  let bound = if timeout_ms > 0 {
    timeout_ms
  } else {
    @core.default_dial_timeout_ms
  }
  match self.tls {
    Some(tls) =>
      // The shutdown can block on a peer that stopped reading; bound it so a
      // half-dead server turns into a failed transfer rather than a hang.
      @async.with_timeout(bound, async fn() {
        tls.shutdown() catch {
          // A peer that already hung up has no one to say goodbye to.
          _ => ()
        }
      }) catch {
        _ => ()
      }
    None => ()
  }
  self.socket.close()
}

///|
/// The deadline `DataConn::close` should bound its `close_notify` with, from
/// the options of the transfer that opened this connection.
pub fn ConnOptions::shut_bound(self : ConnOptions) -> Int32 {
  if self.shut_timeout_ms > 0 {
    self.shut_timeout_ms
  } else {
    self.timeout_ms
  }
}

///|
/// Get the port to connect to, preferring `EPSV` and permanently falling back
/// to `PASV` after the first failure.
///
/// The "EPSV failed once, never try again" behaviour is a deliberate upstream
/// design choice: some servers answer `EPSV` with an error but also with a
/// malformed `PASV` reply, and retrying `EPSV` on every transfer turns a fast
/// failure into a timeout per file.
pub async fn get_data_port(
  control : Control,
  skip_epsv~ : Bool,
  disable_epsv~ : Bool,
  trust_pasv_ip~ : Bool,
) -> (String, Int32, Bool) {
  if disable_epsv == false && skip_epsv == false {
    let port = epsv(control) catch {
      _ => return pasv_data_addr(control, trust_pasv_ip, true)
    }
    return (control.host(), port, false)
  }
  pasv_data_addr(control, trust_pasv_ip, skip_epsv)
}

///|
/// Send `PASV` and apply the SSRF guard to the answer.
///
/// The server's advertised address is used only when the caller explicitly
/// trusts it *and* it is not obviously bogus; otherwise the control
/// connection's host wins. Both the `EPSV`-failed fallback and the
/// `disable_epsv` path go through here so the two cannot drift apart again.
async fn pasv_data_addr(
  control : Control,
  trust_pasv_ip : Bool,
  latched : Bool,
) -> (String, Int32, Bool) {
  let (ip, port) = pasv(control)
  if trust_pasv_ip && is_bogus_data_ip(control.host(), ip) == false {
    return (ip, port, latched)
  }
  (control.host(), port, latched)
}

///|
/// Open the passive data connection: `EPSV` / `PASV`, then a TCP connect.
///
/// No TLS handshake happens here on purpose -- see `DataConn::start_tls` for
/// why it belongs after the transfer command was accepted. The socket is left
/// raw so the handshake can be triggered at the right moment.
pub async fn open_data_conn(
  control : Control,
  skip_epsv~ : Bool,
  disable_epsv~ : Bool,
  trust_pasv_ip~ : Bool,
  timeout_ms~ : Int32,
) -> (DataConn, Bool) {
  let (ip, port, skipped) = get_data_port(
    control,
    skip_epsv~,
    disable_epsv~,
    trust_pasv_ip~,
  )
  let addr = @socket.Addr::parse("\{ip}:\{port}") catch {
    _ =>
      raise @core.FtpError::ParseError(
        msg="invalid data connection address: \{ip}:\{port}",
      )
  }
  let tcp = @async.with_timeout(timeout_ms, async fn() {
    @socket.Tcp::connect(addr)
  })
  ({ socket: tcp, reader: tcp, writer: tcp, tls: None, }, skipped)
}

///|
/// Open a data connection and start a transfer command on it.
///
/// This is the heart of the data channel and follows upstream
/// `cmdDataConnFrom` step by step:
///
/// 1. `PRET <cmd>` first when the server advertised `PRET`,
/// 2. open the data connection (a plain TCP connect, no TLS yet),
/// 3. `REST <offset>` when a resume offset was given, expecting `350`,
/// 4. send the transfer command, expecting `125` or `150`,
/// 5. **only then** start the data-channel TLS handshake for FTPS,
/// 6. on a non 2xx answer, close the data connection before raising.
///
/// Step 5 is the fix for the FTPS ordering bug: the handshake used to run
/// inside `open_data_conn`, i.e. before step 4, which no real ftpd tolerates
/// (see `DataConn::start_tls`). It now happens exactly once the server has
/// answered `150` and is ready to read the data socket.

///|
/// The connection settings `cmd_data_conn_from` and `open_data_conn` need.
///
/// A plain value rather than the client's `Session`, so this package never
/// depends on the root package: the caller (which owns the session) fills in
/// the fields once per transfer.
pub struct ConnOptions {
  /// Send `PRET <cmd>` before the transfer command.
  use_pret : Bool
  /// `EPSV` already failed once; go straight to `PASV`.
  skip_epsv : Bool
  /// Never send `EPSV` at all.
  disable_epsv : Bool
  /// Trust the IP in a `PASV` reply (off: SSRF guard).
  trust_pasv_ip : Bool
  /// Connect timeout, and the deadline for the data-channel TLS handshake.
  timeout_ms : Int32
  /// Bound on the closing `close_notify` of a TLS data connection, in
  /// milliseconds; the same `0`/negative rule as `timeout_ms`.
  shut_timeout_ms : Int32
  /// Wrap the data channel in TLS after the `150`.
  tls : Bool
  /// Name to verify the data connection's certificate against, `None` when the
  /// control connection has none (always the case in the clear).
  server_name : String?
  /// Trust policy for the data connection's certificate.
  trust : @tls.TrustedRoot
}

///|
/// Build connection options; every field has an explicit caller.
pub fn ConnOptions::new(
  use_pret~ : Bool = false,
  skip_epsv~ : Bool = false,
  disable_epsv~ : Bool = false,
  trust_pasv_ip~ : Bool = false,
  timeout_ms~ : Int32 = 0,
  shut_timeout_ms~ : Int32 = 0,
  tls~ : Bool = false,
  server_name~ : String? = None,
  trust~ : @tls.TrustedRoot = @tls.TrustedRoot::SystemRoot,
) -> ConnOptions {
  // No deadline is the SIGABRT shape (see `Control`), so the connect timeout
  // defaults to the protocol default rather than to "wait forever".
  let timeout_ms = if timeout_ms > 0 {
    timeout_ms
  } else {
    @core.default_dial_timeout_ms
  }
  {
    use_pret,
    skip_epsv,
    disable_epsv,
    trust_pasv_ip,
    timeout_ms,
    shut_timeout_ms,
    tls,
    server_name,
    trust,
  }
}

///|
/// Open the data connection for one transfer, and report whether `EPSV` has
/// just been given up on.
///
/// The `Bool` is `get_data_port`'s "latched" flag: `true` when this call took
/// the `PASV` path because `EPSV` failed (or was configured off), which is
/// what the caller stores in `Session::set_skip_epsv`. It used to be dropped
/// on the floor inside `cmd_data_conn_from`, so the "EPSV failed once, never
/// try again" latch never engaged and every transfer re-sent `EPSV` to a
/// server already known to refuse it.
pub async fn cmd_data_conn_from_ex(
  control : Control,
  offset : Int64,
  cmd : String,
  args : Array[String],
  options~ : ConnOptions,
) -> (DataConn, Bool) {
  let (conn, latched) = cmd_data_conn_from_raw(
    control,
    offset,
    cmd,
    args,
    options~,
  )
  (conn, latched)
}

///|
pub async fn cmd_data_conn_from(
  control : Control,
  offset : Int64,
  cmd : String,
  args : Array[String],
  options~ : ConnOptions,
) -> DataConn {
  let (conn, _) = cmd_data_conn_from_raw(control, offset, cmd, args, options~)
  conn
}

///|
/// The body shared by `cmd_data_conn_from` and `cmd_data_conn_from_ex`; see
/// the former for the step list.
async fn cmd_data_conn_from_raw(
  control : Control,
  offset : Int64,
  cmd : String,
  args : Array[String],
  options~ : ConnOptions,
) -> (DataConn, Bool) {
  let session = control
  if options.use_pret {
    // `PRET` announces the command *about to be sent*, so it must carry the
    // same fully rendered line — including the substituted path — that the
    // transfer command will. Building it from the raw `cmd` format would put
    // a literal `{}` on the wire and announce a different command than the
    // one that follows.
    let preview = render_command(cmd, args)
    let _ = try {
      ignore(
        cmd_expect(session, "PRET \{preview}", [
          @core.status_cmd_ok, @core.status_file_action_pending_further_info,
        ]),
      )
      true
    } catch {
      _ => false
    }
  }
  let (conn, latched) = open_data_conn(
    session,
    skip_epsv=options.skip_epsv,
    disable_epsv=options.disable_epsv,
    trust_pasv_ip=options.trust_pasv_ip,
    timeout_ms=options.timeout_ms,
  )
  if offset != 0 {
    let ok = try {
      ignore(
        cmd_format(session, "REST {}", ["\{offset}"], [
          @core.status_file_action_pending_further_info,
        ]),
      )
      true
    } catch {
      _ => false
    }
    guard ok else {
      conn.close(timeout_ms=options.shut_bound())
      raise @core.FtpError::ParseError(msg="REST command failed")
    }
  }
  // The reason the command was rejected propagates untouched. It used to be
  // replaced by a generic `transfer command failed`, which made a stalled
  // server (no reply at all) indistinguishable from one that answered `500`
  // -- the transcript that would tell them apart was already gone.
  //
  // A data connection opened here and never handed to the caller must not
  // leak, so each failure below closes it. This used to be an
  // `errdefer conn.close()`, but `close` is asynchronous and the toolchain
  // rejects a deferred body containing cancellable work (`cancellable_defer`);
  // the diagnostic's own remedy, `@async.protect_from_cancel`, does not
  // silence it either -- in this toolchain it is itself reported as
  // cancellable -- so the close is spelled out on every exit path instead.
  // The error is carried out of the `catch` and re-raised after it for the
  // same reason as in `MirrorWriter::write_once` (debug.mbt): a re-raise from
  // inside the handler is either `fragile_catch_all`, which is denied here, or
  // a miscompile when it uses the caught error after async work.
  let (response, failure) : (@core.Response, Error?) = try {
    let r = cmd_format(session, cmd, args, [
      @core.status_data_conn_already_in_use, 150,
    ])
    (r, None)
  } catch {
    e => (@core.Response::new(-1, ""), Some(e))
  }
  match failure {
    Some(e) => {
      conn.close(timeout_ms=options.shut_bound())
      raise e
    }
    None => ()
  }
  // The reply that starts a transfer is a *positive intermediate* (`125` or
  // `150`), not a completion: `2xx` only arrives at the end, on `226`. Testing
  // `@core.is_positive_completion` here rejected every real transfer.
  guard @core.is_positive_intermediate(response.code()) else {
    conn.close(timeout_ms=options.shut_bound())
    raise @core.FtpError::ServerError(
      code=response.code(),
      msg=response.message(),
    )
  }
  conn.start_tls(
    options.server_name,
    options.trust,
    options.timeout_ms,
    options.tls,
  )
  (conn, latched)
}
