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
moon run cmd/ftp                         # 运行 CLI（打印 usage）
moon info                                # 更新生成接口（.mbti）
```

## 目录结构

所有包**直接平铺在仓库根目录**，不套 `src/` 中间层。包路径由目录决定，多一层只会让
`@src.client` 这类冗余前缀出现在所有引用处。

```
.
├── types/          Entry / EntryType / TransferType                 纯逻辑
├── status/         RFC 959 状态码常量 + status_text()                纯逻辑
├── error/          FtpError / FtpErrors                             纯逻辑
├── scanner/        空白分隔字段扫描器（LIST 行解析用）                 纯逻辑
├── parse/          RFC3659 / UNIX ls / DOS DIR / hostedftp 四种解析器  纯逻辑
├── pathutil/       远端路径 join（对齐 Go path.Join 语义）            纯逻辑
├── architecture/   架构守卫：纯逻辑包不得依赖 moonbitlang/async
├── control/        控制通道：命令编码、多行响应、状态码校验             IO
├── state/          client 与 transport 共享的连接状态（打破循环依赖）   IO
├── transport/      EPSV / PASV / PRET / REST / 数据连接 / TLS 建立     IO
├── client/         FTPClient（对齐上游 ServerConn）公开 API            IO
├── walker/         目录树遍历器（建在 client 上）                      IO
├── debug/          控制 / 数据通道原始流量日志包装                      IO
├── cmd/ftp/        CLI 示例：ls / get / put / walk / mkdir / rm
└── moon.mod        模块根（根目录本身也是包的宿主）
```

依赖方向单向、禁止反向，详见 [docs/porting/01-architecture.md](docs/porting/01-architecture.md)。

## 文档

- [docs/porting.md](docs/porting.md) — 移植总体方案
- [docs/porting/](docs/porting/) — 实施文档集（架构、上游映射、工作包、API 映射、测试、兼容清单、风险、验收）

## 致谢与来源

本项目为 [jlaffaye/ftp](https://github.com/jlaffaye/ftp)（ISC License）的 MoonBit 移植，
参考其协议实现与测试用例。原项目版权归 Julien Laffaye 所有。

## 许可证

Apache-2.0，见 [LICENSE](LICENSE)。
