# scripts/profiles/ — `cmd/profiles` 的无 Docker 自测

`cmd/profiles` 跑四个**客户端**能力画像（`full` / `no-mlst` / `no-time` /
`no-epsv`），每个画像的断言是「客户端选了哪条命令」，不是服务器回了什么：

| 画像 | 断言 |
| --- | --- |
| `full` | 用 `MLSD`、`EPSV`（不退 `PASV`），用 `MFMT` 写、`MDTM` 读时间戳 |
| `no-mlst` | 列目录只用 `LIST`，不发 `MLSD` |
| `no-time` | 仍用 `MDTM` 读时间戳，但从不写（无 `MFMT`） |
| `no-epsv` | 传输只用 `PASV`，不发 `EPSV` |

真实 vsftpd 两种都支持，所以这些选择在容器上无论如何都「通过」——mock 是唯一能
断言它们的地方。

- `ftp_profile_mock.py`：带真实文件系统的明文 FTP mock，按容器的方式回答
  `NLST <dir>`（完整路径而不是裸文件名），并记录每个收到的命令。
- `cmd-profiles-selftest.py ROOT`：用 mock 驱动真实 `cmd/profiles`，检查命令流，
  也覆盖「只跑指定画像名」的模式（新会话、只报告一个画像）。

## 与 `ci.sh` 的约定

- `ci.sh` 按画像名逐个调用 `cmd/profiles/run.sh <name>`，每个前面有自己的
  `ensure-ftp.sh` 并由 `run_guarded` 包裹：一次调用开四个会话，容器可能在第三个
  和第四个之间死掉，前置检测覆盖不到。
- 新增画像必须在 `profiles()`（`cmd/profiles/main.mbt`）和 `ci.sh` 里同时加；
  `scripts/ensure-ftp-selftest.py` 会比对两边的名单，漏一个就失败。
