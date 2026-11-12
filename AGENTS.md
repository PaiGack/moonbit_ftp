# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

You can browse and install extra skills here:
<https://github.com/moonbitlang/skills>

## 重要
- 永远使用中文回复
- 永远使用 read/wite 读写文档，代码等文件

## Project Structure

- This repository has **four source packages**, each in its own directory at
  the repository root (there is no `src/` layer):

  | directory | package | holds |
  | --- | --- | --- |
  | (root) | `PaiGack/ftp` | the public API: `FTPClient` / `Session` / `Options` / `DialOptions` and every client operation |
  | `core/` | `PaiGack/ftp/core` | protocol values and parsers, no IO: `Entry` / `FtpError` / status codes / `Response` / list parsing |
  | `connection/` | `PaiGack/ftp/connection` | the control channel `Control` and the data channel `DataConn`, `PASV` / `EPSV` / TLS setup |
  | `debug/` | `PaiGack/ftp/debug` | the traffic log `DebugLog` |

  Within a package symbols are referenced by bare name; across packages they
  need a prefix (`@core.Entry`, `@connection.Control`, `@debug.DebugLog`). The
  root package aliases the log as `@ftplog` because `moonbitlang/core/debug`
  already owns `@debug`. Dependencies run one way: `core` and `debug` are
  leaves, `connection` depends on both, the root package on all three.

- **There is no re-export in `moon.pkg`.** `pub use` is a reserved word and
  `export *` / `reexport` do not lex, so the root package cannot publish
  `@ftp.Entry` again; a user naming the type writes `@core.Entry` and imports
  `PaiGack/ftp/core`. Do not add a file of one-line forwarding functions to fake
  it — that is the "public API at the top, implementation below" boundary being
  crossed by hand, and it drifts.

- **A package that mentions `@io` / `@tls` types must import those packages
  itself**, even when a sibling package already re-exports the type. The
  compiler reports `Cannot use @io: package io is not imported` otherwise.

- **`impl` only exists in the defining package.** That is why the traffic log
  exposes `DebugLog::write_path` / `read_path` instead of the upstream
  `MirrorWriter` / `TeeLogReader` decorators: a decorator is a new type with an
  `impl @io.Writer`, and only `debug/` may write it — so it could never wrap the
  socket `Control` (in `connection/`) holds. The two paths keep the old
  semantics (write first, record what was accepted; record the line that was
  read).

- **`connection` must not learn about `Session`.** The data channel's settings
  are passed as the `ConnOptions` value type; the root package projects its
  `Session` onto it with `Session::conn_options`. `DataConn::start_tls`,
  `open_data_conn`, `get_data_port` and `cmd_data_conn_from` therefore take
  fields, not the session — `Session` is a private member of `FTPClient` and
  cannot be moved down.

- **The root `transport.mbt` is a thin projection, not a layer.** If it grows a
  protocol decision, that decision belongs in `connection/transport.mbt`.

- `cmd/ftp/` (CLI)、`cmd/example/`（明文真实服务器演示）、`cmd/ftps/`（FTPS
  端到端冒烟）和 `cmd/profiles/`（四个客户端能力画像）是独立包；其余代码都在根
  `PaiGack/ftp` 包。`cmd/*/moon.pkg` 都声明 `supported_targets = "+native"`，
  因为 async 运行时需要它。

- Test files keep the usual naming: `*_test.mbt` (blackbox) and `*_wbtest.mbt`
  (whitebox) and live in the same package directory as the code they cover, so a
  package's tests run with `moon test -p PaiGack/ftp/core` (and so on). A
  whitebox fixture that needs `Control` / `DataConn` belongs to `connection/`; one
  that needs `FTPClient` belongs to the root package. The two cannot share a
  file: a whitebox test only sees its own package's private symbols, and the
  root package cannot reach into `connection`'s helpers.

- Each `moon.pkg` has one plain import block (shared by every file in that
  package, because MoonBit 0.1.20260920 has no per-file imports) plus the
  `for "wbtest"` / `for "test"` blocks its tests need. The layered split is now
  carried by the package boundaries themselves and by the tree in
  `docs/porting.md` section 2.3; the per-file `// Package:` markers only name
  which package a file belongs to.

- In the toplevel directory, there is a `moon.mod` file listing module
  metadata.

## 脚本与可执行包

