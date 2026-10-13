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
/// (`FTP_HOST` / `FTP_PORT` / `FTP_USER` / `FTP_PASS` / `FTP_TIMEOUT`); an
/// explicit flag always wins. See `env_or` for why that layer exists.
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
            Some(cmd) => if run_command(parsed, cmd) { exit_with(1) }
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
/// The C `exit`, so the CLI can report a non-zero status. MoonBit's `abort`
/// panics (SIGABRT, 134), which is not what a command-line tool should return
/// for an ordinary usage error.
extern "c" fn exit(code : Int32) = "exit"

///|
/// The parsed command line: the subcommand plus its positional arguments and
/// the recognized global flags.
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
} derive(@debug.Debug)

///|
/// Parse `args` (including `argv[0]`), reporting unknown flags as `Err`.
fn parse_args(args : Array[String]) -> Result[CliArgs, String] {
  let parsed : CliArgs = {
    command: None,
    help: false,
    positional: [],
    host: env_or("FTP_HOST", "127.0.0.1"),
    port: env_port("FTP_PORT"),
    user: env_or("FTP_USER", "anonymous"),
    password: env_or("FTP_PASS", ""),
    timeout_ms: env_timeout("FTP_TIMEOUT"),
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
            match parse_int(value) {
              Some(port) => {
                parsed.port = Some(port)
                i += 2
              }
              None => return Err("invalid --port value")
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
            match parse_int(value) {
              Some(timeout) => {
                parsed.timeout_ms = timeout
                i += 2
              }
              None => return Err("invalid --timeout value")
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
/// `@env.get_env_var` as a plain `String`, with `fallback` for an unset variable.
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
fn env_or(name : String, fallback : String) -> String {
  match @env.get_env_var(name) {
    Some(value) => value
    None => fallback
  }
}

///|
/// Read `name` as a decimal number, or `None` when it is unset or not
/// decimal. A malformed value is treated as unset rather than fatal: the
/// environment here is a convenience default, and the CLI's own `--port` /
/// `--timeout` remain the authority, so a typo in a shell profile must not make
/// the tool unusable.
fn env_port(name : String) -> Int32? {
  match @env.get_env_var(name) {
    Some(value) => parse_int(value)
    None => None
  }
}

///|
/// `FTP_TIMEOUT` in milliseconds, falling back to the documented default.
fn env_timeout(name : String) -> Int32 {
  match env_port(name) {
    Some(value) => value
    None => 30000
  }
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
fn parse_int(text : String) -> Int32? {
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
/// Run one subcommand, returning `true` when it failed so `main` can set a
/// non-zero exit status.
async fn run_command(args : CliArgs, command : String) -> Bool {
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
      return true
    }
  }
  @lib.login(client, args.user, args.password) catch {
    e => {
      println("error: login failed: \{e}")
      return true
    }
  }
  let mut failed = false
  let result : Result[Unit, Error] = try {
    match command {
      "ls" => cmd_ls(client, args.positional)
      "get" => cmd_get(client, args.positional)
      "put" => cmd_put(client, args.positional)
      "walk" => cmd_walk(client, args.positional)
      "mkdir" => cmd_mkdir(client, args.positional)
      "rm" => cmd_rm(client, args.positional)
      other => {
        println("error: unknown command '\{other}'")
        print_usage()
        failed = true
      }
    }
    Ok(())
  } catch {
    e => Err(e)
  }
  if result is Err(e) {
    println("error: \{e}")
    failed = true
  }
  @lib.quit(client) catch {
    _ => ()
  }
  failed
}

///|
async fn cmd_ls(client : @lib.FTPClient, positional : Array[String]) -> Unit {
  let path = match positional {
    [p, ..] => p
    [] => "/"
  }
  for entry in @lib.list(client, path) {
    println("\{entry.type_.to_string()}  \{entry.size}  \{entry.name}")
  }
}

///|
async fn cmd_get(client : @lib.FTPClient, positional : Array[String]) -> Unit {
  guard positional is [remote, .. rest] else {
    println("usage: get <remote> [local]")
    return
  }
  let dest = match rest {
    [p, ..] => p
    [] => basename(remote)
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
  file.write_reader(response.reader)
  response.close()
  println("\{remote} -> \{dest} (\{remote_size} bytes)")
}

///|
async fn cmd_put(client : @lib.FTPClient, positional : Array[String]) -> Unit {
  guard positional is [src_path, .. rest] else {
    println("usage: put <local> [remote]")
    return
  }
  let dest = match rest {
    [r, ..] => r
    [] => basename(src_path)
  }
  let file = @fs.open(src_path, mode=ReadOnly)
  defer file.close()
  @lib.stor(client, dest, file)
  let uploaded = @lib.file_size(client, dest)
  println("\{src_path} -> \{dest} (\{uploaded} bytes)")
}

///|
async fn cmd_walk(client : @lib.FTPClient, positional : Array[String]) -> Unit {
  let root = match positional {
    [r, ..] => r
    [] => "/"
  }
  let w = @lib.walk(client, root)
  while w.next() {
    println("\{w.path()}")
  }
  if w.err() is Some(e) {
    println("error during walk: \{e}")
  }
}

///|
async fn cmd_mkdir(client : @lib.FTPClient, positional : Array[String]) -> Unit {
  guard positional is [path, ..] else {
    println("usage: mkdir <path>")
    return
  }
  @lib.make_dir(client, path)
  println("created \{path}")
}

///|
async fn cmd_rm(client : @lib.FTPClient, positional : Array[String]) -> Unit {
  // `-r` is peeled off here rather than in the shared option parser, which
  // would otherwise make it a global flag for every subcommand.
  let (recursive, rest) = match positional {
    ["-r", .. rest] => (true, rest)
    _ => (false, positional)
  }
  guard rest is [path, ..] else {
    println("usage: rm [-r] <path>")
    return
  }
  if recursive {
    @lib.remove_dir_recur(client, path)
    println("removed directory tree \{path}")
    return
  }
  let entry = @lib.get_entry(client, path) catch {
    e => {
      println("error: \{e}")
      return
    }
  }
  match entry.type_ {
    File | Link => {
      @lib.delete(client, path)
      println("deleted \{path}")
    }
    Folder =>
      try {
        @lib.remove_dir(client, path)
        println("removed directory \{path}")
      } catch {
        e =>
          println(
            "error: cannot remove non-empty directory '\{path}': \{e}. Re-run with -r to remove it recursively.",
          )
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
