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

- `scripts/ftps/` mirrors the `scripts/*.sh` lifecycle for the encrypted case:
  `gen-cert.sh` (self-signed CA + leaf, regenerated every run and gitignored),
  `probe-ftps.sh` (`AUTH TLS` readiness handshake, verified against the CA),
  `start-ftps.sh` (the FTPS container on `127.0.0.1:2121`, endpoint written to
  `.ftp-tls.env`) and `stop-ftps.sh` (dumps logs, removes the container, never
  fails). There is no Python server: the FTPS container is `bfren/ftps`
  (Alpine + vsftpd 3.0.5) configured with `force_local_data_ssl=YES`, which is
  what makes a control-channel-only "upgrade" fail every transfer.

- **The mounted leaf certificate must be named `/ssl/vsftpd.pem`, and `/ssl`
  must stay read-only.** `bfren/ftps` hardcodes `FTPS_VSFTPD_CERT=/ssl/vsftpd.pem`
  (`10-env.nu`), skips generating a certificate only when that exact path exists
  (`13-vsftpd-ssl.nu`), and points both `rsa_cert_file` and
  `rsa_private_key_file` at it (`vsftpd.conf.esh`). A correctly shaped PEM under
  any other name is invisible, the image self-signs over the mount instead, and
  with `/ssl:ro` that write fails during `init` — `bf-init` runs
  `try { bf x $script } catch { exit 1 }`, so the container dies before vsftpd
  ever listens. The whole symptom is then a probe that retries `Connection
  refused` for the full timeout. `start-ftps.sh` runs its liveness check before
  the readiness probe for that reason, and omits `--rm` so a dead container's
  init log stays readable instead of answering `No such container`.

- `cmd/example` is the real-FTP-server smoke program: it starts a single
  `jmoyer/vsftpd` container via `scripts/start-ftp.sh`, exercises dial / login
  / list / retr / stor / rename / mkdir / walk / quit against the fixture in
  `testdata/ftp/fixture/`, and prints each step to stdout. `cmd/ftp/run.sh` is
  its entry point (a plain `moon run` wrapper, no `exec`/`--`-only indirection);
  with no arguments it falls back to the `FTP_COMMAND` in `.env`, so CI can call
  it argument-free. A failure is a hard failure — never soften it into a skip.

- `cmd/ftps` is the **FTPS end-to-end smoke test**, the encrypted counterpart of
  `cmd/example`. It takes a transport argument: `explicit` (default, `AUTH TLS`
  on a plaintext control channel, the RFC 4217 shape) or `plain` (no TLS, for
  the regression guard against the plaintext container). One binary, both
  transports, so "the fix works over TLS and does not break the clear" is a
  single verifiable claim. Its server comes from `scripts/ftps/start-ftps.sh`;
  the certificate is a self-signed CA generated per run by
  `scripts/ftps/gen-cert.sh`, mounted into the container and injected into the
  client with `trust=@tls.TrustedRoot::CustomPemFile(...)` so verification
  stays **on** — never disable it to make the test pass.

- **FTPS is the one capability whose failure mode is "the first read hangs"**,
  which no unit test and no plaintext server can reach. All four of the TLS
  bugs found so far lived in the seams: `AUTH TLS` sent without upgrading the
  socket, `PBSZ` / `PROT P` skipped for explicit TLS, implicit TLS never
  wrapping the control connection, and a TLS data connection closed without a
  `close_notify`. Before touching `dial.mbt` / `transport.mbt` /
  `control.mbt`, keep `cmd/ftps` passing.

- **The data-channel TLS handshake belongs *after* the transfer command.** The
  server does not read the data socket until it has answered `150`, so a client
  that handshakes earlier writes a `ClientHello` into a socket nobody is
  reading and real servers answer `425 Unable to build data connection` (a
  lenient stub lets it slide, which is how this stayed green while broken).
  `DataConn::start_tls` is called from `cmd_data_conn_from` after the `150` for
  exactly this reason, and `DataConn::close` sends the TLS `close_notify` before
  closing the socket. Both are load bearing.

- `scripts/ci.sh` is the single CI entry point: the whole check / test / build /
  real-server-demo / FTPS-demo / cleanup sequence. `.cnb.yml` and
  `.github/workflows/ci.yml` each have exactly one job whose only real step is
  `bash scripts/ci.sh`, so the two pipelines cannot drift apart. Do not inline
  `moon` commands, credentials or `docker run` into either pipeline, and do not
  add a per-provider copy of a script.

- The root `moon.pkg` has one plain import block (shared by the pure logic
  files, the IO files and the in-package tests, because MoonBit 0.1.20260904 has
  no per-file imports) plus a `for "wbtest"` block. The async packages therefore
  sit in the plain block on purpose; the pure logic / IO split is carried by the
  per-file `// Layer:` markers and by the grouped file tree in
  `docs/porting.md` section 2.3 (package layout).

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
