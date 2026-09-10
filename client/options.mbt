// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

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
    timeout_ms: @types.default_dial_timeout_ms,
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
pub fn DialOptions::to_state_options(self : DialOptions) -> @state.Options {
  @state.Options::new(
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
