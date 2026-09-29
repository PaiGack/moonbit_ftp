// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

// Tests for the depth-first walker in `walker.mbt`.
//
// The walker is a state machine over a client, so the interesting part is the
// stack discipline plus the two contracts upstream pins down: `next()` returns
// `false` (never raises) when a listing fails, and the error is readable
// through `err()`. All of it is reachable without a daemon by driving the
// walker over a scripted control channel and a real loopback data listener,
// which is what `ftp_test_helpers_wbtest.mbt` provides.

///|
/// `walk` normalises the root to a trailing slash and starts with an empty
/// stack, no current entry and no error.
///
/// The trailing slash matters: every child path is `join(root, name)`, so a
/// missing slash would produce `rootsub/` instead of `root/sub`.
async test "walk normalises the root and starts empty" {
  let (client, _) = scripted_client("")
  let bare = walk(client, "/root")
  assert_eq(bare.path(), "/root/")
  assert_eq(bare.pending(), 0)
  assert_true(bare.stat() is None)
  assert_true(bare.err() is None)

  // An already slashed root is left alone.
  let slashed = walk(client, "/root/")
  assert_eq(slashed.path(), "/root/")

  // The empty root still becomes `/`, because `"" + "/"` is `/`.
  let empty = walk(client, "")
  assert_eq(empty.path(), "/")
}

///|
/// `push` / `pop` are LIFO on the array tail, and `pop` on an empty stack
/// returns `None` instead of raising.
async test "walker push and pop are LIFO" {
  let (client, _) = scripted_client("")
  let w = walk(client, "/root")
  assert_true(w.pop() is None)

  w.push(make_file("a"), "/root/a")
  w.push(make_file("b"), "/root/b")
  w.push(make_entry("d", EntryType::Folder), "/root/d")
  assert_eq(w.pending(), 3)

  let (top, path) = match w.pop() {
    Some(top) => top
    None => fail("pop returned None")
  }
  assert_eq(top.name, "d")
  assert_eq(path, "/root/d")
  assert_eq(w.pending(), 2)

  let (top, _) = match w.pop() {
    Some(top) => top
    None => fail("pop returned None")
  }
  assert_eq(top.name, "b")
  assert_eq(w.pending(), 1)
}

///|
/// `entries` exposes the stack oldest first and `set_stack` replaces it
/// wholesale, which is how a caller primes a walk.
async test "walker entries and set_stack round-trip" {
  let (client, _) = scripted_client("")
  let w = walk(client, "/root")
  w.set_stack([(make_file("x"), "/root/x"), (make_file("y"), "/root/y")])
  let entries = w.entries()
  assert_eq(entries.length(), 2)
  assert_eq(entries[0].1, "/root/x")
  assert_eq(entries[1].1, "/root/y")
  // The tail is the top of the stack, which is what `pop` takes.
  let (top, _) = match w.pop() {
    Some(top) => top
    None => fail("pop returned None")
  }
  assert_eq(top.name, "y")
}

///|
/// `pop` alone does not move the cursor: only `next()` updates `cur`, so
/// `stat()` still reports the pre-walk state.
async test "stat is not changed by a bare pop" {
  let (client, _) = scripted_client("")
  let w = walk(client, "/root")
  assert_true(w.stat() is None)
  assert_eq(w.path(), "/root/")
  w.set_stack([(make_entry("sub", EntryType::Folder), "/root/sub")])
  ignore(w.pop())
  assert_true(w.stat() is None)
  assert_eq(w.path(), "/root/")
}

