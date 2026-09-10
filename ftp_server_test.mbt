// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

// Real FTP server end-to-end tests. There is no mock anywhere in this
// repository: every end-to-end assertion below runs against a real vsftpd.
//
// The server is the `bogem/ftp` image, i.e. **vsftpd 3.0.3**, started by
// `.ci/start-ftp.sh` from CI (GitHub Actions / CNB DinD) and from the CNB
// cloud dev environment. Four containers run side by side, one per capability
// profile, so the client's fallback paths are exercised against a daemon that
// really refuses the command:
//
//   profile    port   what it proves
//   full       2121   the reference server
//   no-mlst    2122   MLST / MLSD refused -> `list` must fall back to `LIST`
//   no-time    2123   MDTM refused -> no modification time is available
//   no-epsv    2124   EPSV refused -> PASV is used and kept for the session
//
// What vsftpd advertises (captured from a live 3.0.3 handshake, and the reason
// the MLST / MFMT assertions look the way they do):
//
//   211-Features:
//    EPRT
//    EPSV
//    MDTM
//    PASV
//    REST STREAM
//    SIZE
//    TVFS
//   211 End
//
// `MLST`, `MLSD`, `MFMT` and `UTF8` are *not* in that list and the daemon
// answers `500 Unknown command.` to the first three. Asserting that the client
// detects the absence and degrades correctly is more valuable than pretending
// RFC 3659 is available: it pins `disable_mlsd`, the `LIST` parser and the
// "no time support" branch, which is exactly what a real deployment meets.
//
// The tests are opt in through `FTP_TEST_*`. MoonBit has no skip API, so a
// runner without a server makes them *return early*; a bare
// `moon test --target native` therefore stays green locally. Once
// `FTP_TEST_HOST` is set every assertion is a hard failure - there is
// deliberately no "the server was flaky, skip it" path, because silently
// skipping is how the protocol bugs this file exists for would come back.

///|
/// How the environment describes the running FTP servers.
///
/// Every profile shares the host, the account and the fixture layout; only the
/// control port differs, because each profile is a separate daemon.
struct RealServer {
  host : String
  /// The reference server (`full`).
  port : Int
  /// `MLST` / `MLSD` refused.
  port_no_mlst : Int
  /// `MDTM` refused.
  port_no_time : Int
  /// `EPSV` refused.
  port_no_epsv : Int
  user : String
  password : String
  /// The server root, as the client sees it.
  root : String
  /// Directory the mounted fixture files live in.
  fixture : String
  /// Writable directory used to store uploads.
  work : String
}

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
      match parse_decimal(text) {
        Some(value) => value
        None => default
      }
    None => default
  }
}

///|
/// Read the server description, or `None` when the runner has no server
/// configured (the default outside CI).
fn real_server() -> RealServer? {
  let host = match env_string("FTP_TEST_HOST") {
    Some(host) => host
    None => return None
  }
  let port = env_int("FTP_TEST_PORT", 21)
  let user = match env_string("FTP_TEST_USER") {
    Some(user) => user
    None => "test"
  }
  let password = match env_string("FTP_TEST_PASS") {
    Some(password) => password
    None => "test"
  }
  let fixture = match env_string("FTP_TEST_FIXTURE") {
    Some(path) => path
    None => "/fixture"
  }
  let work = match env_string("FTP_TEST_DIR") {
    Some(path) => path
    None => "/upload"
  }
  let port_no_mlst = env_int("FTP_TEST_PORT_NO_MLST", 0)
  let port_no_time = env_int("FTP_TEST_PORT_NO_TIME", 0)
  let port_no_epsv = env_int("FTP_TEST_PORT_NO_EPSV", 0)
  Some({
    host,
    port,
    port_no_mlst,
    port_no_time,
    port_no_epsv,
    user,
    password,
    root: "/",
    fixture,
    work,
  })
}

///|
/// Append `child` to `parent`, inserting a single `/` when needed.
fn path_join(parent : String, child : String) -> String {
  if parent.has_suffix("/") {
    parent + child
  } else {
    parent + "/" + child
  }
}

///|
/// Connect and log in to the real server on `port`.
///
/// `trust_pasv_ip` is on because the fixture daemon runs on loopback and the
/// `PASV` guard would otherwise refuse the advertised address.
async fn connect_to(server : RealServer, port : Int) -> FTPClient {
  let client = dial(
    "\{server.host}:\{port}",
    timeout_ms=15000,
    trust_pasv_ip=true,
  )
  login(client, server.user, server.password)
  client
}

