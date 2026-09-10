// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

// The FTP client handle and the connection state it carries.
//
// This file merges `client` and `state`: `FTPClient` owns a `Session`, the
// `Session` owns the `Control` connection, and `Options` is the resolved form
// of the caller facing `DialOptions`. The four types are a single object graph
// and the accessors on `FTPClient` were the only readers of `Session::*`, so
// keeping them in separate files only hid where the state lives.

///|
/// The FTP client, the equivalent of upstream `ftp.ServerConn`.
///
/// Upstream documents this type as *not* safe for concurrent use. We keep the
/// same constraint but enforce it with a `Mutex` so that a misuse shows up as
/// serialized commands instead of a corrupted session — a deliberate
/// improvement over the Go implementation, with unchanged semantics.
pub struct FTPClient {
  /// Connection parameters negotiated at dial/login time.
  options : DialOptions
  /// The same parameters projected onto what the data channel layer needs.
  state_options : Options
  /// The control connection.
  session : Session
  /// Whether the connection is currently open.
  mut closed : Bool
  /// Peer address as given by the caller (`host:port`).
  host : String
  /// Serializes every public operation.
  mutex : @async.Mutex
  /// Capability flags collected from `FEAT`.
  mut mlst_supported : Bool
  mut mfmt_supported : Bool
  mut mdtm_supported : Bool
  mut mdtm_can_write : Bool
  /// The timezone used to interpret `LIST` timestamps.
  mut location : @time.Zone
  /// Feature names advertised by `FEAT`, uppercased.
  mut features : Map[String, Bool]
}

///|
/// Acquire the internal lock, making every public operation serialized.
///
/// Upstream documents `ServerConn` as *not* concurrency safe; enforcing it at
/// runtime is a deliberate improvement that does not change the semantics.
pub async fn FTPClient::lock(self : FTPClient) -> Unit {
  self.mutex.acquire()
}

///|
/// Release the internal lock.
pub fn FTPClient::unlock(self : FTPClient) -> Unit {
  self.mutex.release()
}

///|
/// Whether the server advertised `name` in its `FEAT` list.
pub fn FTPClient::has_feature(self : FTPClient, name : String) -> Bool {
  self.features.contains(name.to_upper())
}

///|
/// Whether the server advertised `MLST` (and `MLSD` was not disabled
/// explicitly).
pub fn FTPClient::is_mlst_supported(self : FTPClient) -> Bool {
  self.mlst_supported
}

///|
/// Whether the server accepts `MFMT` to set modification times.
pub fn FTPClient::is_mfmt_supported(self : FTPClient) -> Bool {
  self.mfmt_supported
}

///|
/// Whether the server accepts `MDTM` to read modification times.
pub fn FTPClient::is_get_time_supported(self : FTPClient) -> Bool {
  self.mdtm_supported
}

///|
/// Whether the modification time can be written, either via `MFMT` or via the
/// VsFtpd style `MDTM <time> <path>`.
pub fn FTPClient::is_set_time_supported(self : FTPClient) -> Bool {
  self.mfmt_supported || self.mdtm_supported
}

///|
/// Whether `LIST` output carries second level precision. Servers without
/// `MDTM` only give minute precision through `LIST`.
pub fn FTPClient::is_time_precise_in_list(self : FTPClient) -> Bool {
  self.mdtm_supported
}

///|
/// Replace the cached `FEAT` feature set.
pub fn FTPClient::set_features(
  self : FTPClient,
  features : Map[String, Bool],
) -> Unit {
  self.features = features
}

///|
/// Record whether the server supports `MLST` / `MLSD`.
pub fn FTPClient::set_mlst_supported(self : FTPClient, value : Bool) -> Unit {
  self.mlst_supported = value
}

///|
/// Record whether the server supports `MFMT`.
pub fn FTPClient::set_mfmt_supported(self : FTPClient, value : Bool) -> Unit {
  self.mfmt_supported = value
}

///|
/// Record whether the server supports `MDTM`.
pub fn FTPClient::set_mdtm_supported(self : FTPClient, value : Bool) -> Unit {
  self.mdtm_supported = value
}

///|
/// Record whether `MDTM` may be used to *write* timestamps (VsFtpd quirk).
pub fn FTPClient::set_mdtm_can_write(self : FTPClient, value : Bool) -> Unit {
  self.mdtm_can_write = value
}

///|
/// Mark the client as closed so that `quit` becomes idempotent.
pub fn FTPClient::set_closed(self : FTPClient, value : Bool) -> Unit {
  self.closed = value
}

///|
/// The timezone used to interpret `LIST` timestamps.
pub fn FTPClient::location(self : FTPClient) -> @time.Zone {
  self.location
}

