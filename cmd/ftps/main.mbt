// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

///|
/// The FTPS / plain end-to-end smoke test: the TLS half of the real-server
/// demo, driven by arguments so the same binary covers both transports.
///
/// `cmd/example` exercises dial / login / list / retr / stor / rename / mkdir /
/// walk against a plaintext vsftpd. This one runs the shorter but encrypted
/// round trip (dial → login → LIST → RETR → STOR → DELE → QUIT) against
/// whichever server the caller selects:
///
/// - `explicit` (default) — plaintext control channel, `AUTH TLS` upgrades it,
///   then `PBSZ 0` / `PROT P` protect the data channel. This is the RFC 4217
///   shape a stock vsftpd with `ssl_enable=YES` speaks, and it is the mode that
///   the repo used to advertise without a single test.
/// - `plain` — no TLS at all, against `scripts/start-ftp.sh`'s container. It is
///   here so the *same* code path (`dial` + a real transfer) is exercised both
///   encrypted and in the clear: a fix that only makes TLS work and breaks the
///   plain socket ordering would otherwise slip through.
///
/// Selecting the transport is an argument, not a second program, which is what
/// makes "the client works over TLS and does not regress in the clear" a single
/// verifiable claim.
///
/// Two things are asserted that a "does it connect" test would miss:
///
/// 1. **Certificate verification is on.** The self-signed CA from
///    `scripts/ftps/gen-cert.sh` is injected through
///    `trust=@tls.TrustedRoot::CustomPemFile(...)` instead of the easy
///    `NoVerification`, so a wrong hostname, an expired leaf or a missing SAN
///    fails here exactly as it would for a user.
/// 2. **The data channel is really encrypted.** The FTPS container runs vsftpd
///    with `force_local_data_ssl=YES`, so it rejects `PASV` before `PROT P`
///    with `550`; a client that upgraded only the control connection cannot
///    transfer a single byte.
///
/// Configuration comes from the environment; `cmd/ftps/run.sh` sources
/// `.ftp-tls.env` (written by `scripts/ftps/start-ftps.sh`) and exports it. A
/// missing variable is a hard failure — the same rule as the rest of the repo:
/// no silent skip.
///
/// Usage:
///   scripts/start-ftp.sh          # plain container (port 21)
///   scripts/ftps/start-ftps.sh    # FTPS container (port 2121)
///   cmd/ftps/run.sh               # default: explicit TLS
///   cmd/ftps/run.sh plain         # no TLS, against the plain container
///   scripts/stop-ftp.sh && scripts/ftps/stop-ftps.sh
async fn main {
  let mode = match parse_mode(@env.args()) {
    Ok(mode) => mode
    Err(message) => {
      println("error: \{message}")
      println(usage())
      exit(2)
      // Unreachable: `exit` never returns, but the compiler needs a value.
      ""
    }
  }
  let host = required_env("FTP_TLS_HOST")
  let user = required_env("FTP_TLS_USER")
  let password = required_env("FTP_TLS_PASS")

  match mode {
    "plain" => {
      // No CA is needed, and no TLS: this is the same client against the
      // plaintext container on the shared port 21.
      let port = optional_env("FTP_PLAIN_PORT", 21)
      println("==> plain FTP end-to-end (no TLS) on \{host}:\{port}")
      smoke(
        "plain",
        "\{host}:\{port}",
        user,
        password,
        None,
        explicit_tls=false,
      )
    }
    _ => {
      let ca = required_env("FTP_TLS_CA")
      let port = required_env("FTP_TLS_PORT")
      println("==> FTPS end-to-end (explicit AUTH TLS), CA \{ca}")
      smoke(
        "explicit (AUTH TLS)",
        "\{host}:\{port}",
        user,
        password,
        Some(ca),
        explicit_tls=true,
      )
    }
  }

  println("==> OK: dial + login + list + retr + stor + delete completed")
}

///|
/// The transport selected on the command line.
///
/// `explicit` is the default because it is the mode with a standards-track RFC
/// and the one a user is most likely to hit; `plain` has to be asked for. An
/// unknown argument is rejected rather than silently treated as `explicit`,
/// which would turn a typo into a test that quietly covers the wrong thing.
fn parse_mode(args : Array[String]) -> Result[String, String] {
  let mut mode = "explicit"
  for i = 1; i < args.length(); i = i + 1 {
    match args[i] {
      "plain" | "--plain" => mode = "plain"
      "explicit" | "--tls" | "--explicit" => mode = "explicit"
      other => return Err("unknown argument '\{other}'")
    }
  }
  Ok(mode)
}

///|
/// The usage banner, printed on a bad argument.
fn usage() -> String {
  "usage: cmd/ftps [plain|explicit]\n" +
  "  explicit (default)  FTPS, AUTH TLS against the container on FTP_TLS_PORT\n" +
  "  plain               no TLS, against the container on FTP_PLAIN_PORT"
}

///|
/// The C `exit`, so a usage error reports a distinct status instead of the
/// SIGABRT that `abort` would produce. Mirrors `cmd/ftp`.
extern "c" fn exit(code : Int) = "exit"

