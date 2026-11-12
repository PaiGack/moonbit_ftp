// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

///|
/// A small FTP CLI that drives the PaiGack/ftp client API.
///
/// Usage: moon run cmd/ftp -- [options] <command> [args]
///
/// Subcommands:
///   ls <path>              list a remote directory
///   get <remote> [local]   download a file (resumes if local is shorter)
///   put <local> [remote]   upload a file
///   walk <root>            walk a remote directory tree
///   mkdir <path>           create a directory
///   rm [-r] <path>         remove a file, an empty directory, or a whole tree with -r
///
/// Options:
///   --host <host>          server host (default 127.0.0.1)
///   --port <port>          server port (default 21, or 990 with --tls)
///   --user <user>          login user (default anonymous)
///   --pass <password>      login password (default empty)
///   --timeout <ms>         connect timeout in milliseconds (default 30000)
///   --tls                  use implicit TLS
///   --trust-pasv-ip        trust the IP returned by PASV
///   -h, --help             print this usage and exit
///
/// The same five connection settings can come from the environment
/// (`FTP_TEST_HOST` / `FTP_TEST_PORT` / `FTP_TEST_USER` / `FTP_TEST_PASS` /
/// `FTP_TEST_TIMEOUT`, the names `cmd/example`, `cmd/profiles` and the
/// `scripts/*.sh` helpers all use); an explicit flag always wins. The
/// unprefixed `FTP_HOST` / `FTP_PORT` / `FTP_USER` / `FTP_PASS` /
/// `FTP_TIMEOUT` are still read as a second fallback, so an existing shell
/// profile keeps working. See `env_or` for why that layer exists.
///
/// Exit codes: 0 on success (including `--help`), 2 on a usage error such as an
/// unknown option or a missing value, 1 on a failed FTP command.
async fn main {
  match parse_args(@env.args()) {
    Ok(parsed) =>
      match parsed.help {
        true => print_usage()
        false =>
          match parsed.command {
            None => print_usage()
            Some(cmd) => {
              // The status is the command's own: 0 success, 1 a failed FTP
              // command, 2 a usage error (`get` with no arguments). It used
              // to be a `Bool`, so a missing argument printed the usage line
              // and exited 0 -- a script's `ftp get "$x" && next` carried on
              // after a call that never transferred anything.
              let code = run_command(parsed, cmd)
              if code != 0 {
                exit_with(code)
              }
            }
          }
      }
    Err(message) => {
      println("error: \{message}")
      print_usage()
      exit_with(2)
    }
  }
}

///|
/// Terminate the process with `code`, used by the CLI's failure paths because a
/// plain `return` from `main` always yields exit status 0.
fn exit_with(code : Int32) -> Unit {
  exit(code)
}

///|
/// The usage line for a subcommand that cannot run with these arguments, or
/// `None` when the arguments are well-formed. Checked by `run_command` before
/// it connects, and kept next to the subcommands it guards so the two cannot
/// disagree about how many arguments each takes.
fn usage_of(command : String, positional : Array[String]) -> String? {
  match command {
    "get" =>
      if positional.length() < 1 {
        Some("get <remote> [local]")
      } else {
        None
      }
    "put" =>
      if positional.length() < 1 {
        Some("put <local> [remote]")
      } else {
        None
      }
    "mkdir" => if positional.length() < 1 { Some("mkdir <path>") } else { None }
    "rm" => {
      let rest = match positional {
        ["-r", .. rest] => rest
        _ => positional
      }
      if rest.length() < 1 {
        Some("rm [-r] <path>")
      } else {
        None
      }
    }
    _ => None
  }
}

///|
/// How one subcommand ended, mapped by `run_command` onto an exit status.
#derive(@debug.Debug)
enum Outcome {
  Succeeded
  /// The FTP operation failed: the error was printed, status 1.
  Failed
  /// The arguments were wrong: the usage line was printed, status 2.
  Usage
}

///|
/// The C `exit`, so the CLI can report a non-zero status. MoonBit's `abort`
/// panics (SIGABRT, 134), which is not what a command-line tool should return
/// for an ordinary usage error.
extern "c" fn exit(code : Int32) = "exit"

