// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

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
  control : @control.Control
  /// `EPSV` failed once, fall back to `PASV` for the rest of the session.
  mut skip_epsv : Bool
  /// `PRET` is supported by the server (`FEAT` advertises it).
  mut use_pret : Bool
}

///|
/// Build a session around an already established control connection.
pub fn Session::new(
  control : @control.Control,
  options? : Options = Options::default(),
) -> Session {
  { options, control, skip_epsv: false, use_pret: false, }
}

///|
/// The control connection of this session.
pub fn Session::control(self : Session) -> @control.Control {
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
    timeout_ms: @types.default_dial_timeout_ms,
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