///|
/// Replace the timezone used to interpret `LIST` timestamps.
pub fn FTPClient::set_location(self : FTPClient, location : @time.Zone) -> Unit {
  self.location = location
}

///|
/// The connection options this client was dialed with.
pub fn FTPClient::options(self : FTPClient) -> DialOptions {
  self.options
}

///|
/// The data channel view of the connection options.
pub fn FTPClient::state_options(self : FTPClient) -> Options {
  self.state_options
}

///|
/// The negotiated session state shared with the data channel layer.
pub fn FTPClient::session(self : FTPClient) -> Session {
  self.session
}

///|
/// `SIZE <path>`, expecting `213`.
pub async fn file_size(client : FTPClient, path : String) -> UInt64 {
  client.lock()
  defer client.unlock()
  let response = cmd_format(client.session.control(), "SIZE {}", [path], [
    status_file_status,
  ])
  let text = response.message().trim().to_owned()
  parse_uint(text, 10) catch {
    _ => raise FtpError::ParseError(msg="invalid SIZE response: \{text}")
  }
}

///|
/// `MDTM <path>`, expecting `213` and a `yyyyMMddHHmmss` UTC timestamp.
pub async fn get_time(client : FTPClient, path : String) -> @time.ZonedDateTime {
  client.lock()
  defer client.unlock()
  let response = cmd_format(client.session.control(), "MDTM {}", [path], [
    status_file_status,
  ])
  parse_mdtm(response.message().trim().to_owned())
}

///|
/// Parse a `yyyyMMddHHmmss` timestamp as UTC.
pub fn parse_mdtm(text : String) -> @time.ZonedDateTime raise FtpError {
  guard text.length() >= 14 else {
    raise FtpError::ParseError(msg="invalid MDTM response: \{text}")
  }
  let year = digit_field(text, 0, 4)
  let month = digit_field(text, 4, 2)
  let day = digit_field(text, 6, 2)
  let hour = digit_field(text, 8, 2)
  let minute = digit_field(text, 10, 2)
  let second = digit_field(text, 12, 2)
  @time.ZonedDateTime::of(
    year,
    month,
    day,
    hour~,
    minute~,
    second~,
    zone=@time.utc_zone,
  ) catch {
    _ => raise FtpError::ParseError(msg="invalid MDTM response: \{text}")
  }
}

///|
/// Read a fixed width decimal field or raise.
fn digit_field(src : String, start : Int, width : Int) -> Int raise FtpError {
  guard start + width <= src.length() else {
    raise FtpError::ParseError(msg="invalid date field")
  }
  let mut value = 0
  for i = start; i < start + width; i = i + 1 {
    let c = src.unsafe_get(i).to_int()
    guard c >= 48 && c <= 57 else {
      raise FtpError::ParseError(msg="invalid date field")
    }
    value = value * 10 + (c - 48)
  }
  value
}

///|
/// Set the modification time of `path`.
///
/// `MFMT` is tried first; when the server only advertises `MDTM` and
/// `writing_mdtm` is set, the VsFtpd quirk `MDTM <time> <path>` is used
/// instead. When neither is available the call raises `ServerError` with
/// code `502`, matching upstream's "not implemented" behaviour.
pub async fn set_file_time(
  client : FTPClient,
  path : String,
  timestamp : @time.ZonedDateTime,
) -> Unit {
  client.lock()
  defer client.unlock()
  let encoded = format_mdtm(timestamp)
  if client.mfmt_supported {
    ignore(
      cmd_format(client.session.control(), "MFMT {} {}", [encoded, path], [
        status_file_status,
      ]),
    )
    return
  }
  if client.mdtm_supported && client.mdtm_can_write {
    ignore(
      cmd_format(client.session.control(), "MDTM {} {}", [encoded, path], [
        status_file_status,
      ]),
    )
    return
  }
  raise FtpError::ServerError(
    code=status_not_implemented,
    msg="server does not support setting modification time",
  )
}

///|
/// Render a timestamp as `yyyyMMddHHmmss` in UTC.
pub fn format_mdtm(timestamp : @time.ZonedDateTime) -> String {
  let utc = timestamp.to_plain_date_time()
  pad(utc.year(), 4) +
  pad(utc.month(), 2) +
  pad(utc.day(), 2) +
  pad(utc.hour(), 2) +
  pad(utc.minute(), 2) +
  pad(utc.second(), 2)
}

///|
/// Left-pad `value` with zeros to `width` digits.
fn pad(value : Int, width : Int) -> String {
  let text = value.to_string()
  let missing = width - text.length()
  guard missing > 0 else { return text }
  let prefix = StringBuilder()
  for i = 0; i < missing; i = i + 1 {
    prefix.write_char('0')
  }
  prefix.to_string() + text
}