///|
/// The parsed command line: the subcommand plus its positional arguments and
/// the recognized global flags.
#derive(@debug.Debug)
struct CliArgs {
  mut command : String?
  mut help : Bool
  positional : Array[String]
  mut host : String
  mut port : Int32?
  mut user : String
  mut password : String
  mut timeout_ms : Int32
  mut tls : Bool
  mut trust_pasv_ip : Bool
}

///|
/// Parse `args` (including `argv[0]`), reporting unknown flags as `Err`.
fn parse_args(args : Array[String]) -> Result[CliArgs, String] {
  let parsed : CliArgs = {
    command: None,
    help: false,
    positional: [],
    host: fallback_env_or("FTP_TEST_HOST", "FTP_HOST", "127.0.0.1"),
    port: fallback_env_port("FTP_TEST_PORT", "FTP_PORT"),
    user: fallback_env_or("FTP_TEST_USER", "FTP_USER", "anonymous"),
    password: fallback_env_or("FTP_TEST_PASS", "FTP_PASS", ""),
    // `fallback_env_port` splits "unset" from "declared but malformed" so the
    // default below is only replaced by a number the caller actually wrote.
    timeout_ms: match fallback_env_port("FTP_TEST_TIMEOUT", "FTP_TIMEOUT") {
      Some(ms) => ms
      None => 30000
    },
    tls: false,
    trust_pasv_ip: false,
  }
  let mut i = 1
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--host" =>
        match next_value(args, i, arg) {
          Ok(value) => {
            parsed.host = value
            i += 2
          }
          Err(message) => return Err(message)
        }
      "--port" =>
        match next_value(args, i, arg) {
          Ok(value) =>
            // A port is 1..=65535: zero and anything past it can never be
            // dialled, and a wrapped value would silently pick another port.
            match parse_int(value, limit=65535) {
              Some(port) if port > 0 => {
                parsed.port = Some(port)
                i += 2
              }
              _ => return Err("invalid --port value")
            }
          Err(message) => return Err(message)
        }
      "--user" =>
        match next_value(args, i, arg) {
          Ok(value) => {
            parsed.user = value
            i += 2
          }
          Err(message) => return Err(message)
        }
      "--pass" =>
        match next_value(args, i, arg) {
          Ok(value) => {
            parsed.password = value
            i += 2
          }
          Err(message) => return Err(message)
        }
      "--timeout" =>
        match next_value(args, i, arg) {
          Ok(value) =>
            // Zero is not "wait forever" here -- `DialOptions` and `Control`
            // both turn it into the default deadline -- so it is a usage error
            // rather than a request nobody can observe.
            match parse_int(value) {
              Some(timeout) if timeout > 0 => {
                parsed.timeout_ms = timeout
                i += 2
              }
              _ => return Err("invalid --timeout value")
            }
          Err(message) => return Err(message)
        }
      "--help" | "-h" => {
        parsed.help = true
        i += 1
      }
      "--tls" => {
        parsed.tls = true
        i += 1
      }
      "--trust-pasv-ip" => {
        parsed.trust_pasv_ip = true
        i += 1
      }
      _ => {
        if arg.has_prefix("-") {
          return Err("unknown option: \{arg}")
        }
        // First non-flag is the subcommand; everything after is positional.
        match parsed.command {
          None => parsed.command = Some(arg)
          Some(_) => parsed.positional.push(arg)
        }
        i += 1
      }
    }
  }
  Ok(parsed)
}

///|
/// The first of `primary`, `legacy` that is set, else `fallback`.
///
/// The environment is the *default* layer, and it is here so that a caller who
/// knows the endpoint -- `cmd/ftp/run.sh` against the container it just started
/// -- hands it over through the environment instead of through the command
/// line. That matters when the command line is also data: a wrapper that builds
/// `--host <value>` from an environment value passes a bare host name as one
/// argv entry, and the CLI parses its argv, so a half-set environment turns
/// "connect to 127.0.0.1" into a usage error on an argument the caller never
/// typed. Here the same value is read as a *flag value*, which is the shape it
/// was always meant to have.
///
/// `primary` is the `FTP_TEST_*` name that `cmd/example`, `cmd/profiles` and
/// the `scripts/*.sh` helpers all use, so one exported environment configures
/// every client; `legacy` is the unprefixed name this CLI used on its own,
/// kept so an existing profile does not silently stop applying. There used to
/// be only the unprefixed one, and nothing in CI set it -- so the step ran as
/// `anonymous` and failed its login while the two clients beside it, which
/// read `FTP_TEST_*`, passed. One spelling for the whole repo is what makes
/// that class of failure impossible; the legacy name is compatibility, not the
/// contract, and `scripts/ftp-wrapper-selftest.py` checks the two agree.
fn fallback_env_or(
  primary : String,
  legacy : String,
  fallback : String,
) -> String {
  match @env.get_env_var(primary) {
    Some(value) => value
    None =>
      match @env.get_env_var(legacy) {
        Some(value) => value
        None => fallback
      }
  }
}

