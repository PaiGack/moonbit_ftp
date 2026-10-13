// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

///|
/// The capability-profile end-to-end test: one container, four client profiles.
///
/// `docs/porting.md` 2.6 promises four capability profiles (`full` /
/// `no-mlst` / `no-time` / `no-epsv`) against a real vsftpd, but the promise
/// was made the wrong way round. The obvious reading -- four *server*
/// configurations -- would need four containers (or four vsftpd configs
/// swapped behind one port), and it would test the image's knobs rather than
/// this client's. The profiles are therefore built **client-side**: one
/// container that advertises everything, dialled four times with different
/// `DialOptions`, so each run is the client reacting to a capability it was
/// told not to use.
///
/// That is also why the assertions are about *effects*, not command sequences.
/// A profile's whole content is "the client did the right thing when a
/// capability was unavailable", and the only honest way to see that is to
/// look at what the server ended up holding:
///
///   * `NLST` and `MDTM` are the two commands the repo advertised and never
///     called end to end; both are exercised here, read *and* write.
///   * `MDTM` write-back is asserted by reading the timestamp off the server
///     after writing it, and `no-time` asserts the refusal instead -- a
///     `502` from `set_file_time`, with the file untouched.
///   * Directory lifecycle goes through `MKD` / `RMD` and the recursive
///     `RemoveDirRecur`, with a `LIST` after each removal proving the tree is
///     really gone.
///
/// Configuration comes from the environment; `cmd/profiles/run.sh` sources
/// `.env`, and a missing variable is a hard failure -- the repo rule is no
/// silent skips.
///
/// Usage:
///   scripts/start-ftp.sh
///   cmd/profiles/run.sh
///   scripts/stop-ftp.sh
async fn main {
  if @env.args().length() > 1 {
    println("error: cmd/profiles takes no arguments")
    println(usage())
    exit(2)
  }
  let host = required_env("FTP_TEST_HOST")
  let port = required_env("FTP_TEST_PORT")
  let user = required_env("FTP_TEST_USER")
  let password = required_env("FTP_TEST_PASS")
  let addr = "\{host}:\{port}"

  for profile in profiles() {
    run_profile(profile, addr, user, password)
  }

  println("")
  println("==> OK: full / no-mlst / no-time / no-epsv all passed")
}

///|
/// The four capability profiles, in the order the porting doc lists them.
fn profiles() -> Array[String] {
  ["full", "no-mlst", "no-time", "no-epsv"]
}

///|
/// What one profile turns off, plus the label used in the log.
///
/// `disable_mlsd` / `disable_epsv` are the client's own switches: the server
/// still advertises `MLST` and `EPSV`, so the profile proves the *client*
/// honours the restriction rather than proving the server lacks a command.
struct Profile {
  what : String
  disable_mlsd : Bool
  disable_epsv : Bool
  writing_mdtm : Bool
}

///|
/// Resolve a profile name into the `DialOptions` overrides it stands for.
///
/// `writing_mdtm` is the load-bearing one, and it is on for three of the four
/// profiles for a reason: vsftpd does not implement `MFMT` (it announces
/// `MDTM` only), so the `MDTM <time> <path>` quirk is the *only* way to write
/// a timestamp against the container this runs on. `no-time` is therefore the
/// profile that turns it off, and its assertion is the `502` that results --
/// the honest degradation, not a silent no-op.
fn profile_of(name : String) -> Profile {
  match name {
    "no-mlst" =>
      {
        what: "disable_mlsd -> the client must parse LIST instead of MLSD",
        disable_mlsd: true,
        disable_epsv: false,
        writing_mdtm: true,
      }
    "no-time" =>
      {
        what: "writing_mdtm off -> set_file_time must refuse with 502",
        disable_mlsd: false,
        disable_epsv: false,
        writing_mdtm: false,
      }
    "no-epsv" =>
      {
        what: "disable_epsv -> every transfer must go through PASV",
        disable_mlsd: false,
        disable_epsv: true,
        writing_mdtm: true,
      }
    _ =>
      {
        what: "everything on: MLSD, EPSV, the MDTM write quirk",
        disable_mlsd: false,
        disable_epsv: false,
        writing_mdtm: true,
      }
  }
}

