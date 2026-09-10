// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: pure logic — no IO, no `moonbitlang/async` dependency.

///|
/// Default timeout used when dialing a server, in milliseconds
/// (upstream `ftp.DefaultDialTimeout`, 30s).
pub let default_dial_timeout_ms : Int = 30 * 1000

///|
/// Go-style time layout used by the `MDTM` / `MFMT` commands.
pub let time_format : String = "yyyyMMddHHmmss"

///|
/// Timezone used to interpret `MDTM` / `MFMT` timestamps (they are UTC).
pub let utc_offset_seconds : Int = 0