///|
/// Within one directory the walk is LIFO, not the server's listing order.
///
/// `list` pushes every child in the order the server returned them and
/// `next()` pops the tail, so the **last** listed entry is visited first. That
/// is upstream's `ftp.Walker` behaviour, and the reason a walk is not expected
/// to match `LIST` output.
///
/// The entries here are directories, not files: only folders are listed, so a
/// file would be visited without ever opening a second data connection — see
/// the dedicated test below.
async test "walker visits the children of one directory in reverse listing order" {
  let root = data_listener()
  let root_port = root.addr.port()
  let first = data_listener()
  let second = data_listener()
  let script = epsv_reply(root_port) +
    "150 Here comes the directory listing.\r\n226 Directory send OK.\r\n" +
    epsv_reply(second.addr.port()) +
    "150 Here comes the directory listing.\r\n226 Directory send OK.\r\n" +
    epsv_reply(first.addr.port()) +
    "150 Here comes the directory listing.\r\n226 Directory send OK.\r\n"
  let (client, _) = scripted_client(script, mlst_supported=true)
  let visited = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      serve_payload(root, "type=dir; a\r\ntype=dir; b\r\n")
      serve_payload(second, "")
      serve_payload(first, "")
    })
    let w = walk(client, "/root")
    let seen : Array[String] = []
    while w.next() {
      seen.push(w.path())
    }
    seen
  })
  // `b` was listed last, so it is popped first; `a` follows.
  assert_eq(visited, ["/root/b", "/root/a"])
}

///|
/// A full walk descends into every subdirectory, and `.` / `..` are dropped
/// rather than pushed.
///
/// The dot entries are what a real `MLSD` returns; filtering them is what keeps
/// a walk from looping on `..`. The listing order also shows up here: `sub` is
/// listed last in the root, so it is popped first, and its single child is
/// visited before the root's files.
async test "walker descends into subdirectories and drops dot entries" {
  let root = data_listener()
  let root_port = root.addr.port()
  let sub = data_listener()
  let sub_port = sub.addr.port()
  let top = data_listener()
  let top_port = top.addr.port()
  let script = epsv_reply(root_port) +
    "150 Here comes the directory listing.\r\n226 Directory send OK.\r\n" +
    epsv_reply(top_port) +
    "150 Here comes the directory listing.\r\n226 Directory send OK.\r\n" +
    epsv_reply(sub_port) +
    "150 Here comes the directory listing.\r\n226 Directory send OK.\r\n"
  let (client, sink) = scripted_client(script, mlst_supported=true)
  let visited = @async.with_task_group(async fn(group) {
    // Each listener accepts exactly one connection, and the walker opens them
    // in its own order, so every server task runs concurrently.
    group.spawn_bg(no_wait=true, async fn() {
      serve_payload(
        root, "type=dir; .\r\ntype=dir; ..\r\ntype=dir; sub\r\ntype=dir; top\r\n",
      )
    })
    group.spawn_bg(no_wait=true, async fn() {
      serve_payload(sub, "type=file; nested.txt\r\n")
    })
    group.spawn_bg(no_wait=true, async fn() { serve_payload(top, "") })
    let w = walk(client, "/root")
    let seen : Array[String] = []
    while w.next() {
      seen.push(w.path())
    }
    seen
  })
  assert_eq(visited, ["/root/top", "/root/sub", "/root/sub/nested.txt"])
  // The root is listed with the trailing slash from `walk`; the child paths
  // lose it because `join("/root/", "sub")` drops the separator. Only folders
  // are listed: `top` and `sub` each get an `MLSD`, and `nested.txt` — a
  // *file* — is visited but never listed, so no fourth `EPSV` follows.
  assert_eq(sink.lines, [
    "EPSV", "MLSD /root/", "EPSV", "MLSD /root/top", "EPSV", "MLSD /root/sub",
  ])
}

///|
/// `skip_dir` clears the descend flag for the entry just returned, so its
/// children are never listed.
///
/// The command list is the proof: `sub` is listed last in the root, so it is
/// popped first; skipping it means no second `MLSD` ever reaches the wire.
async test "skip_dir stops the descend into the current directory" {
  let root = data_listener()
  let root_port = root.addr.port()
  let script = epsv_reply(root_port) +
    "150 Here comes the directory listing.\r\n226 Directory send OK.\r\n"
  let (client, sink) = scripted_client(script, mlst_supported=true)
  let visited = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      serve_payload(root, "type=dir; sub\r\n")
    })
    let w = walk(client, "/root")
    let seen : Array[String] = []
    while w.next() {
      seen.push(w.path())
      if w.stat() is Some(entry) && entry.name == "sub" {
        w.skip_dir()
      }
    }
    seen
  })
  // `sub` is the only entry, so the walk ends as soon as it is skipped.
  assert_eq(visited, ["/root/sub"])
  assert_eq(sink.lines, ["EPSV", "MLSD /root/"])
}

