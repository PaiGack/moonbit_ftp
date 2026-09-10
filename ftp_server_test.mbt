// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

// Real FTP server end-to-end tests (track B2 of docs/porting/05-testing.md).
//
// The in-process mock cannot tell whether a command sequence is accepted by an
// actual implementation, because the mock is written to match the client. These
// tests talk to a real daemon instead: `pyftpdlib`, started by
// `.github/ftp-fixture/serve.py` from CI (GitHub Actions / CNB DinD) and from
// the CNB cloud dev environment.
//
// The tests are opt in through `FTP_TEST_*`. MoonBit has no skip API, so a
// runner without a server makes them *return early*; a bare
// `moon test --target native` therefore stays green locally. Once
// `FTP_TEST_HOST` is set every assertion is a hard failure - there is
// deliberately no "the server was flaky, skip it" path, because silently
// skipping is how the protocol bugs this file exists for would come back.
//
//   FTP_TEST_HOST=127.0.0.1     unset -> the whole file no-ops
//   FTP_TEST_PORT=2121
//   FTP_TEST_USER=test
//   FTP_TEST_PASS=test
//   FTP_TEST_FIXTURE=/fixture   read only, holds hello.txt and sub/nested.txt
//   FTP_TEST_DIR=/upload        writable, the write tests clean up after
//                               themselves

///|
/// How the environment describes the running FTP server.
struct RealServer {
  host : String
  port : Int
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
/// Read the server description, or `None` when the runner has no server
/// configured (the default outside CI).
fn real_server() -> RealServer? {
  let host = match env_string("FTP_TEST_HOST") {
    Some(host) => host
    None => return None
  }
  let port = match env_string("FTP_TEST_PORT") {
    Some(text) =>
      match parse_decimal(text) {
        Some(port) => port
        None => 21
      }
    None => 21
  }
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
  Some({ host, port, user, password, root: "/", fixture, work, })
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
/// Connect and log in to the real server.
///
/// `trust_pasv_ip` is on because the fixture daemon runs on loopback and the
/// `PASV` guard would otherwise refuse the advertised address.
async fn connect(server : RealServer) -> FTPClient {
  let client = dial(
    "\{server.host}:\{server.port}",
    timeout_ms=15000,
    trust_pasv_ip=true,
  )
  login(client, server.user, server.password)
  client
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

///|
/// The client sees the server root, so `PWD` answers `/`.
async test "real server: connect, login and PWD" {
  guard test_server() is Some(server) else { return }
  let client = connect(server)
  assert_eq(current_dir(client), server.root)
  quit(client)
}

///|
/// `FEAT` must be accepted by a real daemon, and the capabilities it
/// advertises must be reflected in the client flags.
async test "real server: FEAT negotiation reports MLST and MDTM" {
  guard test_server() is Some(server) else { return }
  let client = connect(server)
  assert_true(client.has_feature("MLST"))
  assert_true(client.is_mlst_supported())
  assert_true(client.is_get_time_supported())
  quit(client)
}

///|
/// The fixture tree is listed with `MLSD`, the daemon advertises `MLST`.
async test "real server: MLSD listing of the fixture directory" {
  guard test_server() is Some(server) else { return }
  let client = connect(server)
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
/// `LIST` parsing works against the real `ls -l` style output too.
///
/// `disable_mlsd` is used rather than `force_list_hidden` because the latter
/// sends `LIST -a <path>`, and pyftpdlib (like several other daemons) reads the
/// flag as part of the path and answers `550`. `LIST -a` itself is covered by
/// the mock server, which can accept any command.
async test "real server: LIST parsing of the fixture directory" {
  guard test_server() is Some(server) else { return }
  let client = dial(
    "\{server.host}:\{server.port}",
    timeout_ms=15000,
    trust_pasv_ip=true,
    disable_mlsd=true,
  )
  login(client, server.user, server.password)
  let entries = list(client, server.fixture)
  let names = entries.map(entry => entry.name)
  assert_true(names.contains("hello.txt"))
  assert_true(names.contains("sub"))
  for entry in entries {
    if entry.name == "hello.txt" {
      assert_eq(entry.type_, EntryType::File)
      assert_eq(entry.size, 12UL)
    }
  }
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
/// `NLST`, the bare name listing the `walk` command builds on.
async test "real server: NLST returns bare names" {
  guard test_server() is Some(server) else { return }
  let client = connect(server)
  let names = name_list(client, server.fixture)
  assert_true(names.contains("hello.txt"))
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
/// `set_file_time` writes a timestamp the server reads back.
async test "real server: MFMT and MDTM agree on the modification time" {
  guard test_server() is Some(server) else { return }
  let client = connect(server)
  let path = work_path(server, "moonbit_time.txt")
  stor(client, path, text_reader("time\n"))
  let timestamp = new_datetime(2021, 3, 4, 5, 6, @time.utc_zone) catch {
    _ => fail("could not build the reference timestamp")
  }
  set_file_time(client, path, timestamp)
  assert_eq(format_mdtm(get_time(client, path)), "20210304050600")
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