///|
/// The first of `primary`, `legacy` that is set *and* decimal, else `None`.
///
/// "Unset" and "set to something that is not a number" stay distinguishable
/// on purpose: a malformed value must not replace the caller's documented
/// default with a number nobody wrote (a non-decimal `primary` therefore falls
/// through to `legacy`), while genuinely absent numbers are reported as
/// `None` so the caller applies that default itself. The environment here is a
/// convenience default, and the CLI's own `--port` / `--timeout` remain the
/// authority, so a typo in a shell profile must not make the tool unusable.
fn fallback_env_port(primary : String, legacy : String) -> Int32? {
  for name in [primary, legacy] {
    match @env.get_env_var(name) {
      Some(value) =>
        match parse_int(value, limit=65535) {
          Some(number) if number > 0 => return Some(number)
          _ => ()
        }
      None => ()
    }
  }
  None
}

///|
/// Read the value that follows a flag, reporting a missing value as `Err`.
fn next_value(
  args : Array[String],
  index : Int32,
  flag : String,
) -> Result[String, String] {
  guard index + 1 < args.length() else {
    return Err("missing value for \{flag}")
  }
  Ok(args[index + 1])
}

///|
/// Parse a decimal integer, returning `None` on any non-digit byte.
///
/// The value is bounded by `limit` (65535 for ports, `Int32::max_value()` for
/// timeouts): an unbounded loop wraps a long digit string around in `Int32`, so
/// `--port 4294983695` used to come out as a small valid port.
fn parse_int(text : String, limit~ : Int32 = 2147483647) -> Int32? {
  guard text != "" else { return None }
  let mut value = 0
  for i = 0; i < text.length(); i = i + 1 {
    let c = text.unsafe_get(i).to_int()
    guard c >= 48 && c <= 57 else { return None }
    guard value <= (limit - (c - 48)) / 10 else { return None }
    value = value * 10 + (c - 48)
  }
  Some(value)
}

///|
/// Print the usage banner.
fn print_usage() -> Unit {
  let banner =
    #|Usage: moon run cmd/ftp -- [options] <command> [args]
    #|
    #|Commands:
    #|  ls <path>              list a remote directory
    #|  get <remote> [local]   download a file
    #|  put <local> [remote]   upload a file
    #|  walk <root>            walk a remote directory tree
    #|  mkdir <path>           create a directory
    #|  rm [-r] <path>         remove a file, an empty directory, or a whole tree with -r
    #|
    #|Options:
    #|  --host <host>          server host (default 127.0.0.1)
    #|  --port <port>          server port (default 21, or 990 with --tls)
    #|  --user <user>          login user (default anonymous)
    #|  --pass <password>      login password (default empty)
    #|  --timeout <ms>         connect timeout in milliseconds (default 30000)
    #|  --tls                  use implicit TLS
    #|  --trust-pasv-ip        trust the IP returned by PASV
    #|  -h, --help             print this usage and exit
    #|
    #|Environment (defaults only; the flags above win):
    #|  FTP_HOST, FTP_PORT, FTP_USER, FTP_PASS, FTP_TIMEOUT
    #|
  println(banner)
}

// ---------------------------------------------------------------------------
// Subcommand dispatch
// ---------------------------------------------------------------------------

