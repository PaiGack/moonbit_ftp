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
  `probe-ftps-selftest.py` (runs that probe against a docker-free mock),
  `ftp_mock.py` (the plaintext FTP mock those docker-free checks drive the real
  binaries against), `cmd-ftps-selftest.py` (runs `cmd/ftps plain` against that
  mock), `fixture-isolation-selftest.py` (asserts the two containers do not
  share a writable fixture), `start-ftps.sh` (the FTPS container on `127.0.0.1:2121`, endpoint
  written to `.ftp-tls.env`) and `stop-ftps.sh` (dumps logs, removes the
  container, never fails). The FTPS container is `bfren/ftps` (Alpine + vsftpd
  3.0.5) configured with `force_local_data_ssl=YES`, which is what makes a
  control-channel-only "upgrade" fail every transfer.

- **`probe-ftps.sh` must be tested against a mock, not only via the container.**
  It is a gate whose failure mode is "says unhealthy about a healthy server", so
  its bugs make CI fail *on success* and surface as a downstream symptom: the
  probe fails, `start-ftps.sh` fails, `.ftp-tls.env` is never written, and both
  `cmd/ftps/run.sh` calls die on the missing file — which reads like a TLS bug
  while the FTPS assertions never ran at all. Two such bugs have already shipped
  once each, both invisible to `bash -n` and to any real-server run:
  `openssl s_client` never exits by itself, so a *successful* login looked like
  a timeout inside the retry loop; and `-quiet` writes server replies to stderr,
  so the `grep '^230 '` on the captured stdout could never match. Hence
  `timeout` around `s_client`, `2>&1` on the capture, and
  `probe-ftps-selftest.py` in `scripts/ci.sh` before any Docker step.

- **Each container gets its own copy of `testdata/ftp/fixture`; never mount the
  checked-in directory into both.** The FTP home has to be writable (the smoke
  tests upload into it) and the two images treat it differently: `bfren/ftps`
  runs `11-user.nu` "Ensuring user test owns /files" and `chown`s whatever is
  mounted at `/files`, while `jmoyer/vsftpd` mounts the same tree as its own
  user's home. Pointing both starters at `testdata/ftp/fixture` therefore makes
  whichever server starts second unable to write, and vsftpd says so with
  `553 Could not create file.` -- in `cmd/ftps/run.sh plain`, i.e. a failure
  that reads like a plaintext-transport regression and has nothing to do with
  TLS. It also dirties the working tree as a side effect. `scripts/start-ftp.sh`
  and `scripts/ftps/start-ftps.sh` each `cp -R` the fixture into their own
  gitignored `.ftp-plain-root/` / `.ftp-ftps-files/`, `chmod -R a+rwX` it, and
  their `stop-*.sh` counterparts `rm -rf` it, so a run cannot inherit a
  root-owned leftover from the one before it. Do not "simplify" this back to a
  single shared mount.

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

- **A `@io.MemoryReader` passed inline has no owner, and that is a deadlock.**
  The reader spawns a background producer task; the only way to stop it is
  `MemoryReader::close`. Build one as a temporary at a call site (`f(MemoryReader(...))`)
  and nothing ever closes it, so the event loop can end with that task still
  alive. The symptom is not a leak report but a deadlock panic from
  `@moonbitlang/async`, naming the line of the argument and nothing else:

  ```
  Dead lock detected. Tasks spawned at the following locations are still alive:
  ["cmd/ftps/main.mbt:202:30-202:70@PaiGack/ftp"]
  ```

  It only fires when the consumer *stops early* — a transfer the server rejects,
  a raised error before the pipe drains — so it hides on the happy path and in
  every unit test. `cmd/ftps` hit it: its `STOR` call built the reader inline, so
  a refused `STOR` panicked instead of reporting the error, and the whole FTPS
  block of `scripts/ci.sh` looked like a TLS bug. Bind the reader to a name and
  `defer reader.close()`, as `cmd/ftps` now does.

