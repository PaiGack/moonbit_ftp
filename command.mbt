// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

///|
/// Send `cmd` (already encoded) and return the reply.
pub async fn cmd(control : Control, command : String) -> Response {
  check_for_command_injection(command)
  control.send_line(command)
  read_response(control)
}

///|
/// Send `cmd` and require one of the `expected` status codes.
///
/// An empty `expected` list accepts any code, which is how upstream spells
/// `cmd(..., -1)` for the `expected == -1` case. A mismatch raises
/// `FtpError::ServerError` carrying the original message.
pub async fn cmd_expect(
  control : Control,
  command : String,
  expected : Array[Int],
) -> Response {
  let response = cmd(control, command)
  if expected.length() == 0 || expected.contains(response.code()) {
    return response
  }
  raise FtpError::ServerError(code=response.code(), msg=response.message())
}

///|
/// Send `\`format\`` with `args` applied through `{}` substitution and require
/// one of the `expected` codes. Convenience wrapper mirroring upstream
/// `cmd(format, args, expected...)`.
pub async fn cmd_format(
  control : Control,
  format : String,
  args : Array[String],
  expected : Array[Int],
) -> Response {
  let mut rendered = format
  for arg in args {
    check_for_command_injection(arg)
    rendered = replace_first(rendered, "{}", arg)
  }
  cmd_expect(control, rendered, expected)
}

///|
/// Refuse command arguments that contain CR or LF.
///
/// Upstream calls this `checkForCommandInjection`; the check must happen
/// before a single byte is written to the socket, otherwise a crafted path
/// could smuggle extra FTP commands into the session.
pub fn check_for_command_injection(arg : String) -> Unit raise FtpError {
  for byte in arg {
    if byte == '\r' || byte == '\n' {
      raise FtpError::InvalidCommand(arg~)
    }
  }
}

///|
/// Replace the first occurrence of `{}` in `format` with `value`.
fn replace_first(format : String, pattern : String, value : String) -> String {
  let index = match format.find(pattern) {
    Some(index) => index
    None => return format
  }
  format[0:index].to_owned() +
  value +
  format[index + pattern.length():].to_owned()
}
