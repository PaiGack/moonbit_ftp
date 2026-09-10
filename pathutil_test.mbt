// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.

///|
test "join matches Go path.Join for the upstream cases" {
  assert_eq(join("root/", "lo"), "root/lo")
  assert_eq(join("root", "a"), "root/a")
  assert_eq(join("root", ".."), ".")
  assert_eq(join("", "a"), "a")
}

///|
test "join collapses redundant separators and dots" {
  assert_eq(join("a//b", "c"), "a/b/c")
  assert_eq(join("a", "./b"), "a/b")
  assert_eq(join("/", "a"), "/a")
  assert_eq(join_all(["a", "b", "c"]), "a/b/c")
}
