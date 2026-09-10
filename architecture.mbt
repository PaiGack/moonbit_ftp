// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
//
// Architecture guard: the pure logic half of the root package must stay free
// of any dependency on `moonbitlang/async`.
//
// `docs/porting/01-architecture.md` states that `types` / `status` / `error` /
// `scanner` / `parse` / `pathutil` may not import `moonbitlang/async`, because
// the async stack is still 0.x and upgrading it must not ripple into the
// parsers. The document also asks for the rule to be executable rather than a
// verbal agreement; this module is that check.
//
// After the packages were flattened into the repository root, all sources
// share one `moon.pkg`, so the rule is checked on the **manifest** instead of
// on directories:
//
//   1. the root manifest must keep exactly one plain import block and it must
//      not name an async package;
//   2. the async packages are allowed only in the `for "test"` / `for "wbtest"`
//      scopes, which are not linked into the production build.
//
// `plain_imports` does the block splitting, so the check stays honest even if
// someone adds a new scoped block later.

///|
/// Module names that are pure logic: no IO, no async, no sockets. A name still
/// appears here even though the modules now live in the root package, because
/// the same names are used by the guard below and by the docs.
pub let pure_logic_packages : Array[String] = [
  "entry", "consts", "status", "error", "scanner", "parse", "parse_rfc3659", "parse_unix_ls",
  "parse_dos_dir", "parse_hostedftp", "parse_time", "pathutil",
]

///|
/// The IO files, as `name.mbt` entries. Kept explicit and checked against the
/// `// Layer: IO` marker so the split stays machine readable after flattening.
pub let io_sources : Array[String] = [
  "control.mbt", "command.mbt", "response.mbt", "state.mbt", "transport_dataconn.mbt",
  "transport_epsv.mbt", "transport_pasv.mbt", "client.mbt", "options.mbt", "dial.mbt",
  "login.mbt", "nav.mbt", "list.mbt", "client_time.mbt", "transfer.mbt", "fsops.mbt",
  "lifecycle.mbt", "walker.mbt", "debug.mbt",
]

///|
/// Packages that may never appear in the plain (non-scoped) import block of a
/// manifest: importing them there would pull the async stack into the pure
/// logic files.
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
/// Return the part of a `moon.pkg` manifest that is **not** scoped: the lines
/// before the first `import { ... } for "scope"` block, plus the body of the
/// plain `import { ... }` block. Lines belonging to a `for "test"` or
/// `for "wbtest"` block are dropped, which is what makes the guard meaningful
/// after flattening.
pub fn plain_imports(manifest : String) -> String {
  let lines = manifest.split("\n").collect()
  let kept : Array[String] = []
  let mut i = 0
  let n = lines.length()
  while i < n {
    let line = lines[i].trim()
    if line.has_prefix("import {") {
      // Find where this block ends so the whole block can be classified by
      // its closing line before any of its body is kept.
      let mut j = i + 1
      let body : Array[String] = []
      let mut scoped = false
      while j < n {
        let inner = lines[j].trim()
        if inner == "}" {
          break
        }
        if inner.has_prefix("} for ") {
          scoped = true
          break
        }
        body.push(inner.to_owned())
        j = j + 1
      }
      if !scoped {
        for entry in body {
          kept.push(entry)
        }
      }
      i = j + 1
      continue
    }
    i = i + 1
  }
  kept.join("\n")
}

///|
/// Check one manifest's plain import block and return every forbidden import
/// it uses.
pub fn violations(package_name : String, manifest : String) -> Array[String] {
  let plain = plain_imports(manifest)
  let found : Array[String] = []
  for forbidden in forbidden_imports {
    if manifest_imports(plain, forbidden) {
      found.push("\{package_name}: \{forbidden}")
    }
  }
  found
}
