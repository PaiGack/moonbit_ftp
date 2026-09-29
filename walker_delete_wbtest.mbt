// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

// A walk is a *lazy* traversal: `next()` lists one directory at a time and
// keeps the rest on its stack, so the walk is still opening data connections
// long after the first entry was handed to the caller.
//
// That is why the README example deletes what it uploaded **after** the walk
// loop, not before. `list` is all-or-nothing — `list.mbt` reads the whole
// payload and only then raises `join_errors` — so a live `DELE` that made a
// directory unreadable would surface as `next()` going `false` with `err()`
// set, i.e. a silently truncated walk. These tests pin the ordering down so the
// example cannot drift back.

///|
/// The walk stays usable while its own upload is still on the server: deleting
/// nothing mid-walk leaves the tree readable and `err()` empty.
///
/// This is the "after the traversal" half of the example: `renamed` exists for
/// every `next()` call, so the walk finishes normally.
async test "a walk completes while the uploaded file is still present" {
  let root = data_listener()
  let root_port = root.addr.port()
  let sub = data_listener()
  let script = epsv_reply(root_port) +
    "150 Here comes the directory listing.\r\n226 Directory send OK.\r\n" +
    epsv_reply(sub.addr.port()) +
    "150 Here comes the directory listing.\r\n226 Directory send OK.\r\n"
  let (client, sink) = scripted_client(script, mlst_supported=true)
  let (visited, had_error) = @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      // The upload sits in the root, so it shows up in the first listing.
      serve_payload(
        root, "type=dir; newdir\r\ntype=file; upload_renamed.txt\r\n",
      )
    })
    group.spawn_bg(no_wait=true, async fn() { serve_payload(sub, "") })
    let w = walk(client, "/")
    let seen : Array[String] = []
    while w.next() {
      seen.push(w.path())
    }
    (seen, w.err() is Some(_))
  })
  assert_eq(visited, ["/upload_renamed.txt", "/newdir"])
  assert_false(had_error)
  // No `DELE` reached the wire: the walk and the cleanup are separate steps.
  assert_false(sink.lines.contains("DELE /upload_renamed.txt"))
}

///|
/// The counter-example that motivates the ordering: a `DELE` issued mid-walk
/// goes out **between** two listings, so the walker is traversing a tree that
/// is changing underneath it.
///
/// The scripted control channel proves the interleaving rather than pretending
/// to model a server's reaction: `DELE` lands after the root `MLSD` and before
/// the `newdir` one. A server that answers that `MLSD` with an error turns the
/// deletion into a truncated walk — `next()` returns `false` and the failure
/// only shows up in `err()`.
async test "deleting mid-walk lands between two listings" {
  let root = data_listener()
  let root_port = root.addr.port()
  let script = epsv_reply(root_port) +
    "150 Here comes the directory listing.\r\n226 Directory send OK.\r\n" +
    "250 DELE ok.\r\n" +
    // The walk continues from here; this listing is never requested because
    // the test stops after the first entry.
    epsv_reply(9) +
    "500 No such directory.\r\n"
  let (client, sink) = scripted_client(script, mlst_supported=true)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      serve_payload(root, "type=dir; newdir\r\ntype=file; upload.txt\r\n")
    })
    let w = walk(client, "/")
    assert_true(w.next())
    assert_eq(w.path(), "/upload.txt")
    delete(client, "/upload.txt")
    // The cleanup went out while the walker still has `newdir` queued.
    assert_eq(w.pending(), 1)
    assert_eq(sink.lines, ["EPSV", "MLSD /", "DELE /upload.txt"])
  })
}
