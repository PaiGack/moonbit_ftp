// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — uses the `moonbitlang/async` stack from the root moon.pkg.

///|
/// A depth-first directory tree walker, a faithful port of upstream
/// `ftp.Walker`.
///
/// The API contract matters here: `next()` returns `false` on a listing error
/// instead of raising, and the error is readable through `err()`.
pub struct Walker {
  /// The client being walked; the walker is built on top of `client`.
  client : FTPClient
  /// The entry currently being visited.
  mut cur : Entry?
  /// Path of `cur`, always as produced by `pathutil.join`.
  mut cur_path : String
  /// Pending entries; the array tail is the stack top (LIFO).
  mut stack : Array[(Entry, String)]
  /// Whether the current directory should still be expanded.
  mut descend : Bool
  /// The root path passed to `walk`, with a trailing slash.
  root : String
  /// The first failure encountered while listing, if any.
  mut walker_err : Error?
}

///|
/// Walk the directory tree rooted at `root`.
pub fn walk(client : FTPClient, root : String) -> Walker {
  let normalized = if root.has_suffix("/") { root } else { root + "/" }
  {
    client,
    cur: None,
    cur_path: "",
    stack: [],
    descend: true,
    root: normalized,
    walker_err: None,
  }
}

///|
/// The entries currently waiting on the stack, oldest first.
pub fn Walker::entries(self : Walker) -> Array[(Entry, String)] {
  self.stack
}

///|
/// Replace the pending entry stack.
pub fn Walker::set_stack(self : Walker, stack : Array[(Entry, String)]) -> Unit {
  self.stack = stack
}

///|
/// The number of entries still to visit.
pub fn Walker::pending(self : Walker) -> Int {
  self.stack.length()
}

///|
/// Push a child entry onto the walk stack.
pub fn Walker::push(self : Walker, entry : Entry, path : String) -> Unit {
  self.set_stack(append_entry(self.entries(), (entry, path)))
}

///|
/// Drop and return the most recently pushed entry, if any.
pub fn Walker::pop(self : Walker) -> (Entry, String)? {
  guard self.pending() > 0 else { return None }
  let top = self.entries()[self.pending() - 1]
  self.set_stack(drop_last(self.entries()))
  Some(top)
}

///|
/// Return a copy of `entries` with `item` appended.
fn append_entry(
  entries : Array[(Entry, String)],
  item : (Entry, String),
) -> Array[(Entry, String)] {
  let grown : Array[(Entry, String)] = []
  for entry in entries {
    grown.push(entry)
  }
  grown.push(item)
  grown
}

///|
/// Advance to the next entry, returning `false` when the walk is finished or
/// when a listing failed.
///
/// The five steps are exactly upstream's:
/// 1. initialise `cur` to a synthetic folder entry for the root,
/// 2. list `cur` when `descend` is set, recording (not raising) failures,
/// 3. push every child except `.` and `..`,
/// 4. stop when the stack is empty,
/// 5. pop the stack top, reset `descend`, return `true`.
pub async fn Walker::next(self : Walker) -> Bool {
  if self.cur is None {
    self.cur = Some(make_entry("", EntryType::Folder))
    self.cur_path = self.root
    self.descend = true
  }
  if self.descend {
    let path = self.path()
    let entries = list(self.client, path) catch {
      err => {
        self.walker_err = Some(err)
        return false
      }
    }
    for entry in entries {
      if entry.name == "." || entry.name == ".." {
        continue
      }
      self.push(entry, join(path, entry.name))
    }
  }
  match self.pop() {
    None => false
    Some(top) => {
      self.cur = Some(top.0)
      self.cur_path = top.1
      self.descend = true
      true
    }
  }
}

///|
/// Do not descend into the directory returned by the last `next()`.
pub fn Walker::skip_dir(self : Walker) -> Unit {
  self.descend = false
}

///|
/// The error that stopped the walk, if any.
pub fn Walker::err(self : Walker) -> Error? {
  self.walker_err
}

///|
/// The entry currently being visited.
pub fn Walker::stat(self : Walker) -> Entry? {
  self.cur
}

///|
/// The path of the current entry.
pub fn Walker::path(self : Walker) -> String {
  if self.cur is None {
    self.root
  } else {
    self.cur_path
  }
}

///|
/// Return a copy of `entries` without its last element, which is how the walk
/// stack is popped (LIFO on the array tail).
fn drop_last(entries : Array[(Entry, String)]) -> Array[(Entry, String)] {
  let kept : Array[(Entry, String)] = []
  for i = 0; i < entries.length() - 1; i = i + 1 {
    kept.push(entries[i])
  }
  kept
}