///|
/// Connect and log in to the reference (`full`) server.
async fn connect(server : RealServer) -> FTPClient {
  connect_to(server, server.port)
}

///|
/// Drain a `DataResponse` into a string and finish the transfer.
async fn read_all(response : DataResponse) -> String {
  let data = response.reader.read_all() catch {
    _ => {
      response.close()
      return ""
    }
  }
  let text = data.text() catch { _ => "" }
  response.close()
  text
}

///|
/// The fixture file every read test uses, mounted read only by CI.
fn fixture_file(server : RealServer) -> String {
  path_join(server.fixture, "hello.txt")
}

///|
/// A path inside the writable directory of the server.
fn work_path(server : RealServer, name : String) -> String {
  path_join(server.work, name)
}

///|
/// The server every test runs against, or `None` when this runner has none.
///
/// MoonBit has no skip API, so an unconfigured runner makes the test return
/// early instead of failing: a bare `moon test --target native` stays green on
/// a developer machine, while CI sets `FTP_TEST_*` and exercises the real
/// protocol.
///
/// Once `FTP_TEST_HOST` *is* set, every failure is a hard failure — there is no
/// soft "server was flaky" escape hatch.
fn test_server() -> RealServer? {
  real_server()
}

///|
/// A one shot reader over an in-memory string, for the upload tests.
fn text_reader(text : String) -> &@io.Reader {
  @io.MemoryReader(writer => writer.write(text))
}

// ---------------------------------------------------------------------------
// The reference (`full`) profile.
// ---------------------------------------------------------------------------

///|
/// The client sees the server root, so `PWD` answers `/`.
async test "real server: connect, login and PWD" {
  guard test_server() is Some(server) else { return }
  let client = connect(server)
  assert_eq(current_dir(client), server.root)
  quit(client)
}

///|
/// vsftpd does **not** implement `MLST` / `MLSD` / `MFMT`, so the capability
/// flags must come back false and `MDTM` must be recognised.
///
/// This replaces the old mock's "FEAT advertises MLST and MDTM" case. Pinning
/// the real capability set is what makes the `LIST` fallback and the "no time
/// write" branch reachable at all.
async test "real server: FEAT reports the real vsftpd capability set" {
  guard test_server() is Some(server) else { return }
  let client = connect(server)
  // The capabilities vsftpd 3.0.3 really advertises.
  assert_true(client.has_feature("EPSV"))
  assert_true(client.has_feature("MDTM"))
  assert_true(client.has_feature("SIZE"))
  // The feature parser keeps the first token only, so `REST STREAM` is
  // cached as `REST` — the same rule upstream applies.
  assert_true(client.has_feature("REST"))
  // And the ones it does not: no RFC 3659 listing, no time writing, no UTF8.
  assert_false(client.has_feature("MLST"))
  assert_false(client.has_feature("MLSD"))
  assert_false(client.has_feature("MFMT"))
  assert_false(client.has_feature("UTF8"))
  // Which the flags the rest of the client reads must reflect.
  assert_false(client.is_mlst_supported())
  assert_false(client.is_mfmt_supported())
  assert_true(client.is_get_time_supported())
  quit(client)
}

///|
/// With no `MLST`, `list` must have taken the `LIST` path and parsed the real
/// `ls -l` output. The daemon is asked for `LIST` directly here so the
/// assertion does not depend on the fallback being spelled the same way.
async test "real server: LIST parsing of the fixture directory" {
  guard test_server() is Some(server) else { return }
  let client = connect_to(server, server.port)
  let entries = list(client, server.fixture)
  let names = entries.map(entry => entry.name)
  assert_true(names.contains("hello.txt"))
  assert_true(names.contains("sub"))
  for entry in entries {
    if entry.name == "hello.txt" {
      assert_eq(entry.type_, EntryType::File)
      assert_eq(entry.size, 12UL)
    }
    if entry.name == "sub" {
      assert_eq(entry.type_, EntryType::Folder)
    }
  }
  quit(client)
}

///|
/// `disable_mlsd` forces `LIST` even on a server that advertises `MLST`.
///
/// vsftpd never advertises `MLST`, so the flag is exercised through the
/// `no-mlst` profile: the client must not discover any listing capability and
/// every entry must still parse.
async test "real server: disable_mlsd falls back to LIST" {
  guard test_server() is Some(server) else { return }
  guard server.port_no_mlst != 0 else { return }
  let client = dial(
    "\{server.host}:\{server.port_no_mlst}",
    timeout_ms=15000,
    trust_pasv_ip=true,
    disable_mlsd=true,
  )
  login(client, server.user, server.password)
  assert_false(client.is_mlst_supported())
  let entries = list(client, server.fixture)
  let names = entries.map(entry => entry.name)
  assert_true(names.contains("hello.txt"))
  assert_true(names.contains("sub"))
  quit(client)
}

