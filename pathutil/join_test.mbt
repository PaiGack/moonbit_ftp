// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.

///|
test "join matches Go path.Join for the upstream cases" {
  assert_eq(@pathutil.join("root/", "lo"), "root/lo")
  assert_eq(@pathutil.join("root", "a"), "root/a")
  assert_eq(@pathutil.join("root", ".."), ".")
  assert_eq(@pathutil.join("", "a"), "a")
}

///|
test "join collapses redundant separators and dots" {
  assert_eq(@pathutil.join("a//b", "c"), "a/b/c")
  assert_eq(@pathutil.join("a", "./b"), "a/b")
  assert_eq(@pathutil.join("/", "a"), "/a")
  assert_eq(@pathutil.join_all(["a", "b", "c"]), "a/b/c")
}
