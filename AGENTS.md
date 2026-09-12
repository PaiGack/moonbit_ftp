# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

You can browse and install extra skills here:
<https://github.com/moonbitlang/skills>

## Project Structure

- This repository uses a **single flat package**: every `.mbt` source file lives
  directly in the repository root and `moon.pkg` there declares the only source
  package (`PaiGack/ftp`). There are no per-directory layer packages any more,
  so symbols are referenced by bare name (`Entry`, `parse_list_line`) instead of
  `@types.Entry` / `@parse.parse_list_line`.

- `cmd/ftp/` and `cmd/example/` are separate packages: they are the CLI
  executable and the real-FTP-server demonstration. Everything else is in the
  root `PaiGack/ftp` package. Both `cmd/*/moon.pkg` declare `supported_targets
  = "+native"` because the async runtime requires it.

- Test files keep the usual naming: `*_test.mbt` (blackbox) and `*_wbtest.mbt`
  (whitebox). They live in the same root package as the code.

- `cmd/example` is the real-FTP-server smoke program: it starts a single
  `jmoyer/vsftpd` container via `scripts/start-ftp.sh`, exercises dial / login
  / list / retr / stor / rename / mkdir / walk / quit against the fixture in
  `testdata/ftp/fixture/`, and prints each step to stdout. `cmd/example/run.sh`
  and `cmd/ftp/run.sh` are its fixed, argument-free entry points. A failure is
  a hard failure — never soften it into a skip.

- `scripts/ci.sh` is the single CI entry point: the whole check / test / build /
  real-server-demo / cleanup sequence. `.cnb.yml` and
  `.github/workflows/ci.yml` each have exactly one job whose only real step is
  `bash scripts/ci.sh`, so the two pipelines cannot drift apart. Do not inline
  `moon` commands, credentials or `docker run` into either pipeline, and do not
  add a per-provider copy of a script.

- The root `moon.pkg` has one plain import block (shared by the pure logic
  files, the IO files and the in-package tests, because MoonBit 0.1.20260904 has
  no per-file imports) plus a `for "wbtest"` block. The async packages therefore
  sit in the plain block on purpose; the pure logic / IO split is carried by the
  per-file `// Layer:` markers and by the grouped file tree in
  `docs/porting/01-architecture.md` section 2.

- In the toplevel directory, there is a `moon.mod` file listing module
  metadata.

## Coding convention

- MoonBit code is organized in block style, each block is separated by `///|`,
  the order of each block is irrelevant. In some refactorings, you can process
  block by block independently.

- Try to keep deprecated blocks in file called `deprecated.mbt` in each
  directory.

## Tooling

- `moon fmt` is used to format your code properly.

- `moon ide` provides project navigation helpers like `peek-def`, `outline`, and
  `find-references`. See $moonbit-agent-guide for details.

- `moon info` is used to update the generated interface of the package, each
  package has a generated interface file `.mbti`, it is a brief formal
  description of the package. If nothing in `.mbti` changes, this means your
  change does not bring the visible changes to the external package users, it is
  typically a safe refactoring.

- In the last step, run `moon info && moon fmt` to update the interface and
  format the code. Check the diffs of `.mbti` file to see if the changes are
  expected.

- Run `moon test` to check tests pass. MoonBit supports snapshot testing; when
  changes affect outputs, run `moon test --update` to refresh snapshots.

- Prefer `assert_eq` or `assert_true(pattern is Pattern(...))` for results that
  are stable or very unlikely to change. For snapshot tests that record
  structured debugging output, derive `Debug` and use `debug_inspect`, rather
  than deriving `Show` for debugging. For solid, well-defined results (e.g.
  scientific computations), prefer assertion tests. You can use
  `moon coverage analyze > uncovered.log` to see which parts of your code are
  not covered by tests.
