// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.

///|
test "join matches Go path.Join for the upstream cases" {
  assert_eq(@ftp.join("root/", "lo"), "root/lo")
  assert_eq(@ftp.join("root", "a"), "root/a")
  assert_eq(@ftp.join("root", ".."), ".")
  assert_eq(@ftp.join("", "a"), "a")
}

///|
test "join collapses redundant separators and dots" {
  assert_eq(@ftp.join("a//b", "c"), "a/b/c")
  assert_eq(@ftp.join("a", "./b"), "a/b")
  assert_eq(@ftp.join("/", "a"), "/a")
  assert_eq(@ftp.join_all(["a", "b", "c"]), "a/b/c")
}

///|
/// `..` that would escape the root is *kept*, matching Go's `path.Clean`: the
/// client must not silently rewrite a relative path into a different one.
test "join keeps a leading .. that cannot be popped" {
  assert_eq(@ftp.join("..", "a"), "../a")
  assert_eq(@ftp.join_all(["..", "..", "a"]), "../../a")
  assert_eq(@ftp.join_all(["a", "..", "..", "b"]), "../b")
  // A `..` after a real segment still pops it.
  assert_eq(@ftp.join_all(["a", "b", "..", "c"]), "a/c")
  assert_eq(@ftp.join_all(["a", "..", ".."]), "..")
}

///|
/// Every input that collapses to nothing yields `.`, never an empty string:
/// the path is always usable as a `CWD` / `LIST` argument.
test "join collapses an empty result to a dot" {
  assert_eq(@ftp.join_all([]), ".")
  assert_eq(@ftp.join_all([""]), ".")
  assert_eq(@ftp.join_all([".", "."]), ".")
  assert_eq(@ftp.join("a", ".."), ".")
}

///|
/// A leading slash is significant only for the *first* non-empty part, which
/// is what `path.Join` does and what keeps a relative path relative.
test "join keeps a leading slash only for the first part" {
  assert_eq(@ftp.join_all(["/a", "b"]), "/a/b")
  assert_eq(@ftp.join("/a", "b"), "/a/b")
  assert_eq(@ftp.join_all(["", "/a", "b"]), "/a/b")
  assert_eq(@ftp.join_all(["a", "/b"]), "a/b")
}
