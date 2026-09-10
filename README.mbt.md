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
moon test   --target native              # 运行测试（真机用例默认跳过）
moon build  --target native              # 构建
moon run cmd/ftp                         # 运行 CLI（打印 usage）
moon info                                # 更新生成接口（.mbti）
```

### 真实 FTP 服务器测试

`ftp_server_test.mbt` 的 13 条端到端用例跑在一台**真实 FTP 守护进程**上，
需要显式设置环境变量才会执行（不设时用例直接跳过，本机 `moon test` 保持全绿）：

```bash
python3 -m pip install "pyftpdlib==2.2.0"
mkdir -p .ci/ftp-root/upload && cp -r .github/ftp-fixture/fixture .ci/ftp-root/
python3 .github/ftp-fixture/serve.py --root "$PWD/.ci/ftp-root" --port 2121 &

FTP_TEST_HOST=127.0.0.1 FTP_TEST_PORT=2121 moon test --target native
```

GitHub Actions、CNB 流水线与 CNB 云原生开发环境都会自动起同一个服务器
（`serve.py` + 仓库内的 fixture），无需手工准备。详见
[docs/porting/05-testing.md](docs/porting/05-testing.md) 第 6 节。

## 目录结构

所有源码**直接平铺在仓库根目录**，没有包目录层级。原先的 `types/` `client/` `parse/`
这些目录全部展开成了同级的 `.mbt` 文件，引用也从 `@types.Entry` 变成直接的 `Entry`
（都在同一个包 `PaiGack/ftp` 里）。

```
.
├── entry.mbt / consts.mbt            Entry / EntryType / TransferType / 常量        纯逻辑
├── status.mbt                        RFC 959 状态码常量 + status_text()             纯逻辑
├── error.mbt                         FtpError / FtpErrors                          纯逻辑
├── scanner.mbt                       空白分隔字段扫描器（LIST 行解析用）             纯逻辑
├── parse.mbt                         RFC3659 / UNIX ls / DOS DIR / hostedftp 解析器  纯逻辑
│                                     与 parse_list_line 回退链
├── parse_time.mbt                    LIST 时间字段解析（含半年规则）                 纯逻辑
├── pathutil.mbt                      远端路径 join（对齐 Go path.Join 语义）        纯逻辑
├── control.mbt                       控制通道：命令编码、多行响应、状态码校验        IO
├── state.mbt                         client 与 transport 共享的连接状态               IO
├── transport.mbt                     EPSV / PASV / PRET / REST / 数据连接 / TLS 建立   IO
├── client.mbt                        FTPClient（对齐上游 ServerConn）+ DialOptions   IO
├── dial.mbt / login.mbt / nav.mbt / list.mbt / transfer.mbt
├── fsops.mbt / lifecycle.mbt
│                                     连接、登录、导航、列表、传输、文件操作、生命周期 IO
├── walker.mbt                        目录树遍历器（建在 client 上）                   IO
├── debug.mbt                         控制 / 数据通道原始流量日志包装                   IO
├── architecture.mbt                  纯逻辑 / IO 文件清单（分层登记表）
├── cmd/ftp/                          CLI 示例：ls / get / put / walk / mkdir / rm
├── moon.pkg                          根包清单（唯一的源码包）
└── moon.mod                          模块根
```

根包只有一个 `moon.pkg`，它的普通 import 块里带着 `moonbitlang/async`：纯逻辑与 IO
源码同属一个包，MoonBit 目前也没有「按文件限定 import」的语法。分层约束因此靠两样东西
落地：每个源文件头部的 `// Layer: pure logic` / `// Layer: IO` 标记，以及
`architecture.mbt` 里两份显式清单（`pure_logic_packages` / `io_sources`）。

依赖方向单向、禁止反向，详见 [docs/porting/01-architecture.md](docs/porting/01-architecture.md)。

## 文档

- [docs/porting.md](docs/porting.md) — 移植总体方案
- [docs/porting/](docs/porting/) — 实施文档集（架构、上游映射、工作包、API 映射、测试、兼容清单、风险、验收）

## 致谢与来源

本项目为 [jlaffaye/ftp](https://github.com/jlaffaye/ftp)（ISC License）的 MoonBit 移植，
参考其协议实现与测试用例。原项目版权归 Julien Laffaye 所有。

## 许可证

Apache-2.0，见 [LICENSE](LICENSE)。
