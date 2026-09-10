// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
//
// Layer inventory: which files belong to the pure logic half of the root
// package and which ones do the IO.
//
// After the layer packages were flattened into the repository root every
// source file lives in one package, and MoonBit 0.1.20260904 has no
// per-file imports, so the root `moon.pkg` necessarily names
// `moonbitlang/async` in its single plain import block. The compiler can no
// longer reject a cross layer reference, so the split is carried by two
// things instead:
//
//   1. every source file starts with a `// Layer: pure logic` or
//      `// Layer: IO` marker;
//   2. the two lists below name the files of each layer, so a reviewer has a
//      machine readable inventory instead of having to infer it from the
//      directory layout.
//
// See `docs/porting/01-architecture.md` section 3 for the rule itself.

///|
/// Pure logic modules, as `name.mbt` stems: no IO, no async, no sockets. The
/// files still live in the root package, but their contents must not reach
/// for the async stack; keeping the list explicit makes that reviewable.
pub let pure_logic_packages : Array[String] = [
  "entry", "consts", "status", "error", "scanner", "parse", "parse_rfc3659", "parse_unix_ls",
  "parse_dos_dir", "parse_hostedftp", "parse_time", "pathutil",
]

///|
/// The IO files, as `name.mbt` entries. Kept next to `pure_logic_packages` so
/// the two halves of the root package are readable at a glance.
pub let io_sources : Array[String] = [
  "control.mbt", "command.mbt", "response.mbt", "state.mbt", "transport_dataconn.mbt",
  "transport_epsv.mbt", "transport_pasv.mbt", "client.mbt", "options.mbt", "dial.mbt",
  "login.mbt", "nav.mbt", "list.mbt", "client_time.mbt", "transfer.mbt", "fsops.mbt",
  "lifecycle.mbt", "walker.mbt", "debug.mbt",
]
