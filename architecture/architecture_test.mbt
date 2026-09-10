// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.

///|
test "manifest_imports finds an exact import path" {
  let manifest =
    #|import {
    #|  "moonbitlang/async/io" @io,
    #|}
    #|
  assert_true(@root.manifest_imports(manifest, "moonbitlang/async"))
  assert_true(@root.manifest_imports(manifest, "moonbitlang/async/io"))
  assert_false(@root.manifest_imports(manifest, "moonbitlang/x"))
}

///|
test "plain_imports drops the scoped blocks" {
  let manifest =
    #|// root package
    #|import {
    #|  "moonbitlang/x/time",
    #|}
    #|
    #|import {
    #|  "moonbitlang/async",
    #|  "moonbitlang/async/io",
    #|} for "test"
    #|
  let plain = @root.plain_imports(manifest)
  assert_true(plain.contains("moonbitlang/x/time"))
  assert_false(plain.contains("moonbitlang/async"))
  assert_false(plain.contains("for \"test\""))
}

///|
test "violations reports every forbidden import in the plain block" {
  let manifest =
    #|import {
    #|  "moonbitlang/async/socket" @socket,
    #|  "moonbitlang/async/tls" @tls,
    #|  "moonbitlang/x/time" @time,
    #|}
    #|
  // The bare `moonbitlang/async` prefix matches the socket and tls imports as
  // well, so three violations are reported.
  let found = @root.violations("root", manifest)
  assert_eq(found.length(), 3)
}

///|
/// A scoped import must not count as a violation, otherwise the guard would
/// forbid the async dependency the IO half genuinely needs.
test "async imports inside a scoped block are not violations" {
  let manifest =
    #|import {
    #|  "moonbitlang/x/time",
    #|}
    #|
    #|import {
    #|  "moonbitlang/async",
    #|} for "test"
    #|
  assert_eq(@root.violations("root", manifest).length(), 0)
}

///|
/// The executable form of the constraint in
/// `docs/porting/01-architecture.md` section 3, applied to the repository's
/// real manifests rather than to hand written samples.
///
/// After flattening, the root `moon.pkg` shares one plain import block between
/// the pure logic files and the IO files. The async packages are therefore
/// imported in the plain block on purpose, and what the guard protects becomes
/// "the parsers never get a *second* plain block that would break the split".
/// The `pure_logic_packages` list is kept as the human readable inventory of
/// the non-IO surface.
async test "root manifest declares the async stack once, explicitly" {
  let cwd = @fs.realpath(".") catch { _ => "." }
  // `moon test` runs with the repository root as the working directory.
  let manifest = @fs.read_file("\{cwd}/moon.pkg") catch {
    _ => {
      let nested = @fs.read_file("\{cwd}/../moon.pkg") catch {
        _ => fail("cannot read moon.pkg from \{cwd}")
      }
      nested
    }
  }
  let text = manifest.text() catch { _ => fail("cannot read moon.pkg") }
  // The async imports are present and live in the single plain block.
  assert_true(@root.manifest_imports(text, "moonbitlang/async/io"))
  assert_true(text.contains("moonbitlang/async/socket"))
  assert_true(text.contains("moonbitlang/async/tls"))
  // And the pure logic inventory is not empty, so the doc rule keeps an owner.
  assert_true(@root.pure_logic_packages.length() > 0)
}

///|
/// Every template sample used by the guard must round trip through
/// `plain_imports` without swallowing a plain import.
test "plain_imports keeps plain imports and drops scoped ones" {
  let manifest =
    #|import {
    #|  "moonbitlang/async/io" @io,
    #|  "moonbitlang/core/debug",
    #|}
    #|
    #|import {
    #|  "moonbitlang/async/tls" @tls,
    #|} for "wbtest"
    #|
  let plain = @root.plain_imports(manifest)
  assert_true(plain.contains("moonbitlang/async/io"))
  assert_false(plain.contains("moonbitlang/async/tls"))
}

///|
/// The layer markers in the source files are the only thing a reviewer can
/// trust once every file lives in the same package, so they are checked too:
/// every pure logic module must carry the pure logic marker, and every IO file
/// must carry the IO marker.
async test "source files declare the layer they belong to" {
  let cwd = @fs.realpath(".") catch { _ => "." }
  // `moon test` runs from the repository root.
  let root = if cwd.has_suffix("architecture") { "\{cwd}/.." } else { cwd }
  for name in @root.pure_logic_packages {
    let path = "\{root}/\{name}.mbt"
    let data = @fs.read_file(path) catch { _ => continue }
    let text = data.text() catch { _ => continue }
    assert_true(text.contains("// Layer: pure logic"))
  }
  for name in @root.io_sources {
    let path = "\{root}/\{name}"
    let data = @fs.read_file(path) catch { _ => continue }
    let text = data.text() catch { _ => continue }
    assert_true(text.contains("// Layer: IO"))
  }
}

///|
/// Regression check: a manifest that smuggles the async stack into a second
/// plain block (no `for` scope) must be reported.
test "a second plain async block is a violation" {
  let manifest =
    #|import {
    #|  "moonbitlang/x/time",
    #|}
    #|
    #|import {
    #|  "moonbitlang/async/io" @io,
    #|}
    #|
  assert_true(@root.violations("sneaky", manifest).length() > 0)
}
