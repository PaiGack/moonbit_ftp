// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.

///|
test "manifest_imports finds an exact import path" {
  let manifest =
    #|import {
    #|  "moonbitlang/async/io" @io,
    #|}
    #|
  assert_true(@architecture.manifest_imports(manifest, "moonbitlang/async"))
  assert_true(@architecture.manifest_imports(manifest, "moonbitlang/async/io"))
  assert_false(@architecture.manifest_imports(manifest, "moonbitlang/x"))
}

///|
test "violations reports every forbidden import" {
  let manifest =
    #|import {
    #|  "moonbitlang/async/socket" @socket,
    #|  "moonbitlang/async/tls" @tls,
    #|  "moonbitlang/x/time" @time,
    #|}
    #|
  // The bare `moonbitlang/async` prefix matches the socket and tls imports
  // as well, so three violations are reported.
  let found = @architecture.violations("parse", manifest)
  assert_eq(found.length(), 3)
}

///|
/// Walk every pure logic package and assert its `moon.pkg` is async free.
///
/// This is the executable form of the constraint in
/// `docs/porting/01-architecture.md` section 3.
async test "pure logic packages never import moonbitlang/async" {
  let root = @fs.realpath(".") catch { _ => "." }
  for name in @architecture.pure_logic_packages {
    let manifest_path = "\{root}/\{name}/moon.pkg"
    let manifest = @fs.read_file(manifest_path) catch { _ => continue }
    let text = manifest.text() catch { _ => continue }
    let found = @architecture.violations(name, text)
    assert_true(found.length() == 0)
  }
}