///|
/// One full FTPS round trip against `addr`, printing each step.
///
/// Every step is a real assertion: the call raises on a bad status code, so
/// reaching the next `println` *is* the pass. The explicit checks below are
/// only for the things a status code cannot express.
async fn smoke(
  label : String,
  addr : String,
  user : String,
  password : String,
  ca : String?,
  explicit_tls? : Bool = false,
) -> Unit {
  println("==> \{label}: dial \{addr}")
  // With a CA the connection is verified against it; in the clear there is no
  // certificate to check, so the trust policy is irrelevant.
  let trust = match ca {
    Some(ca) => @tls.TrustedRoot::CustomPemFile(ca)
    None => @tls.TrustedRoot::SystemRoot
  }
  let client = @ftp.dial(
    addr,
    explicit_tls~,
    timeout_ms=15000,
    trust~,
    // The test servers answer PASV with 127.0.0.1, which is also the peer, so
    // the SSRF guard is satisfied without opting out of it.
    trust_pasv_ip=true,
  )

  @ftp.login(client, user, password) catch {
    e => fail("\{label}: login failed: \{@debug.Repr(e)}")
  }
  println("    PWD: \{@ftp.current_dir(client)}")

  // LIST over the encrypted data channel. This is the step that proves
  // `PROT P` took effect: without it both servers answer the passive command
  // with 550 and the listing fails.
  let entries = @ftp.list(client, "/") catch {
    e => fail("\{label}: LIST failed: \{@debug.Repr(e)}")
  }
  let mut saw_fixture = false
  for entry in entries {
    println("    \{entry.type_.to_string()}  size=\{entry.size}  \{entry.name}")
    if entry.name == "hello.txt" {
      saw_fixture = true
    }
  }
  guard saw_fixture else {
    fail("\{label}: LIST did not report the hello.txt fixture")
  }

  // RETR: the read direction of the encrypted data channel.
  let response = @ftp.retr(client, "/hello.txt") catch {
    e => fail("\{label}: RETR failed: \{@debug.Repr(e)}")
  }
  let bytes = response.reader.read_all() catch {
    e => fail("\{label}: reading the RETR payload failed: \{e}")
  }
  response.close()
  let payload = bytes.text() catch { _ => "" }
  guard payload == "hello world\n" else {
    fail(
      "\{label}: RETR payload was \{format_repr(payload)}, expected hello.txt",
    )
  }
  println("    RETR /hello.txt -> \{format_repr(payload)}")

  // STOR / DELE: the write direction, and proof that the data connection is
  // opened per transfer rather than being a one-shot control path.
  //
  // The source is a `MemoryReader`, which runs its producer in a background
  // task, and it is closed in a `defer` rather than left to the GC. That is
  // not tidiness: `stor` only drains the source once the server accepted the
  // transfer, so a `STOR` that is refused -- or that never gets its `150` --
  // leaves the producer parked on a pipe nobody reads. The async runtime
  // reports a parked task as a *deadlock* the moment the loop has nothing else
  // to run, and it names the `MemoryReader` line rather than the stalled read,
  // so the failure reads like a bug in the smoke test instead of "the server
  // did not answer". Closing the reader cancels the producer, which leaves the
  // real error (`RequestTimeout`, `550`, ...) as the only thing to report.
  let scratch = "/ftps_smoke.txt"
  let upload = @io.MemoryReader(w => w.write("ftps\n"))
  defer upload.close()
  @ftp.stor(client, scratch, upload) catch {
    e => fail("\{label}: STOR failed: \{@debug.Repr(e)}")
  }
  println("    SIZE \{scratch}: \{@ftp.file_size(client, scratch)}")
  @ftp.delete(client, scratch) catch {
    e => fail("\{label}: DELE failed: \{@debug.Repr(e)}")
  }

  @ftp.quit(client)
  println("    \{label}: dial / login / list / retr / stor / delete / quit OK")
}

///|
/// Read a required environment variable.
///
/// A missing variable means the smoke test was not wired up, which is a
/// failure and not something to paper over with a default: a silently skipped
/// TLS test is the exact state this program exists to end.
fn required_env(name : String) -> String {
  match @env.get_env_var(name) {
    Some(value) => if value == "" { missing(name) } else { value }
    None => missing(name)
  }
}

///|
/// Read an optional integer environment variable, falling back to `default`.
///
/// Used for the plaintext port, which has a sane fixed value (21) and therefore
/// no need to be a hard requirement -- unlike the FTPS port, which the caller
/// must not have to guess.
fn optional_env(name : String, default : Int) -> Int {
  match @env.get_env_var(name) {
    Some(value) =>
      match parse_int(value) {
        Some(parsed) => parsed
        None => abort("ftps smoke: \{name} is not a number: \{value}")
      }
    None => default
  }
}

///|
/// Parse a decimal integer, returning `None` on any non-digit byte.
fn parse_int(text : String) -> Int? {
  guard text != "" else { return None }
  let mut value = 0
  for i = 0; i < text.length(); i = i + 1 {
    let c = text.unsafe_get(i).to_int()
    guard c >= 48 && c <= 57 else { return None }
    value = value * 10 + (c - 48)
  }
  Some(value)
}

///|
/// Abort about a missing environment variable, in a way the compiler accepts
/// on a `String`-returning path.
fn missing(name : String) -> String {
  abort("ftps smoke: environment variable is unset: \{name}")
}

///|
/// Render a string with its escapes visible, so a whitespace or CRLF
/// difference in a payload shows up in the log instead of looking identical.
fn format_repr(text : String) -> String {
  let out = StringBuilder()
  out.write_char('"')
  for byte in text {
    match byte {
      '\n' => out.write("\\n")
      '\r' => out.write("\\r")
      '\t' => out.write("\\t")
      '"' => out.write("\\\"")
      _ => out.write_char(byte)
    }
  }
  out.write_char('"')
  out.to_string()
}