目录级细节写在各自的 `AGENTS.md` 里，改对应目录时一起读：

| 目录 | 内容 |
| --- | --- |
| `scripts/` | CI 入口、明文容器、无需 Docker 的自测、fixture 隔离 |
| `scripts/ftps/` | FTPS 容器、证书、握手探测与它们的自测 |
| `scripts/profiles/` | `cmd/profiles` 的无 Docker 自测 |
| `cmd/` | 四个可执行包与包装脚本 |
| `docs/` | `porting.md` 的包布局、文档代码块约定 |

`scripts/ci.sh` 是唯一 CI 入口：`.cnb.yml` 与 `.github/workflows/ci.yml` 各自只有
一个 job，唯一实质步骤是 `bash scripts/ci.sh` —— 不要在流水线里内联 `moon` 命令、
凭据或 `docker run`，也不要给某个平台单独写一份脚本。每个容易被误读的环节都有
一个在镜像拉取之前运行的自测；改动被测脚本时同步改自测。

## MoonBit 中的 async 规则

- **`@io.MemoryReader` 必须有主并在用完后 `close`。** 它有一个后台生产者任务，只有
  `close` 能停掉它；作为临时值内联传入（`f(MemoryReader(...))`）没人关，消费者提前
  停止时事件循环会以 `Dead lock detected` 结束，只点名参数所在行。绑定到变量并
  `defer reader.close()`。`stor` / `append` 同样要求调用方负责关闭 source。

- **控制通道的读必须有超时。** `Control` 携带 `timeout_ms`，`read_line` 超时抛
  `FtpError::RequestTimeout`；没有超时，等待一个慢服务器的读会被事件循环判为死锁。
  不要在 `cmd_data_conn_from` 里把这个错误吞掉。

- **数据通道的 TLS 握手必须在传输命令之后**（服务器在回 `150` 前不读数据 socket），
  由 `cmd_data_conn_from` 在收到 `150` 后调用 `DataConn::start_tls`；
  `DataConn::close` 先发 TLS `close_notify` 再关 socket。

- **FTPS 的问题单测和明文服务器都覆盖不到**。历史上的 TLS bug 全在接缝处：
  `AUTH TLS` 后没升级 socket、显式 TLS 跳过 `PBSZ` / `PROT P`、
  隐式 TLS 没包住控制连接、数据连接未发 `close_notify`。改动
  `dial.mbt` / `transport.mbt` / `control.mbt` 前后都要保持 `cmd/ftps` 通过，
  且**不得关闭证书校验**来让它通过。

## Coding convention

- MoonBit code is organized in block style, each block is separated by `///|`,
  the order of each block is irrelevant. In some refactorings, you can process
  block by block independently.

- Try to keep deprecated blocks in file called `deprecated.mbt` in each
  directory.

## Tooling

- `moon fmt` 格式化代码，也会格式化 `.mbt.md` 里被检查的代码块；
  `moon fmt --check` 要求 README 片段符合规范。

- `.mbt.md` 里的代码块默认只高亮：写 ```moonbit check 才会进 `moon check`，
  `moonbit nocheck` 是例外。`README.mbt.md` 的快速开始带 `check`，是文档 API 的回归
  测试；它位于根包，不能声明 `main`（用 `test { }` 包起来）。`docs/porting.md`
  的普通围栏是有意为之。

- `moon ide` provides project navigation helpers like `peek-def`, `outline`, and
  `find-references`. See $moonbit-agent-guide for details.

- `moon info` regenerates the package interface `.mbti`. 最后一步跑
  `moon info && moon fmt`，检查 `.mbti` 的差异是否预期。

- Run `moon test` to check tests pass. MoonBit supports snapshot testing; when
  changes affect outputs, run `moon test --update` to refresh snapshots.

- Prefer `assert_eq` or `assert_true(pattern is Pattern(...))` for results that
  are stable or very unlikely to change. For snapshot tests that record
  structured debugging output, derive `Debug` and use `debug_inspect`, rather
  than deriving `Show` for debugging. For solid, well-defined results (e.g.
  scientific computations), prefer assertion tests. You can use
  `moon coverage analyze > uncovered.log` to see which parts of your code are
  not covered by tests.

- Rerun the Docker-free self-tests you touched directly, e.g.
  `python3 scripts/ftp-wrapper-selftest.py .`; they take a repo root argument and
  need no server.
