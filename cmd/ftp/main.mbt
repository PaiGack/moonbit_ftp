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
///   rm <path>              remove a file or empty directory
///
/// Options:
///   --host <host>          server host (default 127.0.0.1)
///   --port <port>          server port (default 21, or 990 with --tls)
///   --user <user>          login user (default anonymous)
///   --pass <password>      login password (default empty)
///   --timeout <ms>         connect timeout in milliseconds (default 30000)
///   --tls                  use implicit TLS
///   --trust-pasv-ip        trust the IP returned by PASV
async fn main {
  match parse_args(@env.args()) {
    Ok(parsed) =>
      match parsed.command {
        None => print_usage()
        Some(cmd) => run_command(parsed, cmd)
      }
    Err(message) => {
      println("error: \{message}")
      print_usage()
    }
  }
}

///|
/// The parsed command line: the subcommand plus its positional arguments and
/// the recognized global flags.
struct CliArgs {
  mut command : String?
  positional : Array[String]
  mut host : String
  mut port : Int?
  mut user : String
  mut password : String
  mut timeout_ms : Int
  mut tls : Bool
  mut trust_pasv_ip : Bool
} derive(@debug.Debug)

///|
/// Parse `args` (including `argv[0]`), reporting unknown flags as `Err`.
fn parse_args(args : Array[String]) -> Result[CliArgs, String] {
  let parsed : CliArgs = {
    command: None,
    positional: [],
    host: "127.0.0.1",
    port: None,
    user: "anonymous",
    password: "",
    timeout_ms: 30000,
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
/// Read the value that follows a flag, reporting a missing value as `Err`.
fn next_value(
  args : Array[String],
  index : Int,
  flag : String,
) -> Result[String, String] {
  guard index + 1 < args.length() else {
    return Err("missing value for \{flag}")
  }
  Ok(args[index + 1])
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
    #|  rm <path>              remove a file or empty directory
    #|
    #|Options:
    #|  --host <host>          server host (default 127.0.0.1)
    #|  --port <port>          server port (default 21, or 990 with --tls)
    #|  --user <user>          login user (default anonymous)
    #|  --pass <password>      login password (default empty)
    #|  --timeout <ms>         connect timeout in milliseconds (default 30000)
    #|  --tls                  use implicit TLS
    #|  --trust-pasv-ip        trust the IP returned by PASV
    #|
  println(banner)
}

// ---------------------------------------------------------------------------
// Subcommand dispatch
// ---------------------------------------------------------------------------

///|
async fn run_command(args : CliArgs, command : String) -> Unit {
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
      return
    }
  }
  @lib.login(client, args.user, args.password) catch {
    e => {
      println("error: login failed: \{e}")
      return
    }
  }
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
      }
    }
    Ok(())
  } catch {
    e => Err(e)
  }
  if result is Err(e) {
    println("error: \{e}")
  }
  @lib.quit(client) catch {
    _ => ()
  }
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
  guard positional is [path, ..] else {
    println("usage: rm <path>")
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
            "error: cannot remove non-empty directory '\{path}': \{e}. Use a recursive tool for nested directories.",
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
