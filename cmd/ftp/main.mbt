// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

///|
/// A minimal CLI skeleton for the FTP client.
///
/// W0 delivers the argument parsing and the usage output; the six subcommands
/// (`ls` / `get` / `put` / `walk` / `mkdir` / `rm`) are filled in by W7 once
/// the client API is complete.
fn main {
  let args = @env.args()
  match parse_args(args) {
    Ok(parsed) =>
      match parsed.command {
        None => print_usage()
        Some(command) =>
          println(
            "command '\{command}' is not implemented yet (W7 adds ls/get/put/walk/mkdir/rm)",
          )
      }
    Err(message) => {
      println("error: \{message}")
      print_usage()
    }
  }
}

///|
/// The parsed command line: the subcommand plus the recognized global flags.
struct CliArgs {
  mut command : String?
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
        parsed.command = Some(arg)
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
    #|  rm <path>              remove a file or directory
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
