// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
//
// Ported from jlaffaye/ftp `scanner_test.go`.

///|
test "scanner walks fields and keeps the separator in remaining" {
  let scanner = @scanner.Scanner::new("foo  bar x  y")
  assert_eq(scanner.next(), "foo")
  assert_eq(scanner.remaining(), " bar x  y")
  assert_eq(scanner.next(), "bar")
  assert_eq(scanner.remaining(), "x  y")
  assert_eq(scanner.next(), "x")
  assert_eq(scanner.remaining(), " y")
  assert_eq(scanner.next(), "y")
  assert_eq(scanner.next(), "")
  assert_eq(scanner.remaining(), "")
}

///|
test "scanner on an empty input yields empty fields" {
  let scanner = @scanner.Scanner::new("")
  assert_eq(scanner.next(), "")
  assert_eq(scanner.next(), "")
  assert_eq(scanner.remaining(), "")
}

///|
test "scanner next_fields stops without raising when input runs out" {
  let scanner = @scanner.Scanner::new("a b")
  assert_eq(scanner.next_fields(5), ["a", "b"])
}

///|
test "scanner tolerates a leading run of spaces" {
  let scanner = @scanner.Scanner::new("   a b")
  assert_eq(scanner.next(), "a")
  assert_eq(scanner.next(), "b")
  assert_eq(scanner.next(), "")
}