///|
/// One profile: dial, prove `FEAT`, then run the whole command surface.
///
/// The scratch paths are per profile so a leftover from a failed earlier run
/// cannot make a later one look clean, and so the "what is left on the server"
/// assertions below are about this run only.
async fn run_profile(
  name : String,
  addr : String,
  user : String,
  password : String,
) -> Unit {
  let profile = profile_of(name)
  println("")
  println("===== profile \{name}: \{profile.what} =====")
  let client = @ftp.dial(
    addr,
    timeout_ms=15000,
    disable_mlsd=profile.disable_mlsd,
    disable_epsv=profile.disable_epsv,
    writing_mdtm=profile.writing_mdtm,
    // The container answers PASV with 127.0.0.1, which is the peer we dialled,
    // so the SSRF guard is satisfied without opting out of it.
    trust_pasv_ip=true,
  )
  @ftp.login(client, user, password)
  println("    PWD: \{@ftp.current_dir(client)}")

  report_features(client)

  let scratch = "/profiles_\{(name)}"
  let file = "\{(scratch)}/sample.txt"

  // The scratch directory is created explicitly rather than assumed: the
  // container's FTP root is the fixture, so a profile that starts by
  // uploading into a directory nobody made would be refused with `550`, and
  // "the container is dirty" is not a hypothesis worth debugging.
  println("==> MKD \{scratch}")
  @ftp.make_dir(client, scratch)

  // --- upload first, so every later step has something to talk about -------
  let payload = "profiles \{name}\n"
  println("==> STOR \{file}")
  let source = @io.MemoryReader(w => w.write(payload))
  defer source.close()
  @ftp.stor(client, file, source)

  // --- LIST: MLSD for `full`, the four-parser fallback for `no-mlst` -------
  //
  // Both paths must land on the same entry, which is the point of the
  // profile: `disable_mlsd` is only meaningful if the fallback really carries
  // the same information.
  println("==> LIST \{scratch}")
  let entries = @ftp.list(client, scratch)
  let listed = find_entry(entries, "sample.txt")
  guard listed is Some(entry) else {
    raise @ftp.FtpError::ParseError(msg="LIST did not report sample.txt")
  }
  guard entry.size == payload.length().to_uint64() else {
    raise @ftp.FtpError::ParseError(
      msg="LIST reported size \{entry.size}, expected \{payload.length()}",
    )
  }
  println(
    "    MLSD path \{if @ftp.FTPClient::is_mlst_supported(client) { "on" } else { "off" }}, size \{payload.length()}",
  )

  // --- NLST: the bare-name listing, never called end to end before --------
  println("==> NLST \{scratch}")
  let names = @ftp.name_list(client, scratch)
  guard names.contains("sample.txt") else {
    raise @ftp.FtpError::ParseError(
      msg="NLST did not report sample.txt: \{format_repr(join_named(names))}",
    )
  }
  println("    NLST -> \{join_named(names)}")

  // --- RETR: the payload has to come back byte for byte -------------------
  println("==> RETR \{file}")
  let response = @ftp.retr(client, file)
  let bytes = response.reader.read_all()
  response.close()
  let downloaded = bytes.text()
  guard downloaded == payload else {
    raise @ftp.FtpError::ParseError(
      msg="RETR returned \{format_repr(downloaded)}, expected \{format_repr(payload)}",
    )
  }
  println("    RETR -> \{format_repr(downloaded)}")

  // --- MDTM read ----------------------------------------------------------
  println("==> MDTM (read) \{file}")
  let before = @ftp.get_time(client, file)
  println("    server time: \{@ftp.format_mdtm(before)}")
  println("    SIZE \{file}: \{@ftp.file_size(client, file)}")

  // --- MDTM write: the read-back is the assertion ------------------------
  check_set_time(client, name, file, before)

  // --- directory lifecycle ------------------------------------------------
  let tree = "\{scratch}/tree"
  let sub = "\{tree}/sub"
  let deep = "\{tree}/sub/deep"
  println("==> MKD \{tree} -> \{sub} -> \{deep}")
  @ftp.make_dir(client, tree)
  @ftp.make_dir(client, sub)
  @ftp.make_dir(client, deep)
  let nested = "\{deep}/nested.txt"
  let nested_payload = "nested in \{name}\n"
  let nested_source = @io.MemoryReader(w => w.write(nested_payload))
  defer nested_source.close()
  @ftp.stor(client, nested, nested_source)

  // `remove_dir` only removes an *empty* directory, so it cannot touch the
  // tree; the failing RMD is what proves the guard is still there.
  expect_empty_rmd_refused(client, tree)
  expect_empty_rmd_refused(client, sub)

  println("==> RemoveDirRecur \{tree}")
  @ftp.remove_dir_recur(client, tree)
  expect_absent(client, tree)

  // --- the scratch file, then the scratch directory -----------------------
  println("==> RMD \{scratch} while it is not empty (must be refused)")
  expect_empty_rmd_refused(client, scratch)

  println("==> DELE \{file} ; RMD \{scratch}")
  @ftp.delete(client, file)
  @ftp.remove_dir(client, scratch)
  expect_absent(client, scratch)
  let leftover = walk_paths(client)
  println("    server tree: \{join_named(leftover)}")

  @ftp.quit(client)
  println("    profile \{name}: OK")
}