///|
/// `next()` reports a listing failure as `false` and stores the error, which
/// `err()` then returns — the walk never raises.
async test "next returns false and records the error when a listing fails" {
  // `EPSV` points at a port nobody listens on, so the connect fails and the
  // session falls back to `PASV`; the `500` then fails the listing.
  let script = epsv_reply(9) + "500 PASV not understood.\r\n"
  let (client, _) = scripted_client(script)
  let w = walk(client, "/root")
  assert_false(w.next())
  // `err()` returns whatever stopped the walk: connecting to a closed port
  // fails, the `PASV` fallback is refused with `500`, and the listing therefore
  // has no data connection.
  assert_true(w.err() is Some(_))
  // A second `next()` stays `false`: the walk does not recover on its own.
  assert_false(w.next())
}

///|
/// A walk whose root listing succeeds but whose child listing fails keeps the
/// entries it already visited and reports the failure through `err()`.
async test "walker keeps the visited entries when a nested listing fails" {
  let root = data_listener()
  let root_port = root.addr.port()
  // The second listing is scripted to fail: `EPSV` points nowhere and the
  // `PASV` fallback is refused.
  let script = epsv_reply(root_port) +
    "150 Here comes the directory listing.\r\n226 Directory send OK.\r\n" +
    epsv_reply(9) +
    "500 No such directory.\r\n"
  let (client, _) = scripted_client(script, mlst_supported=true)
  let (visited, had_error) = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      // Only the root listing is served; the `sub` listing never gets far
      // enough to open a data connection.
      serve_payload(root, "type=file; top.txt\r\ntype=dir; sub\r\n")
    })
    let w = walk(client, "/root")
    let seen : Array[String] = []
    while w.next() {
      seen.push(w.path())
    }
    (seen, w.err() is Some(_))
  })
  // `sub` is listed last, so it is popped first; its own listing fails and the
  // walk stops there, which is why `top.txt` never shows up.
  assert_eq(visited, ["/root/sub"])
  assert_true(had_error)
}

///|
/// A walk visits file entries but never lists them: only folders are descended
/// into.
///
/// That is upstream `ftp.Walker` behaviour — `Next` guards its listing with
/// `w.cur.entry.Type == EntryTypeFolder`. The guard is what lets a walk of a
/// real tree finish cleanly: without it the walker would `LIST` every file it
/// pops, and a server that refuses to list a file (the common case) would turn
/// an ordinary tree into a recorded error at the very end.
async test "walker visits file entries without listing them" {
  let root = data_listener()
  let root_port = root.addr.port()
  let script = epsv_reply(root_port) +
    "150 Here comes the directory listing.\r\n226 Directory send OK.\r\n"
  let (client, sink) = scripted_client(script, mlst_supported=true)
  let (visited, had_error) = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      serve_payload(root, "type=file; a.txt\r\n")
    })
    let w = walk(client, "/root")
    let seen : Array[String] = []
    while w.next() {
      seen.push(w.path())
    }
    (seen, w.err() is Some(_))
  })
  assert_eq(visited, ["/root/a.txt"])
  assert_false(had_error)
  // The file is visited but never listed: exactly one listing reached the wire,
  // the root one, and no second `EPSV`/`MLSD /root/a.txt` follows.
  assert_eq(sink.lines, ["EPSV", "MLSD /root/"])
}

///|
/// The walker builds child paths itself instead of sending `CWD`, so a walk
/// costs one listing per directory and nothing else.
async test "walker never sends CWD or PWD" {
  let root = data_listener()
  let root_port = root.addr.port()
  let script = epsv_reply(root_port) +
    "150 Here comes the directory listing.\r\n226 Directory send OK.\r\n"
  let (client, sink) = scripted_client(script, mlst_supported=true)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      // A directory that is skipped, so the walk touches exactly one listing.
      serve_payload(root, "type=dir; only\r\n")
    })
    let w = walk(client, "/root")
    while w.next() {
      w.skip_dir()
    }
    ()
  })
  assert_eq(sink.lines, ["EPSV", "MLSD /root/"])
  assert_false(sink.lines.contains("CWD /root/"))
  assert_false(sink.lines.contains("PWD"))
}