///|
/// `SIZE` and `MDTM` agree with the fixture file that CI mounts.
async test "real server: SIZE and MDTM of a fixture file" {
  guard test_server() is Some(server) else { return }
  let client = connect(server)
  let path = fixture_file(server)
  assert_eq(file_size(client, path), 12UL)
  let time = get_time(client, path)
  assert_true(time.to_plain_date_time().year() >= 2020)
  quit(client)
}

///|
/// Download a fixture file and compare it with the mounted content.
async test "real server: RETR downloads the mounted fixture" {
  guard test_server() is Some(server) else { return }
  let client = connect(server)
  assert_eq(read_all(retr(client, fixture_file(server))), "hello world\n")
  quit(client)
}

///|
/// Download from a resume offset with `REST`.
async test "real server: RETR from an offset resumes the download" {
  guard test_server() is Some(server) else { return }
  let client = connect(server)
  let response = retr_from(client, fixture_file(server), offset=6L)
  assert_eq(read_all(response), "world\n")
  quit(client)
}

///|
/// `NLST` on a real vsftpd returns the names **prefixed with the requested
/// path** (`/fixture/hello.txt`), not bare names.
///
/// The old mock returned bare names, which is what `NLST` does on some other
/// daemons; asserting the vsftpd shape is the point of running against a real
/// server, since `walk` has to tolerate the prefix.
async test "real server: NLST returns path prefixed names" {
  guard test_server() is Some(server) else { return }
  let client = connect(server)
  let names = name_list(client, server.fixture)
  assert_true(names.contains(path_join(server.fixture, "hello.txt")))
  assert_true(names.contains(path_join(server.fixture, "sub")))
  quit(client)
}

///|
/// Create, enter, rename and remove a directory inside the writable area.
async test "real server: MKD, CWD, rename and RMD round trip" {
  guard test_server() is Some(server) else { return }
  let client = connect(server)
  let dir = work_path(server, "moonbit_dir")
  let renamed = work_path(server, "moonbit_dir_renamed")
  make_dir(client, dir)
  change_dir(client, dir)
  assert_true(current_dir(client).contains("moonbit_dir"))
  change_dir(client, server.root)
  rename(client, dir, renamed)
  remove_dir(client, renamed)
  quit(client)
}

///|
/// Upload a file with `STOR`, then check the size the server reports.
async test "real server: STOR uploads a file" {
  guard test_server() is Some(server) else { return }
  let client = connect(server)
  let path = work_path(server, "moonbit_upload.txt")
  let payload = "uploaded by moonbit\n"
  stor(client, path, text_reader(payload))
  assert_eq(file_size(client, path), payload.length().to_uint64())
  delete(client, path)
  quit(client)
}

///|
/// `APPE` appends to the file created by `STOR`.
async test "real server: APPE appends to an uploaded file" {
  guard test_server() is Some(server) else { return }
  let client = connect(server)
  let path = work_path(server, "moonbit_append.txt")
  let first = "first\n"
  let second = "second\n"
  stor(client, path, text_reader(first))
  append(client, path, text_reader(second))
  assert_eq(file_size(client, path), (first + second).length().to_uint64())
  assert_eq(read_all(retr(client, path)), "first\nsecond\n")
  delete(client, path)
  quit(client)
}

