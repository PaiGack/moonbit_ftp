// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

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