///|
/// Run one subcommand and report the exit status `main` should use: 0 on
/// success, 1 for a failed FTP command, 2 for a usage error (a subcommand
/// called with too few arguments).
///
/// The subcommands return `Outcome` rather than `Unit` so that "I
/// printed a usage line and stopped" is distinguishable from "the server
/// refused". The argument count is checked *before* connecting: a script
/// that calls `ftp get` with an empty variable should learn that its own
/// call was malformed, not that a server it never meant to reach is down.
async fn run_command(args : CliArgs, command : String) -> Int32 {
  let usage_error = usage_of(command, args.positional)
  if usage_error is Some(message) {
    println("usage: \{message}")
    return 2
  }
  let port = match args.port {
    Some(p) => p
    None => if args.tls { 990 } else { 21 }
  }
  let client = @lib.dial(
    "\{args.host}:\{port}",
    timeout_ms=args.timeout_ms,
    tls=args.tls,
    trust_pasv_ip=args.trust_pasv_ip,
  ) catch {
    e => {
      println("error: connect failed: \{e}")
      return 1
    }
  }
  @lib.login(client, args.user, args.password) catch {
    e => {
      println("error: login failed: \{e}")
      return 1
    }
  }
  let outcome : Result[Outcome, Error] = try {
    let outcome = match command {
      "ls" => cmd_ls(client, args.positional)
      "get" => cmd_get(client, args.positional)
      "put" => cmd_put(client, args.positional)
      "walk" => cmd_walk(client, args.positional)
      "mkdir" => cmd_mkdir(client, args.positional)
      "rm" => cmd_rm(client, args.positional)
      other => {
        println("error: unknown command '\{other}'")
        print_usage()
        Outcome::Failed
      }
    }
    Ok(outcome)
  } catch {
    e => Err(e)
  }
  let code = match outcome {
    Err(e) => {
      println("error: \{e}")
      1
    }
    Ok(Outcome::Succeeded) => 0
    Ok(Outcome::Failed) => 1
    Ok(Outcome::Usage) => 2
  }
  @lib.quit(client) catch {
    _ => ()
  }
  code
}

///|
async fn cmd_ls(client : @lib.FTPClient, positional : Array[String]) -> Outcome {
  let path = match positional {
    [p, ..] => p
    [] => "/"
  }
  for entry in @lib.list(client, path) {
    println("\{entry.type_.to_string()}  \{entry.size}  \{entry.name}")
  }
  Outcome::Succeeded
}

///|
async fn cmd_get(
  client : @lib.FTPClient,
  positional : Array[String],
) -> Outcome {
  guard positional is [remote, .. rest] else {
    println("usage: get <remote> [local]")
    return Outcome::Usage
  }
  // An explicit local name is the caller's own choice; a derived one comes
  // from the remote path (or the server), so it must stay a plain file name in
  // the current directory -- `/x/..` would otherwise open the parent directory.
  let dest = match rest {
    [p, ..] => Ok(p)
    [] => safe_local_name(remote)
  }
  let dest = match dest {
    Ok(name) => name
    Err(message) => {
      println("error: \{message}")
      return Outcome::Failed
    }
  }
  // Resume if the local file exists and is shorter than the remote file.
  let remote_size = @lib.file_size(client, remote)
  let local_size = @fs.file_size(dest) catch { _ => 0L }
  let offset = if local_size > 0L &&
    local_size.reinterpret_as_uint64() < remote_size {
    local_size
  } else {
    0L
  }
  let file = if offset > 0L {
    println("resuming from offset \{offset}")
    @fs.open(dest, mode=WriteOnly, append=true)
  } else {
    @fs.open(dest, mode=WriteOnly, create_mode=CreateOrTruncate)
  }
  defer file.close()
  let response = if offset > 0L {
    @lib.retr_from(client, remote, offset~)
  } else {
    @lib.retr(client, remote)
  }
  // `read_to` streams and closes: the response holds the session lock, so a
  // separate read loop followed by `close` is the same transfer with one more
  // way to forget the `close`.
  response.read_to(file)
  println("\{remote} -> \{dest} (\{remote_size} bytes)")
  Outcome::Succeeded
}

///|
async fn cmd_put(
  client : @lib.FTPClient,
  positional : Array[String],
) -> Outcome {
  guard positional is [src_path, .. rest] else {
    println("usage: put <local> [remote]")
    return Outcome::Usage
  }
  let dest = match rest {
    [r, ..] => r
    [] =>
      match safe_local_name(src_path) {
        Ok(name) => name
        Err(message) => {
          println("error: \{message}")
          return Outcome::Failed
        }
      }
  }
  let file = @fs.open(src_path, mode=ReadOnly)
  defer file.close()
  @lib.stor(client, dest, file)
  let uploaded = @lib.file_size(client, dest)
  println("\{src_path} -> \{dest} (\{uploaded} bytes)")
  Outcome::Succeeded
}

