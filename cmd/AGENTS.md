# cmd/ — 可执行包

四个独立的原生包，都只依赖根包 `PaiGack/ftp`：

| 包 | 作用 | 运行方式 |
| --- | --- | --- |
| `ftp/` | CLI，参数解析在 `main.mbt`，无参数时打印用法 | `cmd/ftp/run.sh [args...]` |
| `example/` | 对真实 `jmoyer/vsftpd` 容器跑 dial / login / list / retr / stor / rename / mkdir / walk / quit，逐步打印 | `cmd/example/run.sh` |
| `ftps/` | FTPS 端到端冒烟；参数 `explicit`（默认，`AUTH TLS`）或 `plain`（无 TLS） | `cmd/ftps/run.sh [explicit\|plain]` |
| `profiles/` | 四个客户端能力画像，可只跑指定画像名 | `cmd/profiles/run.sh [profile]` |

所有 `moon.pkg` 都声明 `supported_targets = "+native"`。失败一律是硬失败，不要
软化成 skip。

## 包装脚本

- **包装脚本只通过环境变量传端点，绝不拼 `--flag <value>` 对。** 空的展开会让标志
  吞掉下一个参数，或把值变成位置参数，报的是没人输入过的 usage 错误。仓库里没有
  `.env`。
- `cmd/ftp/run.sh` 与 `cmd/profiles/run.sh` 各自 `export` 同一套
  `FTP_TEST_HOST/PORT/USER/PASS` 默认值，`cmd/ftp` 读这组名字（
  `fallback_env_or` / `fallback_env_port`，`FTP_*` 作为第二回退），
  `cmd/profiles` 把四个都当必填、缺一个就报错退出。统一拼写是目的：没有哪个
  客户端会「少了一个没人导出的变量」而悄悄退回 `anonymous`。改包装脚本、改
  二进制读的变量名、改 `AGENTS.md` 三者必须同一个提交里一起改。
- `cmd/example/run.sh` 不需要任何配置，`main.mbt` 自己给每个变量带默认值。
- `cmd/ftps/run.sh` 先读 `.ftp-tls.env`（由 `scripts/ftps/start-ftps.sh` 写），
  再用 `moon run cmd/ftps -- "$@"`；它的 `plain` 模式针对明文容器，是对「修复
  没有破坏明文路径」的回归守卫。
- `scripts/ftp-wrapper-selftest.py`（无需 Docker，在 `scripts/ci.sh` 里跑）断言了
  上面全部内容：没有 `.env`、不出现任何连接标志、导出四个默认值与容器凭据 /
  固定端口一致、二进制读的变量名与包装脚本导出的名字一致。

## 程序内的约定

- **`@io.MemoryReader` 必须有主并在用完后 `close`。** 它有一个后台生产者任务，
  只有 `close` 能停掉它；作为临时值内联传入（`f(MemoryReader(...))`）没人关，
  消费者提前停止时事件循环会以 `Dead lock detected` 结束，只点名参数所在行。
  绑定到变量并 `defer reader.close()`（`cmd/ftps/main.mbt` 的 `STOR` 就是这样）。
  `stor` / `append` 同样要求调用方负责关闭 source，`cmd/example/main.mbt` 的
  `stor_text` 的注释里有完整说明。

- **`cmd/ftps` 拨号失败会再试一次**：一次读到 EOF 可能只是容器还在启动，两次都
  失败才判定「端点背后没有服务器」，并在消息里点名端点。这是为了把
  `ReaderClosed` 从「客户端 bug」纠正为「容器已死」。