///|
/// A wrong password must surface as a server error, not as a hang.
async test "real server: a wrong password is rejected" {
  guard test_server() is Some(server) else { return }
  let client = dial(
    "\{server.host}:\{server.port}",
    timeout_ms=15000,
    trust_pasv_ip=true,
  )
  let rejected = try {
    login(client, server.user, "definitely-not-the-password")
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
/// A command argument carrying CRLF never reaches the wire.
///
/// The mock used to assert this by watching its own command log. A real
/// daemon cannot be asked what it received, so the assertion is the observable
/// consequence: the malicious line is refused *and* the session survives, i.e.
/// no second command was smuggled in. A regression that wrote the raw bytes
/// would leave the server waiting for the tail of an unknown command and the
/// follow up `PWD` would fail.
async test "real server: an injected command is refused and the session survives" {
  guard test_server() is Some(server) else { return }
  let client = connect(server)
  let raised = try {
    ignore(cmd(client.session.control(), "CWD /tmp\r\nDELE hello.txt"))
    None
  } catch {
    FtpError::InvalidCommand(arg~) => Some(arg)
    _ => None
  }
  assert_eq(raised, Some("CWD /tmp\r\nDELE hello.txt"))
  // The fixture file is still there, and the session still answers.
  assert_eq(file_size(client, fixture_file(server)), 12UL)
  assert_eq(current_dir(client), server.root)
  quit(client)
}

// ---------------------------------------------------------------------------
// The `no-time` profile.
// ---------------------------------------------------------------------------

///|
/// When the server refuses `MDTM` at the command level, reading a time is a
/// hard `550` and writing one raises `502`.
///
/// This replaces the old mock's `no-time` profile with a real configuration
/// switch (`cmds_denied=MDTM,MFMT`). A notable real-server finding is pinned
/// here: vsftpd keeps advertising `MDTM` in its `FEAT` list even when the
/// command is denied, so the client's `is_get_time_supported()` flag is still
/// true and the failure only shows up when the command is attempted. A client
/// that guessed the time would be available would hang; this one raises.
async test "real server: no-time profile fails the time commands cleanly" {
  guard test_server() is Some(server) else { return }
  guard server.port_no_time != 0 else { return }
  let client = connect_to(server, server.port_no_time)
  // Reading a time is a hard server error, not a silent zero.
  let read_failed = try {
    ignore(get_time(client, fixture_file(server)))
    false
  } catch {
    FtpError::ServerError(..) => true
    _ => false
  }
  assert_true(read_failed)
  // Writing a time is refused by the server too, and never silently accepted.
  let write_failed = try {
    let timestamp = new_datetime(2021, 3, 4, 5, 6, @time.utc_zone) catch {
      _ => fail("could not build the reference timestamp")
    }
    ignore(set_file_time(client, fixture_file(server), timestamp))
    false
  } catch {
    FtpError::ServerError(..) => true
    _ => false
  }
  assert_true(write_failed)
  // The session is still usable after both refusals.
  assert_eq(read_all(retr(client, fixture_file(server))), "hello world\n")
  quit(client)
}

// ---------------------------------------------------------------------------
// The `no-epsv` profile.
// ---------------------------------------------------------------------------

///|
/// When the server refuses `EPSV`, the data connection must fall back to
/// `PASV` — and keep using it for every later transfer in the same session.
///
/// This is the real server counterpart of the old mock's "EPSV returns 500"
/// case. Two transfers run back to back to prove `skip_epsv` sticks: a client
/// that retried `EPSV` on the second transfer would fail here.
async test "real server: no-epsv profile falls back to PASV and keeps it" {
  guard test_server() is Some(server) else { return }
  guard server.port_no_epsv != 0 else { return }
  let client = connect_to(server, server.port_no_epsv)
  let path = fixture_file(server)
  assert_eq(read_all(retr(client, path)), "hello world\n")
  assert_eq(read_all(retr(client, path)), "hello world\n")
  quit(client)
}

// ---------------------------------------------------------------------------
// The writable / rename round trip on the reference profile.
// ---------------------------------------------------------------------------

///|
/// Renaming a file replaces the old name with the new one.
async test "real server: rename moves a file" {
  guard test_server() is Some(server) else { return }
  let client = connect(server)
  let original = work_path(server, "moonbit_rename.txt")
  let moved = work_path(server, "moonbit_rename_moved.txt")
  stor(client, original, text_reader("rename me\n"))
  rename(client, original, moved)
  assert_eq(read_all(retr(client, moved)), "rename me\n")
  delete(client, moved)
  quit(client)
}

///|
/// Nested directories are created and removed with the real `MKD` / `RMD`
/// commands, deepest first, which is the order a recursive remove has to use.
async test "real server: nested MKD and RMD round trip" {
  guard test_server() is Some(server) else { return }
  let client = connect(server)
  let root_dir = work_path(server, "moonbit_tree")
  let nested = path_join(root_dir, "inner")
  make_dir(client, root_dir)
  make_dir(client, nested)
  stor(client, path_join(nested, "leaf.txt"), text_reader("leaf\n"))
  // The nested listing sees the uploaded file.
  let entries = list(client, nested)
  let names = entries.map(entry => entry.name)
  assert_true(names.contains("leaf.txt"))
  delete(client, path_join(nested, "leaf.txt"))
  // Deepest first: `RMD` on a non empty directory is a server error.
  remove_dir(client, nested)
  remove_dir(client, root_dir)
  quit(client)
}