///|
async fn cmd_walk(
  client : @lib.FTPClient,
  positional : Array[String],
) -> Outcome {
  let root = match positional {
    [r, ..] => r
    [] => "/"
  }
  let w = @lib.walk(client, root)
  while w.next() {
    println("\{w.path()}")
  }
  walk_outcome(w.err())
}

///|
/// The status a finished walk reports. Split out of `cmd_walk` because the
/// decision is the whole point and `cmd/ftp`'s tests have no way to drive a
/// failing listing without a server.
///
/// `Walker::next` stops at the first directory it cannot list, so an error
/// means the output is *partial*: the subtrees after the failure were never
/// visited. Reporting that and exiting 0 (what a `println` with no status did)
/// left a script believing it had seen the whole tree.
fn walk_outcome(error : Error?) -> Outcome {
  match error {
    Some(e) => {
      println("error during walk: \{e}")
      Outcome::Failed
    }
    None => Outcome::Succeeded
  }
}

///|
async fn cmd_mkdir(
  client : @lib.FTPClient,
  positional : Array[String],
) -> Outcome {
  guard positional is [path, ..] else {
    println("usage: mkdir <path>")
    return Outcome::Usage
  }
  @lib.make_dir(client, path)
  println("created \{path}")
  Outcome::Succeeded
}

///|
async fn cmd_rm(client : @lib.FTPClient, positional : Array[String]) -> Outcome {
  // `-r` is peeled off here rather than in the shared option parser, which
  // would otherwise make it a global flag for every subcommand.
  let (recursive, rest) = match positional {
    ["-r", .. rest] => (true, rest)
    _ => (false, positional)
  }
  guard rest is [path, ..] else {
    println("usage: rm [-r] <path>")
    return Outcome::Usage
  }
  if recursive {
    @lib.remove_dir_recur(client, path)
    println("removed directory tree \{path}")
    return Outcome::Succeeded
  }
  let entry = @lib.get_entry(client, path) catch {
    e => {
      println("error: \{e}")
      return Outcome::Failed
    }
  }
  match entry.type_ {
    File | Link => {
      @lib.delete(client, path)
      println("deleted \{path}")
      Outcome::Succeeded
    }
    Folder =>
      try {
        @lib.remove_dir(client, path)
        println("removed directory \{path}")
        Outcome::Succeeded
      } catch {
        e => {
          println(
            "error: cannot remove non-empty directory '\{path}': \{e}. Re-run with -r to remove it recursively.",
          )
          Outcome::Failed
        }
      }
  }
}

///|
/// Return the last path segment of `path`, or the whole string if no `/`.
fn basename(path : String) -> String {
  let trimmed = path.trim_end(chars="/")
  match trimmed.rev_find("/") {
    Some(i) => trimmed[i + 1:].to_owned()
    None => trimmed.to_owned()
  }
}

///|
/// Derive a local file name from a remote path that is safe to open for
/// writing in the current directory.
///
/// The name is attacker-controlled -- it comes from the `get` argument or the
/// server's listing -- so `.`, `..` and the empty string are refused: joining
/// them to the working directory would leave it (`..` opens the parent
/// directory, `..` mid-path escapes further). A name that still contains a
/// path separator or a backslash is refused too, so the result is always a
/// plain entry of the current directory.
fn safe_local_name(path : String) -> Result[String, String] {
  let raw = basename(path)
  // Trim only surrounding whitespace; a name whose *content* is `..` is the
  // dangerous one, and `trim` does not touch interior characters.
  let name = raw.trim(chars=" ").to_owned()
  let unsafe_name = name == "" ||
    name == "." ||
    name == ".." ||
    name.find("/") is Some(_) ||
    name.find("\\") is Some(_)
  if unsafe_name {
    return Err(
      "refusing to write '\{path}': derived local name '\{name}' is not a plain file name",
    )
  }
  Ok(name)
}