///|
/// Print the negotiated `FEAT` facts, so the log says which capability set the
/// profile actually ran against rather than which one it asked for.
fn report_features(client : @ftp.FTPClient) -> Unit {
  let list = ["MLST", "MFMT", "MDTM", "UTF8"]
  let advertised : Array[String] = []
  for name in list {
    if client.has_feature(name) {
      advertised.push(name)
    }
  }
  println("==> FEAT")
  println("    advertised: \{join_named(advertised)}")
  println(
    "    mlst_supported=\{client.is_mlst_supported()} mfmt_supported=\{client.is_mfmt_supported()} mdtm_supported=\{client.is_get_time_supported()} set_time_supported=\{client.is_set_time_supported()} list_precise=\{client.is_time_precise_in_list()}",
  )
}

///|
/// Write a timestamp with `set_file_time` and assert the server reports it
/// back through `MDTM`.
///
/// The `no-time` profile is the interesting half. There is no client switch
/// for "the server has no way to write a timestamp" -- `dial` derives
/// `mfmt_supported` / `mdtm_supported` from `FEAT` -- so the profile is made
/// by taking the `full` profile's capabilities away *after* login: `MFMT`
/// dropped and `writing_mdtm` left on. `set_file_time` then has no path left
/// and must raise `502` rather than quietly not setting anything, and the
/// file's timestamp must be exactly what it was. That is the one assertion
/// that a write-time API has to be able to make.
async fn check_set_time(
  client : @ftp.FTPClient,
  profile : String,
  file : String,
  before : @time.ZonedDateTime,
) -> Unit {
  let target = @time.ZonedDateTime::of(
    2001,
    2,
    3,
    hour=4,
    minute=5,
    second=6,
    zone=@time.utc_zone,
  )
  if profile == "no-time" {
    println("==> set_file_time without MFMT and without the MDTM write quirk")
    client.set_mfmt_supported(false)
    client.set_mdtm_can_write(false)
    let refused = try {
      @ftp.set_file_time(client, file, target)
      false
    } catch {
      @ftp.FtpError::ServerError(code=502, ..) => true
      _ => false
    }
    guard refused else {
      raise @ftp.FtpError::ServerError(
        code=502,
        msg="set_file_time was expected to refuse without MFMT / writing MDTM",
      )
    }
    let after = @ftp.get_time(client, file)
    guard @ftp.format_mdtm(after) == @ftp.format_mdtm(before) else {
      raise @ftp.FtpError::ParseError(
        msg="a refused set_file_time changed the timestamp anyway: \{@ftp.format_mdtm(before)} -> \{@ftp.format_mdtm(after)}",
      )
    }
    println(
      "    refused with 502, timestamp unchanged (\{@ftp.format_mdtm(after)})",
    )
    return
  }
  // vsftpd does not implement `MFMT`, so `set_file_time` reaches it through
  // the `MDTM <time> <path>` quirk -- which only this profile (`writing_mdtm`)
  // turns on. Asserting the read-back is what makes that more than a guess.
  println("==> set_file_time \{@ftp.format_mdtm(target)}")
  guard client.is_set_time_supported() else {
    println("    server advertises neither MFMT nor MDTM; nothing to assert")
    return
  }
  @ftp.set_file_time(client, file, target)
  let after = @ftp.get_time(client, file)
  guard @ftp.format_mdtm(after) == @ftp.format_mdtm(target) else {
    raise @ftp.FtpError::ParseError(
      msg="set_file_time did not stick: wrote \{@ftp.format_mdtm(target)}, server reports \{@ftp.format_mdtm(after)}",
    )
  }
  println("    read back: \{@ftp.format_mdtm(after)}")
}

