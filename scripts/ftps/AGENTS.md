# scripts/ftps/ — FTPS 容器、证书与握手探测

FTPS 的问题在单测和明文服务器上都暴露不出来（TLS 的 bug 都在接缝处），
所以这一块的容器、证书、探测和自测都放在同一个目录，并且每一条规则都由
`ci.sh` 里一个无需 Docker 的自测守着。

## 生命周期

1. `gen-cert.sh OUT_DIR` —— 现签自签名 CA + 叶子证书到 `OUT_DIR`，每次重签，
   产物 gitignored。
2. `start-ftps.sh` —— 起 `bfren/ftps` 容器（`127.0.0.1:2121`），等 `probe-ftps.sh`
   通过后把端点与 CA 路径写进 gitignored 的 `.ftp-tls.env`。
3. `cmd/ftps/run.sh` 读 `.ftp-tls.env`，以 `trust=CustomPemFile(CA)` 连接，
   **证书校验保持开启**。
4. `stop-ftps.sh` —— 打印日志、删容器，永不失败。

## 规则

- **`testdata/ftp/tls` 必须在 `moon test` 之前生成。**
  `transfer_wbtest.mbt` 的零字节 TLS 上传用例是唯一做服务端握手的测试，而
  `@tls.Tls::server_from_pair` 只接受文件路径。缺证书时报的是
  `stor_from: Cancelled`（任务组把服务器任务的错误折叠成取消），不会点名证书。
  `scripts/ci.sh` 在测试前调用 `gen-cert.sh`，再由 `tls-fixture-selftest.py`
  确认产物可用。

- **叶子证书必须挂成 `/ssl/vsftpd.pem`，`/ssl` 保持只读。** 镜像内部写死了这个
  路径（`10-env.nu` / `13-vsftpd-ssl.nu` / `vsftpd.conf.esh`）。名字不对，镜像会
  在 init 时试图自签而写失败，容器直接退出，表现为探测一直 `Connection refused`。
  `start-ftps.sh` 因此先做存活检查再探测，并且不传 `--rm`，好让死掉的容器日志
  还能读。

- **就绪探测看会话记录，不看 `openssl` 退出码。** vsftpd 在 `QUIT` 后不发
  `close_notify`，`s_client` 会在成功的 `230` 之后以退出码 1 结束；另外
  `s_client` 自己不会退出（需要 `timeout`），`-quiet` 的服务器回复走 stderr
  （需要 `2>&1`）。所以探测捕获输出后只以出现 `230` 为准，失败时打印完整记录。

- **FTPS 容器挂自己的 fixture 副本（`.ftp-ftps-files/`）。** 镜像 init 时会递归
  `chown` `/files`，那是 bind mount，会改到宿主机；和明文容器共享同一份
  `testdata/ftp/fixture` 会让明文一侧 `STOR` 失败（`553`）。
  `fixture-isolation-selftest.py` 守这条。

- **数据通道的 TLS 握手必须在传输命令之后**（服务器在回 `150` 前不读数据
  socket），`DataConn::close` 先发 `close_notify` 再关 socket。两个位置都是
  承重的，改动 `dial.mbt` / `transport.mbt` / `control.mbt` 前后都要保持
  `cmd/ftps` 通过。

## 自测

- `probe-ftps-selftest.py PROBE`：用 mock 驱动 `probe-ftps.sh`，四种结局
  （登录成功、密码被拒、无人监听、证书非本 CA 签发）。探测的 bug 是「对健康
  服务器说不健康」，会让 `start-ftps.sh` 失败、`.ftp-tls.env` 不生成，下游
  看起来全是 TLS 问题，所以必须在这里先抓住。
- `tls-fixture-selftest.py ROOT [GEN_CERT]`：重签一份到临时目录并确认它是一对
  可用的 key + 证书，同时确认 `ci.sh` 把 `gen-cert.sh` 排在 `moon test` 之前、
  指向 `testdata/ftp/tls`。
- `fixture-isolation-selftest.py ROOT`：断言两个 starter 不挂同一个目录。
- `cmd-ftps-selftest.py ROOT`：用 `ftp_mock.py` 驱动真实 `cmd/ftps` 两次，一次
  全部成功，一次拒绝 `STOR` —— 后者是 `MemoryReader` 未关闭导致
  `Dead lock detected` 的回归守卫。
