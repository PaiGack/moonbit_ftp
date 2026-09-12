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

## 快速开始

所有公开函数都是 `async` 函数，调用方需处在 `@async` 运行时中（CLI / 测试里写
`async fn main` 即可，无需手写 `await`）。最小可运行例子：

```moonbit nocheck
///|
async fn main {
  // 1. 建连并登录
  let client = @ftp.dial("127.0.0.1:21", timeout_ms=15000)
  @ftp.login(client, "user", "pass")

  // 2. 列目录：优先 MLSD，否则自动回退到 LIST 四种格式解析
  for entry in @ftp.list(client, "/") {
    println("\{entry.type_.to_string()}  size=\{entry.size}  \{entry.name}")
  }

  // 3. 下载文件
  let resp = @ftp.retr(client, "/hello.txt")
  let bytes = resp.reader.read_all() catch { _ => b"" }
  resp.close()

  // 4. 上传文件（任意 &@io.Reader 均可）
  @ftp.stor(
    client,
    "/upload.txt",
    @io.MemoryReader(w => w.write("demo upload")),
  )

  // 5. 目录与文件操作
  @ftp.make_dir(client, "/newdir")
  @ftp.rename(client, "/a.txt", "/b.txt")
  @ftp.delete(client, "/b.txt")

  // 6. 递归遍历目录树
  let w = @ftp.walk(client, "/")
  while w.next() {
    println(w.path())
  }

  // 7. 退出并关闭连接
  @ftp.quit(client)
}
```

### 常用函数

| 函数 | 作用 |
| --- | --- |
| `dial(addr, ..)` | 建连，可选 `explicit_tls` / `tls` / `timeout_ms` / `trust_pasv_ip` 等参数 |
| `login(client, user, pass)` | `USER`/`PASS` 登录并协商 `FEAT` / `TYPE` 能力 |
| `list(client, path)` | 列目录，返回 `Array[Entry]`（MLSD / LIST 自动回退） |
| `get_entry(client, path)` | 取单个条目的 facts |
| `retr` / `retr_from(client, path, offset)` | 下载 / 断点续传下载 |
| `stor` / `append(client, path, reader)` | 上传 / 追加 |
| `make_dir` / `remove_dir` / `delete` / `rename` / `change_dir` / `current_dir` | 目录与文件管理 |
| `walk(client, root)` | 深度优先遍历目录树，`next()` 失败时不抛错而是返回 `false` |
| `quit(client)` | 发 `QUIT` 并关闭连接 |

> 错误以 `FtpError` 抛出，可用 `catch` / `try!` 统一处理；`list` / `walk` 解析不出的行会被跳过而非中断。

## 开发

### 常用命令

所有 `moon` 命令都带上 `--target native`：模块声明了 `preferred_target = "native"`，
wasm / wasm-gc 后端没有真实网络栈。

```bash
moon fmt --check                         # 格式检查
moon check --target native --deny-warn   # 类型检查，要求 0 warning
moon test --target native                # 单元测试
moon build --target native               # 构建
moon info                                # 更新生成接口（.mbti）
```

提交前请确认 `moon fmt --check`、`moon check --target native --deny-warn`、
`moon test --target native` 三条命令均通过。

## 目录结构

所有源码直接平铺在仓库根目录，没有包目录层级，全部属于同一个包 `PaiGack/ftp`，
包内互相引用使用裸名字（如 `Entry`、`parse_list_line`）。

```
.
├── entry.mbt                  Entry / EntryType / TransferType                    纯逻辑
├── status.mbt                 RFC 959 状态码与常量 + status_text()                 纯逻辑
├── error.mbt                  FtpError / FtpErrors                                纯逻辑
├── parse.mbt                  RFC 3659 / UNIX ls / DOS DIR / hostedftp 解析器      纯逻辑
│                              回退链 + LIST 时间字段解析 + 字段扫描器
├── pathutil.mbt               远端路径 join（对齐 Go path.Join 语义）             纯逻辑
├── control.mbt                控制通道：命令编码、多行响应、状态码校验 + 流量日志    IO
├── transport.mbt              EPSV / PASV / PRET / REST / 数据连接 / TLS 建立        IO
├── client.mbt                 FTPClient + Session / Options + DialOptions           IO
├── dial.mbt                   dial / 登录 / FEAT 能力协商                           IO
├── commands.mbt               CWD / PWD / MKD / RMD / DELE / RNFR+RNTO / QUIT       IO
├── list.mbt                   目录列表
├── transfer.mbt               文件传输（RETR / STOR / APPE / REST）
├── walker.mbt                 目录树遍历
├── cmd/ftp/                   CLI 示例：ls / get / put / walk / mkdir / rm
│   ├── main.mbt
│   └── run.sh                 按 .env 跑 cmd/ftp，可带参数覆盖默认命令
├── cmd/example/               真实 vsftpd 端到端演示
│   ├── main.mbt
│   └── run.sh                 按 .env 跑 cmd/example
├── scripts/
│   ├── ci.sh                  CI 入口脚本
│   ├── start-ftp.sh           启动 vsftpd 容器
│   ├── probe-ftp.py           容器就绪探测（登录 + 一次被动 LIST）
│   └── stop-ftp.sh            导出容器日志并清理
├── testdata/ftp/              测试与演示使用的 fixture
├── docs/                      移植方案与设计文档
├── moon.pkg                   根包清单
└── moon.mod                   模块定义
```

`moon.pkg` 的 import 块包含 `moonbitlang/async`，纯逻辑与 IO 源码同属一个包，
分层约束通过每个源文件头部注释标记，目录树按层分组列出文件名。

## 致谢与来源

本项目为 [jlaffaye/ftp](https://github.com/jlaffaye/ftp)（ISC License）的 MoonBit 移植，
参考其协议实现与测试用例。原项目版权归 Julien Laffaye 所有。

上游 ISC 许可证原文、版权署名与来源说明见 [LICENSE-THIRD-PARTY](LICENSE-THIRD-PARTY)。
包含移植代码的源文件头部均标注
`Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.`。

## 许可证

本项目自身代码采用 Apache-2.0，见 [LICENSE](LICENSE)。
移植自 [jlaffaye/ftp](https://github.com/jlaffaye/ftp) 的部分同时受其 ISC 许可约束，
原文见 [LICENSE-THIRD-PARTY](LICENSE-THIRD-PARTY)。