- **`scripts/ftps/cmd-ftps-selftest.py` runs `cmd/ftps` without Docker**, which
  is where that deadlock is caught. `scripts/ftps/ftp_mock.py` is a plaintext
  FTP mock on ephemeral ports; the self-test drives the real binary against it
  twice, once with every transfer served and once with `STOR` refused. The
  refused case is the regression guard: on the buggy code it reproduces the
  exact CI deadlock, and it runs in `scripts/ci.sh` *before* any image is
  pulled. The same rule as `probe-ftps.sh` applies — if `cmd/ftps` breaks, the
  gate should say so, not the container log.

- **The two containers must not share the fixture directory.** `bfren/ftps`'s
  `11-user.nu` runs `bf ch --owner "test:test" --recurse $files` over `/files`
  at init, with `FTPS_VSFTPD_UID` defaulting to 1000. `/files` is a bind mount,
  so that recursive chown rewrites the *host* tree — and `scripts/start-ftp.sh`
  mounts the same `testdata/ftp/fixture` directory as its FTP root, where the
  virtual user maps to the image's `ftp` (uid 100). Once the FTPS container has
  started, the plaintext container can no longer write there and its `STOR` is
  refused with `550`. That is why `cmd/ftps/run.sh plain` fails *after*
  `start-ftps.sh` has run while `cmd/example` — which runs before it — passes on
  the same container. `start-ftps.sh` therefore mounts a per-run **copy** under
  `testdata/ftp/ftps-fixture` (gitignored, rebuilt every run, removed by
  `stop-ftps.sh`), so the chown can only ever touch the throwaway tree.

- **FTPS is the one capability whose failure mode is "the first read hangs"**,
  which no unit test and no plaintext server can reach. All four of the TLS
  bugs found so far lived in the seams: `AUTH TLS` sent without upgrading the
  socket, `PBSZ` / `PROT P` skipped for explicit TLS, implicit TLS never
  wrapping the control connection, and a TLS data connection closed without a
  `close_notify`. Before touching `dial.mbt` / `transport.mbt` /
  `control.mbt`, keep `cmd/ftps` passing.

- **The readiness probe judges the transcript, never `openssl`'s exit code.**
  vsftpd closes the control socket after `QUIT` without a TLS `close_notify`,
  so `openssl s_client` exits 1 with `ssl3_read_n:unexpected eof while reading`
  *after* a successful `230 Login successful.`. `probe-ftps.sh` therefore
  captures with `|| true` and passes only on a `230` seen in the output; keying
  off the exit status made the gate reject a healthy server and retry until the
  timeout, printing the *successful* handshake as the "last error". A probe that
  fails must print the whole transcript — truncating it to the last line is what
  turned that into a wild goose chase.

- **The data-channel TLS handshake belongs *after* the transfer command.** The
  server does not read the data socket until it has answered `150`, so a client
  that handshakes earlier writes a `ClientHello` into a socket nobody is
  reading and real servers answer `425 Unable to build data connection` (a
  lenient stub lets it slide, which is how this stayed green while broken).
  `DataConn::start_tls` is called from `cmd_data_conn_from` after the `150` for
  exactly this reason, and `DataConn::close` sends the TLS `close_notify` before
  closing the socket. Both are load bearing.

- **A reply read must have a deadline, or the async runtime calls the wait a
  deadlock.** `EventLoop::check_dead_lock` fires as soon as the loop has no
  ready task and no pending timer, and a suspended socket read counts as "no
  ready task" — so an unbounded `Control::read_line` on a server that is merely
  slow (a real ftpd answers `150` only *after* it accepted the data
  connection) aborts the process with `Dead lock detected`, naming whichever
  *unrelated* task happened to be parked. That is how a plain `STOR` came to be
  blamed on the `@io.MemoryReader` two files away in `cmd/ftps/main.mbt`.
  `Control` therefore carries a `timeout_ms` and `read_line` raises
  `FtpError::RequestTimeout`; keep the deadline on, and keep `timeout_ms` out
  of the `FtpError` collapse in `cmd_data_conn_from` — a swallowed error turns
  a silent server into the same "transfer command failed" as a `550`.

- **A `MemoryReader` passed to `stor` / `append` must be closed by the caller.**
  `stor` only drains the source once the server accepted the transfer, so a
  refused or unanswered command leaves the producer parked on a pipe nobody
  reads. The parked task then trips the deadlock check at process exit, which
  is the same misleading abort as above. `cmd/ftps` closes its reader in a
  `defer`; tests use `failing_source()` or call `.close()`.

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
