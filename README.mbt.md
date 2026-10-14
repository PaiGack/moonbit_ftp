# PaiGack/ftp

纯 MoonBit 实现的 FTP / FTPS 客户端库，移植自 [jlaffaye/ftp](https://github.com/jlaffaye/ftp)。

支持被动模式（`EPSV` 优先、`PASV` 回退）、`MLSD` / `LIST` 四种列表格式解析、断点续传、
目录树遍历，以及显式与隐式 TLS。

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

完整依赖表（`openssl` / `python3` / `docker` 分别服务哪些步骤）见
[开发 → 依赖安装](#开发)。

## 快速开始

所有公开函数都是 `async` 函数，调用方需处在 `@async` 运行时中（CLI / 测试里写
`async fn main` 即可，无需手写 `await`）。下面这段**最小可运行例子**同时是文档自身的
回归测试：它用 `moonbit check` 标注，会被 `moon check` 真的类型检查。

```moonbit check
///|
test {
  ///|
  async fn demo() -> Unit {
    // 1. 建连并登录
    let client = @ftp.dial("127.0.0.1:21", timeout_ms=15000)
    @ftp.login(client, "user", "pass")

    // 2. 列目录：优先 MLSD，否则自动回退到 LIST 四种格式解析
    for entry in @ftp.list(client, "/") {
      println("\{entry.type_.to_string()}  size=\{entry.size}  \{entry.name}")
    }

    // 3. 下载文件
    let resp = @ftp.retr(client, "/hello.txt")
    // 读到的内容要接住：`let bytes` 不消费会触发 unused warning
    let bytes = resp.reader.read_all() catch { _ => b"" }
    println(bytes.text() catch { _ => "<not utf8>" })
    resp.close()

    // 4. 上传文件（任意 &@io.Reader 均可）
    // `MemoryReader` 的后台生产者由调用方负责关：绑到变量再 defer close，
    // 否则传输失败时它残留的任务会让事件循环以死锁收场。
    let source = @io.MemoryReader(w => w.write("demo upload"))
    defer source.close()
    let upload = "/upload.txt"
    @ftp.stor(client, upload, source)

    // 5. 重命名，顺手做一次建目录 / 删目录的往返
    let renamed = "/upload_renamed.txt"
    @ftp.rename(client, upload, renamed)
    @ftp.make_dir(client, "/newdir")
    @ftp.remove_dir(client, "/newdir")

    // 6. 递归删除非空目录：`remove_dir` 只删空目录，`remove_dir_recur` 先删光
    //    内容再删目录本身（对应上游的 RemoveDirRecur）
    @ftp.make_dir(client, "/tree")
    @ftp.make_dir(client, "/tree/sub")
    let nested = @io.MemoryReader(w => w.write("nested"))
    defer nested.close()
    @ftp.stor(client, "/tree/sub/f.txt", nested)
    @ftp.remove_dir_recur(client, "/tree")

    // 7. 递归遍历目录树
    let w = @ftp.walk(client, "/")
    while w.next() {
      println(w.path())
    }

    // 8. 遍历结束再删：上传的文件活到走完目录树才收拾，重复运行才安全（幂等）
    @ftp.delete(client, renamed)

    // 9. 退出：发 QUIT 并标记为已关闭（底层 socket 的处理见下方说明）
    @ftp.quit(client)
  }
  ignore(demo)
}
```

> 这个代码块用 `moonbit check` 标注，因此它**真的会被 `moon check` 类型检查**，
> 不是只做语法高亮：把它单独跑一遍 `moon check --target native --deny-warn` 也是绿的。
> 写法上按 `--deny-warn` 的标准收紧了尾巴：
>
> - 例子里是 `async fn demo() -> Unit` 而不是 `async fn main`：`main` 只允许出现在
>   可执行包里（`pkgtype(kind: "executable")`），写进 README 这种普通包会报
>   `Unexpected main function in the non-main package`，所以用 `test { ... }` 包一层、
>   换个名字，语义不变。
> - `main` / `demo` 的返回类型必须是 `Unit`，标注成别的反而报错。
> - 读到的内容要被 `println` 接住，`let bytes` 不消费会触发 unused warning。
> - 上传的 `@io.MemoryReader` 绑到变量再 `defer close()`：它的后台生产者只能这样停，
>   传输失败时没人关它，事件循环会以死锁 panic 收场。
>
> 要真的跑起来，把同样的代码放进 `cmd/example/main.mbt` 那种可执行包里
> （`moon.pkg` 声明 `pkgtype(kind: "executable")` + `supported_targets = "+native"`），
> 用 `async fn main` 去掉外层 `test { }` 即可 `moon run --target native`。

### 常用函数

下面这些函数**都是 `async`**，调用方需处在 `@async` 运行时中（`async fn main` 或
`test { }` 块内）；`walk` 本身是普通函数，但它的 `Walker::next` 是 `async`。

| 函数 | 作用 |
| --- | --- |
| `dial(addr, ..)` | 建连，可选 `explicit_tls` / `tls` / `timeout_ms` / `trust_pasv_ip` 等参数 |
| `login(client, user, pass)` | `USER`/`PASS` 登录，随后按上游顺序协商：`FEAT` → `TYPE I` → `OPTS UTF8 ON`（能力与开关都满足时）→ `PBSZ 0`/`PROT P`（TLS 时） |
| `list(client, path)` | 列目录，返回 `Array[Entry]`（MLSD / LIST 自动回退） |
| `name_list(client, path)` | `NLST`，只拿名字，返回 `Array[String]` |
| `get_entry(client, path)` | `MLST` 取单个条目的 facts |
| `retr` / `retr_from(client, path, offset)` | 下载 / 断点续传下载，返回 `DataResponse`（`read` 后必须 `close`） |
| `stor` / `append(client, path, reader)` | 上传 / 追加，`reader` 由调用方负责 `close` |
| `file_size(client, path)` | `SIZE` |
| `get_time(client, path)` / `set_file_time(client, path, time)` | `MDTM` 读 / 写时间戳 |
| `make_dir` / `remove_dir` / `remove_dir_recur` / `delete` / `rename` / `change_dir` / `change_dir_to_parent` / `current_dir` | 目录与文件管理（`remove_dir_recur` 递归删除非空目录） |
| `walk(client, root)` | 普通函数，拿到 `Walker`；`while w.next() { ... }` 深度优先遍历，`next()` 是 `async` 且失败时不抛错而是返回 `false`（原因读 `w.err()`） |
| `no_op` / `logout` / `quit(client)` | `NOOP` / `REIN` / `QUIT`（`quit` 发 `QUIT` 并标记为已关闭；socket 不做显式 close，见下方"连接与关闭语义"） |

> 错误以 `FtpError` 抛出，可用 `catch` / `try!` 统一处理；多次失败会被聚合成
> `FtpErrors::MultipleErrors` 一起报，而不是遇到第一个就吞掉。`list` / `walk`
> 解析不出的行会被跳过而非中断。

### 连接与关闭语义

`quit` 发 `QUIT`，然后把客户端标记为已关闭（之后再调 `quit` 是空操作，`is_closed()` 返回 `true`）。
它**不**关闭底层 socket：`Control` 没有 `close` 方法，也没有任何路径调用 `@socket.Tcp::close`。
关闭由两端各自完成——服务端收到 `QUIT` 后回包并关闭它那一侧，进程退出时本地的句柄随之释放。

这与上游 Go 版**不同**：上游 `Quit` 会显式 `c.conn.Close()`，再把这条关闭错误与命令错误一起
`errors.Join`。本仓库删掉了那一步，所以 `quit` 的错误列表里最多只有 `QUIT` 命令本身的一个错误，
"聚合"是上游 `errors.Join` 的形状，不是当下的必要性。因此也不要指望 `quit` 之后 socket 立刻
读到一个 EOF——那要靠服务端关闭它那一侧。

与之互补的是 `logout`（`REIN`）：它丢弃登录态但**保留**控制连接，可以继续在这条连接上 `USER`/`PASS`。

> `FtpErrors::MultipleErrors` 一起报，而不是遇到第一个就吞掉。`list` / `walk`
> 解析不出的行会被跳过而非中断。

## 开发

### 依赖安装

除 MoonBit 工具链外，本仓库的 `moon` 命令与自测脚本还有这些外部依赖，装不齐会在
完全无关的步骤上报错，所以先装好：

| 依赖 | 谁需要它 | 安装（Debian / Ubuntu） |
| --- | --- | --- |
| `gcc` + `libc6-dev` | **所有 `--target native` 的编译与链接**。native 后端没有 C 工具链连不出可执行文件，`moon.pkg` 因此声明 `preferred_target = "native"` | `sudo apt-get install -y gcc libc6-dev` |
| `openssl` | FTPS：`scripts/ftps/gen-cert.sh` 每次签发自签名 CA + 叶证书，`scripts/ftps/probe-ftps.sh` 用 `s_client` 做就绪握手 | `sudo apt-get install -y openssl` |
| `python3` | `scripts/` 下所有 `*-selftest.py` 无 Docker 自测 | `sudo apt-get install -y python3` |
| `docker` | 仅"本地端到端"那一层需要（拉 `jmoyer/vsftpd` / `bfren/ftps` 镜像）。不需要跑真实服务器测试时可以完全不装 | 见 [Docker 官方安装](https://docs.docker.com/engine/install/) |

MoonBit 工具链本身：

```bash
curl -fsSL https://cli.moonbitlang.cn/install/unix.sh | bash
export PATH="$HOME/.moon/bin:$PATH"
```

> `moon test --target native` 还有一个**仓库内的前置条件**：`testdata/ftp/tls` 里的
> 证书必须先由 `scripts/ftps/gen-cert.sh testdata/ftp/tls` 生成。有一条零字节 TLS 上传的
> 白测要讲**服务端** TLS，只能从磁盘上的证书构造。没生成的话失败信息是
> `transfer_wbtest.mbt:386 FAILED: stor_from: Cancelled`——一个任务组的取消，读起来像库
> 的 bug，而真正原因只是没人签发过证书。`scripts/ci.sh` 因此在任何测试之前先跑
> `gen-cert.sh`，并用 `tls-fixture-selftest.py` 断言这一步真的发生过。

### 常用命令

所有 `moon` 命令都带上 `--target native`：模块声明了 `preferred_target = "native"`，
wasm / wasm-gc 后端没有真实网络栈。

```bash
moon update                              # 首次 / 依赖变动后：拉取 registry 索引
moon fmt --check                         # 格式检查
moon check --target native --deny-warn   # 类型检查，要求 0 warning
moon test --target native --deny-warn    # 单元测试（含 --enable-coverage 与覆盖率报告）
moon build --target native               # 构建
moon build --target native --release     # release 构建
moon info                                # 更新生成接口（.mbti）
```

提交前请确认下面三条**均通过**（与 `scripts/ci.sh` 用的是同一条命令，不是近似版）：

```bash
moon fmt --check
moon check --target native --deny-warn
moon test --target native --deny-warn
```

`moon test` 前面记得先 `scripts/ftps/gen-cert.sh testdata/ftp/tls`（见上文"依赖安装"）。
想省事可以直接 `bash scripts/ci.sh`，它按同样顺序跑完 check / test / build / 真实服务器
演示，并在失败时导出容器日志。

### 测试分层

| 层 | 命令 | 覆盖 |
| --- | --- | --- |
| 纯逻辑单测 | `moon test --target native --deny-warn` | 四种列表解析、状态码、路径 join、控制通道帧解析 |
| 明文端到端 | `scripts/start-ftp.sh` + `cmd/example/run.sh` | 真实 vsftpd 上的 dial / login / list / retr / stor / rename / mkdir / walk |
| **能力画像端到端** | `cmd/profiles/run.sh <画像>` | 同一个 vsftpd 上四个客户端画像（`full` / `no-mlst` / `no-time` / `no-epsv`）：`FEAT`、`MLSD`/`LIST`、`EPSV`/`PASV`、`STOR`/`RETR`/`NLST`、`MDTM` 读+写、`MKD`/`RMD`/`RemoveDirRecur`。CI 逐个画像各调一次（每次前面插一次 `scripts/ensure-ftp.sh` 复检容器） |
| **FTPS 端到端** | `scripts/ftps/start-ftps.sh` + `cmd/ftps/run.sh` | 真实 vsftpd 上的**显式 `AUTH TLS`**：dial / login / LIST / RETR / STOR / DELE |
| 明文回归 | `cmd/ftps/run.sh plain` | 同一个 `cmd/ftps` 二进制走明文链路，确保数据通道时序改动没有破坏无 TLS 路径 |
| 无 Docker 自测 | `scripts/` 下的 `*-selftest.py` | 拉镜像之前就跑：FTPS 就绪探测、`cmd/ftps`（含 `STOR` 被拒回归）、`cmd/profiles` 的协议选择断言、两个容器不共用 fixture、`start-ftp.sh` 传给镜像的 10 个环境变量非空、`ensure-ftp.sh` 的复检三分支与它在 `ci.sh` 中的位置、`cmd/ftp/run.sh` 不拼 flag |

### 本地端到端（需要 docker）

```bash
scripts/start-ftp.sh          # 明文 vsftpd，127.0.0.1:21
cmd/example/run.sh            # 明文演示：dial / login / list / retr / stor / rename / mkdir / walk
cmd/profiles/run.sh           # 四个能力画像，都打这个容器（也可 cmd/profiles/run.sh no-epsv 只跑一个）
scripts/ftps/start-ftps.sh    # FTPS vsftpd，127.0.0.1:2121
cmd/ftps/run.sh               # 显式 AUTH TLS
cmd/ftps/run.sh plain         # 明文回归
scripts/ftps/stop-ftps.sh
scripts/stop-ftp.sh
```

这一层还有一条硬性约定：`scripts/ftps/gen-cert.sh` 每次重新签发证书并写进
`testdata/ftp/tls`（gitignored），客户端用 `trust=@tls.TrustedRoot::CustomPemFile(...)`
注入它，**证书校验始终开启**——不要为了跑通把它关掉。

不需要 Docker 也能跑其中一层：`scripts/profiles/ftp_profile_mock.py` 是一个带真实文件系统的
FTP mock，`scripts/profiles/cmd-profiles-selftest.py` 用它驱动真的 `cmd/profiles`，并逐条核对
每个画像实际发出的命令（`LIST` 还是 `MLSD`、`PASV` 还是 `EPSV`、有没有写时间戳）——
这些在真实服务器上看不出来，因为它两种被动命令都支持、两种列表都出结果。

mock 还必须按**容器**的形状回答 `NLST`：vsftpd 对 `NLST <dir>` 返回完整路径而不是裸文件名
（RFC 3659 §4.1 两者都允许），而这个差别在只跑 mock 时是隐形的——所以自测会直接向 mock
探测它的 `NLST` 形状，两边一旦不一致就立刻报错。

FTPS 用自签名 CA，客户端始终校验证书；两种传输方式共用同一个 `cmd/ftps` 二进制。

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
├── control.mbt                控制通道：命令编码、多行响应、状态码校验            IO
├── debug.mbt                  流量日志（DebugLog / MirrorWriter / TeeLogReader）  IO
├── transport.mbt              EPSV / PASV / PRET / REST / 数据连接 / TLS 建立        IO
├── client.mbt                 FTPClient + Session / Options + DialOptions + 时间/大小   IO
├── dial.mbt                   dial / 登录 / FEAT 能力协商                           IO
├── commands.mbt               CWD / PWD / MKD / RMD / DELE / RNFR+RNTO / QUIT       IO
├── list.mbt                   目录列表
├── transfer.mbt               文件传输（RETR / STOR / APPE / REST）
├── walker.mbt                 目录树遍历
├── cmd/ftp/                   CLI 示例：ls / get / put / walk / mkdir / rm
│   ├── main.mbt
│   └── run.sh                 设置 FTP_* 环境默认值后原样转发 argv
├── cmd/example/               真实 vsftpd 端到端演示（明文）
│   ├── main.mbt
│   └── run.sh                 跑 cmd/example（无参数）
├── cmd/ftps/                  FTPS / 明文端到端冒烟：参数选择传输方式
│   ├── main.mbt
│   └── run.sh                 读 .ftp-tls.env 跑 cmd/ftps（可传 plain）
├── cmd/profiles/              四个客户端能力画像的端到端测试（同一个容器）
│   ├── main.mbt               full / no-mlst / no-time / no-epsv，各自的开关与断言
│   └── run.sh                 设置 FTP_TEST_* 环境默认值后跑 cmd/profiles
├── scripts/
│   ├── ci.sh                  CI 入口脚本（check / test / build / 演示的唯一入口）
│   ├── start-ftp.sh           启动明文 vsftpd 容器（127.0.0.1:21）
│   ├── probe-ftp.py           明文容器就绪探测（登录 + 一次被动 LIST）
│   ├── ensure-ftp.sh          客户端之间复检明文容器，挂了就用 start-ftp.sh 重启
│   ├── ensure-ftp-selftest.py 用桩 docker 自测上面的复检（无需 Docker）
│   ├── ftp-wrapper-selftest.py    断言 cmd/ftp/run.sh 只传环境默认值、不拼 flag（无需 Docker）
│   ├── vsftpd-env-selftest.py      断言 start-ftp.sh 传齐镜像入口要的 10 个变量（无需 Docker）
│   ├── stop-ftp.sh            导出明文容器日志并清理
│   ├── ftps/                  FTPS（显式 AUTH TLS）容器
│   │   ├── gen-cert.sh        自签名 CA + 叶证书（每次重新签发，写进 testdata/ftp/tls）
│   │   ├── probe-ftps.sh      就绪探测：AUTH TLS 握手 + 证书校验
│   │   ├── probe-ftps-selftest.py  用 mock 服务器自测上面的探测（无需 Docker，用法见下）
│   │   ├── ftp_mock.py        明文 FTP mock，供 cmd-ftps-selftest.py 驱动真实二进制
│   │   ├── cmd-ftps-selftest.py    无 Docker 跑 cmd/ftps plain（含 STOR 被拒的回归用例）
│   │   ├── fixture-isolation-selftest.py  断言两个容器不共用可写 fixture
│   │   ├── tls-fixture-selftest.py  断言 moon test 要的证书在跑之前已被签发（无需 Docker）
│   │   ├── start-ftps.sh      启动 FTPS 容器（127.0.0.1:2121）并写 .ftp-tls.env
│   │   └── stop-ftps.sh       导出容器日志并清理
│   └── profiles/              cmd/profiles 的无 Docker 自测
│       ├── ftp_profile_mock.py        带真实文件系统的 FTP mock
│       └── cmd-profiles-selftest.py   驱动真程序并核对每个画像发出的命令
├── testdata/ftp/              测试与演示使用的 fixture
│   └── tls/                   gen-cert.sh 每次现签的 CA + 叶证书（gitignored，
│                              `moon test` 的前置条件，见"开发 → 依赖安装"）
├── docs/                      移植方案（porting.md）与设计文档（proposal.md）
├── moon.pkg                   根包清单
└── moon.mod                   模块定义
```

纯逻辑与 IO 源码同属一个包，分层约束通过每个源文件头部的 `// Layer:` 注释标记。

> **`probe-ftps-selftest.py` 的用法**：`python3 scripts/ftps/probe-ftps-selftest.py PROBE [CA_FILE]`。
> `PROBE` 是被测的探测脚本（`scripts/ftps/probe-ftps.sh`），`CA_FILE` 可选，默认用自测现场
> 现签的那张 CA（正是 mock 出示的证书的签发者）。
> 第一个参数是脚本路径，**不是**仓库根目录——把 `$PWD` 之类的路径传进去，它会被当成 `PROBE`，
> 于是报出 `bash /gen-cert.sh: exit 127` 这种与真实原因无关的错。`scripts/ci.sh` 只传 `PROBE`。

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