///|
/// Assert that an `RMD` on a non-empty directory is refused, and that the
/// directory survives the attempt.
///
/// `remove_dir` is the API `RemoveDirRecur` is built on, so the guard is not
/// incidental: without the refusal the recursion would be indistinguishable
/// from a plain `RMD` that happens to work.
async fn expect_empty_rmd_refused(
  client : @ftp.FTPClient,
  path : String,
) -> Unit {
  let refused = try {
    @ftp.remove_dir(client, path)
    false
  } catch {
    _ => true
  }
  guard refused else {
    raise @ftp.FtpError::ServerError(
      code=550,
      msg="RMD \{path} succeeded on a non-empty directory",
    )
  }
  guard entry_exists(client, path) else {
    raise @ftp.FtpError::ParseError(
      msg="the refused RMD removed \{path} anyway",
    )
  }
}

///|
/// Assert the server no longer holds `path`.
async fn expect_absent(client : @ftp.FTPClient, path : String) -> Unit {
  guard entry_exists(client, path) == false else {
    raise @ftp.FtpError::ParseError(msg="\{path} is still on the server")
  }
}

///|
/// Whether the parent listing reports a child called `name`.
async fn entry_exists(client : @ftp.FTPClient, path : String) -> Bool {
  let (parent, name) = split_parent(path)
  let entries = @ftp.list(client, parent)
  match find_entry(entries, name) {
    Some(_) => true
    None => false
  }
}

///|
/// Find the entry named `name`, if the listing has one.
fn find_entry(entries : Array[@ftp.Entry], name : String) -> @ftp.Entry? {
  for entry in entries {
    if entry.name == name {
      return Some(entry)
    }
  }
  None
}

///|
/// Split `path` into its parent directory and its last component.
fn split_parent(path : String) -> (String, String) {
  let mut index = -1
  for i = 0; i < path.length(); i = i + 1 {
    if path.unsafe_get(i) == '/' {
      index = i
    }
  }
  match index {
    -1 => (".", path)
    0 => ("/", path[1:].to_owned())
    _ => (path[0:index].to_owned(), path[index + 1:].to_owned())
  }
}

///|
/// Every path the server currently holds, via a full recursive walk.
///
/// Printed at the end of each profile because "the server is back to the
/// fixture and nothing else" is the effect-level statement the whole file is
/// making: any scratch file left behind shows up here.
async fn walk_paths(client : @ftp.FTPClient) -> Array[String] {
  let paths : Array[String] = []
  let walker = @ftp.walk(client, "/")
  while walker.next() {
    paths.push(walker.path())
  }
  paths
}

///|
/// Read a required environment variable. A missing one means the program was
/// not wired up, which is a failure, not something to default away.
fn required_env(name : String) -> String {
  match @env.get_env_var(name) {
    Some(value) => if value == "" { missing(name) } else { value }
    None => missing(name)
  }
}

///|
/// The usage banner, kept in one place with the doc comment above.
fn usage() -> String {
  "usage: cmd/profiles\n" +
  "  no arguments; the endpoint comes from FTP_TEST_HOST / FTP_TEST_PORT /\n" +
  "  FTP_TEST_USER / FTP_TEST_PASS, and the four profiles run in sequence."
}

///|
/// Fail about a missing environment variable in a way the compiler accepts on
/// a `String`-returning path.
fn missing(name : String) -> String {
  abort("profiles: environment variable is unset: \{name}")
}

///|
/// The C `exit`, so a usage error reports a distinct status instead of the
/// SIGABRT `abort` would produce. Mirrors `cmd/ftp`.
extern "c" fn exit(code : Int) = "exit"

///|
/// Render an array of names as `[a, b, c]`.
///
/// `Array::to_string` goes through `Show`, which the core library deprecates
/// for anything but debugging; this log line is read by a human, so it gets a
/// spelling instead of a deprecation warning.
fn join_named(values : Array[String]) -> String {
  let out = StringBuilder()
  out.write_char('[')
  for i = 0; i < values.length(); i = i + 1 {
    if i > 0 {
      out.write(", ")
    }
    out.write(values[i])
  }
  out.write_char(']')
  out.to_string()
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
