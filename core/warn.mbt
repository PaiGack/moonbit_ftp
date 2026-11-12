// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.

// Package: `PaiGack/ftp/core` — pure values and parsers, no IO.

///|
/// Warn that a login was sent in the clear to a server that could have taken
/// it over TLS.
///
/// This is deliberately not an error. The password is already on the wire by
/// the time anyone knows the server advertises `AUTH TLS`, and refusing the
/// login would only break a session the caller may have chosen on purpose (a
/// throwaway account on a lab network). What the library owes the caller is the
/// *fact*: an operator reading the log can then decide, instead of finding out
/// from a packet capture.
///
/// `user` is named, the password never is -- this line is going into a log. The
/// warning goes to stderr so that a CLI's stdout (a listing, a downloaded
/// file's name) stays machine readable.
pub fn warn_plaintext_login(user : String) -> Unit {
  eprintln(
    "warning: login for '\{user}' was sent in plaintext, but the server advertises AUTH TLS; pass explicit_tls=true to protect the password",
  )
}

///|
/// Say that a transfer fell back from `EPSV` to `PASV` because `EPSV` failed.
///
/// The fallback is upstream behaviour and is kept -- some servers only speak
/// one of the two -- but it is not free: the session latches `PASV` and keeps
/// using it, and on an IPv6-only server `PASV` is usually refused, so one
/// transient `EPSV` timeout can turn every later transfer into that refusal.
/// Without a line on stderr the caller only sees the symptom.
///
/// The failure is named, because "the server does not support EPSV" and "the
/// `EPSV` reply was lost" call for different actions.
pub fn warn_epsv_fallback(reason : String) -> Unit {
  eprintln(
    "warning: EPSV failed (\{reason}); falling back to PASV for the rest of this session",
  )
}