///|
/// The connection options, the MoonBit counterpart of upstream's 16
/// `DialWith*` functions. Every field has a documented default so that
/// `dial(addr)` alone is a valid call.
pub struct DialOptions {
  /// Connect timeout in milliseconds, default 30s.
  mut timeout_ms : Int
  /// Timeout applied before the 226 read that terminates a transfer.
  mut shut_timeout_ms : Int
  /// Use implicit TLS (FTPS on port 990).
  mut tls : Bool
  /// Use explicit TLS (`AUTH TLS` on port 21).
  mut explicit_tls : Bool
  /// Certificate trust policy for TLS connections.
  mut trust : @tls.TrustedRoot
  /// Never send `EPSV`, go straight to `PASV`.
  mut disable_epsv : Bool
  /// Trust the IP returned by `PASV` (off: SSRF guard).
  mut trust_pasv_ip : Bool
  /// Never send `OPTS UTF8 ON`.
  mut disable_utf8 : Bool
  /// Never use `MLSD`, always parse `LIST`.
  mut disable_mlsd : Bool
  /// Set modification times with `MDTM` (VsFtpd quirk) instead of `MFMT`.
  mut writing_mdtm : Bool
  /// Send `LIST -a` and force the `LIST` path.
  mut force_list_hidden : Bool
  /// Timezone used to interpret `LIST` timestamps, defaults to UTC.
  mut location : @time.Zone
  /// Optional traffic log.
  mut debug_log : &@io.Writer?
}

///|
/// The documented defaults: 30s connect timeout, no TLS, EPSV enabled,
/// `PASV` IP untrusted, UTF8 and MLSD enabled, UTC timestamps.
pub fn DialOptions::default() -> DialOptions {
  {
    timeout_ms: default_dial_timeout_ms,
    shut_timeout_ms: 0,
    tls: false,
    explicit_tls: false,
    trust: @tls.TrustedRoot::SystemRoot,
    disable_epsv: false,
    trust_pasv_ip: false,
    disable_utf8: false,
    disable_mlsd: false,
    writing_mdtm: false,
    force_list_hidden: false,
    location: @time.utc_zone,
    debug_log: None,
  }
}

///|
/// Project a `DialOptions` onto the subset of parameters the data channel
/// layer needs.
pub fn DialOptions::to_state_options(self : DialOptions) -> Options {
  Options::new(
    self.disable_epsv,
    self.trust_pasv_ip,
    self.tls || self.explicit_tls,
    self.timeout_ms,
    self.shut_timeout_ms,
    self.trust,
  )
}

///|
/// Replace the connect timeout in milliseconds.
pub fn DialOptions::set_timeout_ms(self : DialOptions, value : Int) -> Unit {
  self.timeout_ms = value
}

///|
/// Replace the 226 wrap-up timeout in milliseconds.
pub fn DialOptions::set_shut_timeout_ms(
  self : DialOptions,
  value : Int,
) -> Unit {
  self.shut_timeout_ms = value
}

///|
/// Turn implicit TLS on or off.
pub fn DialOptions::set_tls(self : DialOptions, value : Bool) -> Unit {
  self.tls = value
}

///|
/// Turn explicit `AUTH TLS` on or off.
pub fn DialOptions::set_explicit_tls(self : DialOptions, value : Bool) -> Unit {
  self.explicit_tls = value
}

///|
/// Replace the certificate trust policy.
pub fn DialOptions::set_trust(
  self : DialOptions,
  value : @tls.TrustedRoot,
) -> Unit {
  self.trust = value
}

///|
/// Turn `EPSV` off, forcing `PASV`.
pub fn DialOptions::set_disable_epsv(self : DialOptions, value : Bool) -> Unit {
  self.disable_epsv = value
}

///|
/// Trust or distrust the IP returned by `PASV`.
pub fn DialOptions::set_trust_pasv_ip(self : DialOptions, value : Bool) -> Unit {
  self.trust_pasv_ip = value
}

///|
/// Turn `OPTS UTF8 ON` off.
pub fn DialOptions::set_disable_utf8(self : DialOptions, value : Bool) -> Unit {
  self.disable_utf8 = value
}

///|
/// Turn `MLSD` off, forcing `LIST`.
pub fn DialOptions::set_disable_mlsd(self : DialOptions, value : Bool) -> Unit {
  self.disable_mlsd = value
}

///|
/// Use `MDTM <time> <path>` to write timestamps (VsFtpd quirk).
pub fn DialOptions::set_writing_mdtm(self : DialOptions, value : Bool) -> Unit {
  self.writing_mdtm = value
}

///|
/// Force `LIST -a`.
pub fn DialOptions::set_force_list_hidden(
  self : DialOptions,
  value : Bool,
) -> Unit {
  self.force_list_hidden = value
}

