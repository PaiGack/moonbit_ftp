# PaiGack/ftp

纯 MoonBit 实现的 FTP 客户端库，移植自 [jlaffaye/ftp](https://github.com/jlaffaye/ftp)。

支持被动模式、`MLSD` / `LIST` 四种列表格式解析、断点续传与 FTPS（显式 / 隐式 TLS）。

## 环境要求

- [MoonBit](https://www.moonbitlang.com/download) 工具链（`moon`）
- **C 编译器**：`gcc` + `libc6-dev`。FTP 需要真实 TCP + TLS，模块声明了
  `preferred_target = "native"`，native 后端的编译与链接依赖 C 工具链。

安装：

```bash
curl -fsSL https://cli.moonbitlang.cn/install/unix.sh | bash
export PATH="$HOME/.moon/bin:$PATH"

# native 后端所需的 C 工具链（Debian / Ubuntu）
sudo apt-get install -y gcc libc6-dev
```

## 开发

所有 `moon` 命令都显式带上 `--target native`：`preferred_target` 已是 `native`，
wasm / wasm-gc 后端提供不了真实网络栈。

```bash
moon fmt --check                         # 格式化检查
moon check  --target native --deny-warn  # 类型检查，0 warning 0 error
moon test   --target native              # 运行测试
moon build  --target native              # 构建
moon run cmd/ftp -- --help               # CLI 用法
moon run cmd/example                     # 真机演示（需先起 vsftpd）
moon info                                # 更新生成接口（.mbti）
```

### 真实 FTP 服务器演示

`cmd/example` 是一个跑在**真实 vsftpd** 上的端到端演示：起一个
`jmoyer/vsftpd` 容器，挂 `testdata/ftp/fixture/` 为 FTP 根目录，跑一遍
dial / login / list / retr / stor / mkdir / walk / quit，每步打印到 stdout。
镜像与 fixture 由公共脚本 `scripts/start-ftp.sh` 提供：

```bash
scripts/start-ftp.sh            # 起一个 jmoyer/vsftpd 容器（--network host）

export FTP_TEST_HOST=127.0.0.1 FTP_TEST_PORT=21 \
       FTP_TEST_USER=test FTP_TEST_PASS=test
moon run cmd/example --target native

scripts/stop-ftp.sh             # 打日志并清理容器
```

GitHub Actions（`ftp-demo` job）与 CNB 流水线（`ftp-demo` stage）都调用
**同一份**脚本（`scripts/start-ftp.sh` / `scripts/stop-ftp.sh`），镜像为
`jmoyer/vsftpd`（vsftpd 3.0.5），fixture 在 `testdata/ftp/fixture/`。
详见 [docs/porting/05-testing.md](docs/porting/05-testing.md) 第 4 节。

### 公共脚本

跨 CI 复用、需要跟平台无关的脚本统一放在 `scripts/`：

| 脚本 | 作用 |
| --- | --- |
| `scripts/start-ftp.sh` | 起一个真实 FTP 服务器容器并轮询端口，起不来直接 exit 1 |
| `scripts/stop-ftp.sh` | 打印容器日志并清理，从不失败 |

## 目录结构

所有源码**直接平铺在仓库根目录**，没有包目录层级。原先的 `types/` `client/` `parse/`
这些目录全部展开成了同级的 `.mbt` 文件，引用也从 `@types.Entry` 变成直接的 `Entry`
（都在同一个包 `PaiGack/ftp` 里）。

```
.
├── entry.mbt                         Entry / EntryType / TransferType              纯逻辑
├── status.mbt                        RFC 959 状态码与常量 + status_text()            纯逻辑
├── error.mbt                         FtpError / FtpErrors                          纯逻辑
├── parse.mbt                         RFC3659 / UNIX ls / DOS DIR / hostedftp 解析器  纯逻辑
│                                     回退链 + LIST 时间字段解析 + 字段扫描器
├── pathutil.mbt                      远端路径 join（对齐 Go path.Join 语义）        纯逻辑
├── control.mbt                       控制通道：命令编码、多行响应、状态码校验        IO
│                                     + 流量日志包装
├── transport.mbt                     EPSV / PASV / PRET / REST / 数据连接 / TLS 建立   IO
├── client.mbt                        FTPClient + Session/Options + DialOptions       IO
│                                     + SIZE / MDTM / MFMT
├── dial.mbt                          dial / 登录 / FEAT 能力协商                     IO
├── commands.mbt                      CWD / PWD / MKD / RMD / DELE / RNFR+RNTO        IO
│                                     / NOOP / REIN / QUIT
├── list.mbt / transfer.mbt / walker.mbt
│                                     列表、传输、目录树遍历                          IO
├── cmd/ftp/                          CLI 示例：ls / get / put / walk / mkdir / rm
├── cmd/example/                      真实 vsftpd 端到端演示（CI 用）
├── scripts/                          跨 CI 复用的公共脚本
│   ├── start-ftp.sh                  起一个真实 vsftpd 容器（CNB / GitHub 共用）
│   └── stop-ftp.sh                   打容器日志并清理
├── testdata/ftp/                     fixture 内容
├── .cnb.yml / .github/workflows/     CNB 与 GitHub 两条流水线（调同一份 scripts/）
├── moon.pkg                          根包清单（唯一的源码包）
└── moon.mod                          模块根
```

根包只有一个 `moon.pkg`，它的普通 import 块里带着 `moonbitlang/async`：纯逻辑与 IO
源码同属一个包，MoonBit 目前也没有「按文件限定 import」的语法。分层约束因此落在每个
源文件头部的 `// Layer: pure logic` / `// Layer: IO` 标记上，目录树按层分组列出文件名。

依赖方向单向、禁止反向，详见 [docs/porting/01-architecture.md](docs/porting/01-architecture.md)。

## 文档

- [docs/porting.md](docs/porting.md) — 移植总体方案
- [docs/porting/](docs/porting/) — 实施文档集（架构、上游映射、工作包、API 映射、测试、兼容清单、风险、验收）
- [LICENSE-THIRD-PARTY](LICENSE-THIRD-PARTY) — 上游 jlaffaye/ftp 的 ISC 许可证原文与署名

## 致谢与来源

本项目为 [jlaffaye/ftp](https://github.com/jlaffaye/ftp)（ISC License）的 MoonBit 移植，
参考其协议实现与测试用例。原项目版权归 Julien Laffaye 所有。

上游 ISC 许可证原文、版权署名、来源链接与参考范围说明见
[LICENSE-THIRD-PARTY](LICENSE-THIRD-PARTY)；逐文件的上游落点映射见
[docs/porting/02-upstream-map.md](docs/porting/02-upstream-map.md)。所有包含移植代码的
源文件头部均标注 `Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.`。

## 许可证

本项目自身代码采用 Apache-2.0，见 [LICENSE](LICENSE)。
移植自 [jlaffaye/ftp](https://github.com/jlaffaye/ftp) 的部分同时受其 ISC 许可约束，
原文见 [LICENSE-THIRD-PARTY](LICENSE-THIRD-PARTY)。
