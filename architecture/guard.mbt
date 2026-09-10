// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
//
// Architecture guard: the pure logic layer must stay free of any dependency
// on `moonbitlang/async`.
//
// `docs/porting/01-architecture.md` states that `types` / `status` / `error` /
// `scanner` / `parse` / `pathutil` may not import `moonbitlang/async`, because
// the async stack is still 0.x and upgrading it must not ripple into the
// parsers. The document also asks for the rule to be executable rather than a
// verbal agreement; this module is that check.

///|
/// Packages that must remain pure logic: no IO, no async, no sockets.
pub let pure_logic_packages : Array[String] = [
  "types", "status", "error", "scanner", "parse", "pathutil",
]

///|
/// The imports a pure logic package is forbidden from using.
pub let forbidden_imports : Array[String] = [
  "moonbitlang/async", "moonbitlang/async/io", "moonbitlang/async/socket", "moonbitlang/async/tls",
]

///|
/// Whether `manifest` (the contents of a `moon.pkg` file) mentions `needle`
/// as an import path.
pub fn manifest_imports(manifest : String, needle : String) -> Bool {
  for line in manifest.split("\n") {
    if line.trim().has_prefix("\"\{needle}") {
      return true
    }
  }
  false
}

///|
/// Check one manifest and return every forbidden import it uses.
pub fn violations(package_name : String, manifest : String) -> Array[String] {
  let found : Array[String] = []
  for forbidden in forbidden_imports {
    if manifest_imports(manifest, forbidden) {
      found.push("\{package_name}: \{forbidden}")
    }
  }
  found
}