///|
/// Replace the timezone used to interpret `LIST` timestamps.
pub fn DialOptions::set_location(
  self : DialOptions,
  value : @time.Zone,
) -> Unit {
  self.location = value
}

///|
/// Attach or detach the traffic log.
pub fn DialOptions::set_debug_log(
  self : DialOptions,
  value : &@io.Writer?,
) -> Unit {
  self.debug_log = value
}

///|
/// Everything `transport` needs from a dialed FTP session.
///
/// This type exists to break the otherwise circular dependency between the
/// `client` package (which owns `FTPClient`) and the `transport` package
/// (which needs the control connection and the capability flags). `client`
/// embeds a `Session` and fills it in during `dial` / `feat`, `transport`
/// only reads it.
pub struct Session {
  /// Negotiation results and connection parameters.
  options : Options
  /// The control connection state: reader, writer, peer address, debug tee.
  control : Control
  /// `EPSV` failed once, fall back to `PASV` for the rest of the session.
  mut skip_epsv : Bool
  /// `PRET` is supported by the server (`FEAT` advertises it).
  mut use_pret : Bool
}

///|
/// Build a session around an already established control connection.
pub fn Session::new(
  control : Control,
  options? : Options = Options::default(),
) -> Session {
  { options, control, skip_epsv: false, use_pret: false, }
}

///|
/// The control connection of this session.
pub fn Session::control(self : Session) -> Control {
  self.control
}

///|
/// The connection parameters of this session.
pub fn Session::options(self : Session) -> Options {
  self.options
}

///|
/// Whether `EPSV` has already failed and must not be retried.
pub fn Session::skip_epsv(self : Session) -> Bool {
  self.skip_epsv
}

///|
/// Remember that `EPSV` failed; every later transfer goes through `PASV`.
pub fn Session::set_skip_epsv(self : Session, value : Bool) -> Unit {
  self.skip_epsv = value
}

///|
/// Whether the server supports `PRET`.
pub fn Session::use_pret(self : Session) -> Bool {
  self.use_pret
}

///|
/// Record whether the server supports `PRET`.
pub fn Session::set_use_pret(self : Session, value : Bool) -> Unit {
  self.use_pret = value
}

///|
/// The connection parameters that affect the data channel, mirroring the
/// subset of upstream `DialOption`s that `transport` cares about.
pub struct Options {
  /// Disable `EPSV` entirely and go straight to `PASV`.
  disable_epsv : Bool
  /// Trust the IP returned by `PASV` instead of the control connection IP.
  /// Off by default: this is the SSRF guard.
  trust_pasv_ip : Bool
  /// Enable TLS on the data connection as well.
  tls : Bool
  /// Timeout applied around opening the data connection, milliseconds.
  timeout_ms : Int
  /// Timeout "nudging" the control connection before the 226 read.
  shut_timeout_ms : Int
  /// Certificate trust policy for TLS data connections.
  trust : @tls.TrustedRoot
}

///|
/// Default options, matching the documented defaults in
/// `docs/porting/04-api-mapping.md`.
pub fn Options::default() -> Options {
  {
    disable_epsv: false,
    trust_pasv_ip: false,
    tls: false,
    timeout_ms: default_dial_timeout_ms,
    shut_timeout_ms: 0,
    trust: @tls.TrustedRoot::SystemRoot,
  }
}

///|
/// Build the data channel options explicitly.
pub fn Options::new(
  disable_epsv : Bool,
  trust_pasv_ip : Bool,
  tls : Bool,
  timeout_ms : Int,
  shut_timeout_ms : Int,
  trust : @tls.TrustedRoot,
) -> Options {
  { disable_epsv, trust_pasv_ip, tls, timeout_ms, shut_timeout_ms, trust, }
}

///|
/// Whether `EPSV` is disabled by configuration.
pub fn Options::disable_epsv(self : Options) -> Bool {
  self.disable_epsv
}

///|
/// Whether the `PASV` reply IP may be trusted.
pub fn Options::trust_pasv_ip(self : Options) -> Bool {
  self.trust_pasv_ip
}

///|
/// Whether the data connection is wrapped in TLS.
pub fn Options::tls(self : Options) -> Bool {
  self.tls
}

///|
/// Connect timeout for the data connection, milliseconds.
pub fn Options::timeout_ms(self : Options) -> Int {
  self.timeout_ms
}

///|
/// Timeout pushing the control connection before the 226 read, milliseconds.
pub fn Options::shut_timeout_ms(self : Options) -> Int {
  self.shut_timeout_ms
}

///|
/// The certificate trust policy for TLS data connections.
pub fn Options::trust(self : Options) -> @tls.TrustedRoot {
  self.trust
}
