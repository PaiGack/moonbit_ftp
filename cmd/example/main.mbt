// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

///|
/// A runnable end-to-end demonstration of the PaiGack/ftp client API against
/// a real vsftpd container started by `scripts/start-ftp.sh`. Every operation
/// prints what it's about to do and the result it observed, so a human
/// (or a CI log) can read the demo's effect without parsing assertions.
///
/// Usage:
///   scripts/start-ftp.sh
///   export FTP_TEST_HOST=127.0.0.1 FTP_TEST_PORT=21 \
///          FTP_TEST_USER=test FTP_TEST_PASS=test
///   moon run cmd/example --target native
///   scripts/stop-ftp.sh
async fn main {
  let host = env_string("FTP_TEST_HOST").unwrap_or("127.0.0.1")
  let port = env_int("FTP_TEST_PORT", 21)
  let user = env_string("FTP_TEST_USER").unwrap_or("test")
  let pass = env_string("FTP_TEST_PASS").unwrap_or("test")

  println("==> connecting to \{host}:\{port} as \{user}")
  let client = @ftp.dial(
    "\{host}:\{port}",
    timeout_ms=15000,
    trust_pasv_ip=true,
  )
  @ftp.login(client, user, pass)
  println("    PWD: \{@ftp.current_dir(client)}")

  // The container mounts testdata/ftp/fixture as the FTP user's home, so
  // the root is / and hello.txt / sub/ are visible right there.
  println("==> LIST /")
  for entry in @ftp.list(client, "/") {
    println("    \{entry.type_.to_string()}  size=\{entry.size}  \{entry.name}")
  }

  // Download the fixture file and print its content.
  println("==> RETR /hello.txt")
  let response = @ftp.retr(client, "/hello.txt")
  let bytes = response.reader.read_all() catch { _ => b"" }
  response.close()
  let payload = bytes.text() catch { _ => "" }
  println("    payload: \{payload}")

  // Upload, rename, size-check, then delete.
  let upload = "/moonbit_demo.txt"
  let renamed = "/moonbit_demo_renamed.txt"
  println("==> STOR \{upload}")
  @ftp.stor(client, upload, text_reader("demo upload from cmd/example\n"))
  println("    SIZE: \{@ftp.file_size(client, upload)}")
  println("==> RNFR \{upload} -> RNTO \{renamed}")
  @ftp.rename(client, upload, renamed)
  println("    SIZE after rename: \{@ftp.file_size(client, renamed)}")
  println("==> DELE \{renamed}")
  @ftp.delete(client, renamed)

  // MKD / RMD round-trip.
  println("==> MKD /moonbit_demo_dir ; RMD /moonbit_demo_dir")
  @ftp.make_dir(client, "/moonbit_demo_dir")
  @ftp.remove_dir(client, "/moonbit_demo_dir")

  // Walk the directory tree once (just the fixture sub/ subtree, to keep
  // the demo's output short).
  println("==> WALK /sub")
  let w = @ftp.walk(client, "/sub")
  while w.next() {
    println("    \{w.path()}")
  }

  @ftp.quit(client)
  println("==> OK")
}

// ---------------------------------------------------------------------------
// Local helpers (copied from the deleted ftp_server_test.mbt, since the demo
// file is the only consumer and the test helper namespace is gone).
// ---------------------------------------------------------------------------

///|
/// Read `name` from the environment, treating the empty string as unset.
fn env_string(name : String) -> String? {
  match @env.get_env_var(name) {
    Some(value) => if value == "" { None } else { Some(value) }
    None => None
  }
}

///|
/// Read an integer setting, falling back to `default` when it is unset or not
/// a plain decimal number.
fn env_int(name : String, default : Int) -> Int {
  match env_string(name) {
    Some(text) =>
      match @ftp.parse_decimal(text) {
        Some(value) => value
        None => default
      }
    None => default
  }
}

///|
/// A one-shot reader over an in-memory string, used to feed the upload.
fn text_reader(text : String) -> &@io.Reader {
  @io.MemoryReader(writer => writer.write(text))
}
