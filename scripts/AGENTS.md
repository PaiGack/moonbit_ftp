# scripts/ — CI 与本地验证

`ci.sh` 是唯一 CI 入口。`.cnb.yml` 与 `.github/workflows/ci.yml` 各自只有一个
job，唯一实质步骤是 `bash scripts/ci.sh` —— 不要在流水线里内联 `moon` 命令、
凭据或 `docker run`，也不要给某个平台单独写一份脚本。所有步骤都要经由
`run` 执行（失败记入 `status` 而不中断），`stop-*.sh` 由 `trap` 兜底清理。

## 无需 Docker 的自测

`ci.sh` 在任何镜像拉取之前运行下面这些自测。它们各自守一个「真实服务器上
看不出来、或者失败症状会被误读」的规则；触发条件与失败症状写在脚本的
docstring 里，**改动被测脚本时同步改自测**。

| 自测 | 被测对象 | 守住的规则 |
| --- | --- | --- |
| `probe-ftp-selftest.py` | `probe-ftp.py` | 健康判定，以及会话以 `QUIT` 结束 |
| `ensure-ftp-selftest.py` | `ensure-ftp.sh`、`ci.sh` 的 `run_guarded` | 重启逻辑；条件重试的四种结局；每个明文客户端的调用位置 |
| `ftp-wrapper-selftest.py` | `cmd/*/run.sh` | 环境变量传端点、不拼 `--flag`、不读 `.env` |
| `vsftpd-env-selftest.py` | `start-ftp.sh` | 镜像 entrypoint 用到的每个变量都传了 |
| `ftps/probe-ftps-selftest.py` | `ftps/probe-ftps.sh` | `AUTH TLS` + 登录的就绪判定 |
| `ftps/tls-fixture-selftest.py` | `ftps/gen-cert.sh` 的产物 | `moon test` 所需的证书确实已生成且可用 |
| `ftps/fixture-isolation-selftest.py` | 两个 starter | 明文 / FTPS 容器各用一份 fixture 副本 |
| `ftps/cmd-ftps-selftest.py` | `cmd/ftps` | 真实二进制对 mock 跑通，含拒绝 `STOR` 的失败路径 |
| `profiles/cmd-profiles-selftest.py` | `cmd/profiles` | 每个画像实际发出的命令（`LIST`/`MLSD`、`PASV`/`EPSV`、时间戳） |

单独重跑：`python3 <自测脚本> <参数>`，参数见各自 docstring。多数只收仓库根，
**`ftps/probe-ftps-selftest.py` 例外**：它收的是被测脚本本身
（`scripts/ftps/probe-ftps.sh`），传仓库根会被前置校验直接拒绝
（以前会拖到调用 `gen-cert.sh` 时才以 127 失败，看起来像缺工具）。除
`cmd-ftps-selftest.py` / `cmd-profiles-selftest.py` 会驱动已构建的原生二进制外，
其余都不需要编译。

## 明文容器

- `start-ftp.sh` / `stop-ftp.sh` 起停 `jmoyer/vsftpd`，`127.0.0.1:21`。
- `probe-ftp.py` 是就绪探测：登录 + 被动 `LIST`，以 `QUIT` 收尾。`start-ftp.sh`
  和 `ensure-ftp.sh` 都靠它的退出码判断服务器是否在服务。
- `ensure-ftp.sh` 在明文客户端之间复检容器，不在就重启；只在客户端**失败且**
  服务器确实不在时才被 `ci.sh` 的 `run_guarded` 用到。
- 容器可能在某个步骤进行中就死掉（DinD 下端口代理仍在，客户端报
  `ReaderClosed` / `Connection reset by peer` / `Connection refused` 各不相同）。
  所以 `ci.sh` 里每个明文客户端都由 `run_guarded` 包裹，而不是只靠前置检测。

## fixture

- **每个容器各拷一份 `testdata/ftp/fixture`，绝不把这份检入目录同时挂进两个
  容器。** `bfren/ftps` 在 init 时递归 `chown` 它的 `/files` 挂载点，会改到宿主机
  目录；共享会让后启动的容器 `STOR` 失败（`553`），也会弄脏工作树。两个 starter
  各自 `cp -R` 到 gitignored 的 `.ftp-plain-root/` / `.ftp-ftps-files/`，对应
  `stop-*.sh` 负责 `rm -rf`。不要「简化」回单一挂载。
- `testdata/ftp/tls` 是 `gen-cert.sh` 的产物（gitignored），必须是 `moon test`
  之前生成，见 `ftps/AGENTS.md`。
