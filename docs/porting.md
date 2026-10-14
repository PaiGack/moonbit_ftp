# `jlaffaye/ftp` → MoonBit 移植方案

> 目标项目：[jlaffaye/ftp](https://github.com/jlaffaye/ftp)（Go 语言 FTP 客户端库，RFC 959）
> 分析对象：`master` 分支（约 1.4k stars / 382 forks，ISC License）
> 本文档用于指导 `PaiGack/ftp` 的 MoonBit 移植工作。

---

## 1. 上游项目分析

### 1.1 项目定位

`jlaffaye/ftp` 是一个纯 Go 实现的 FTP 客户端库，遵循 RFC 959，并额外支持：

- RFC 2389（`FEAT` 特性协商）
- RFC 3659（`MLST` / `MLSD` / `SIZE` / `MDTM` / `MFMT`）
- RFC 4217（显式 / 隐式 FTPS，`AUTH TLS` / `PBSZ` / `PROT P`）
- 被动模式，`EPSV`（RFC 2428）优先、`PASV` 回退；主动模式（`PORT` / `EPRT`）不做
- 常见服务器的兼容性处理（VsFtpd、ProFTPD、Serv-U、hostedftp、Windows IIS、WFTPD 等）

它的价值在于**不是简单封装 socket**，而是把 FTP 这套"文本控制通道 + 独立数据通道"协议的
各种历史包袱、服务器差异、目录列表格式差异都收敛成一套简洁的 Go API。

### 1.2 源码结构（约 1.86k 行实现 + 1.41k 行测试）

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `ftp.go` | 1191 | 核心：连接、登录、控制命令、数据传输、目录操作 |
| `parse.go` | 277 | LIST / MLSD / DOS DIR / hostedftp 等列表行的解析 |
| `status.go` | 119 | RFC 959 状态码常量与文本 |
| `scanner.go` | 58 | 按空白切分的字段扫描器 |
| `walker.go` | 98 | 目录树遍历器（`Walk` / `SkipDir` / `Stat` / `Path`） |
| `debug.go` | 37 | 调试输出包装（TeeReader / MultiWriter）——**已移植**，重构后落在 `debug.mbt`，接线点见第 3 节 |

### 1.3 功能矩阵

**连接与选项（Dial + 16 个 `DialWith*` 选项函数）**

- `Dial` / `Connect` / `DialTimeout`，默认 30s 超时
- 超时、上下文、自定义 dialer、自定义 dial 函数
- TLS：隐式 TLS、显式 TLS（`AUTH TLS` 升级）
- `EPSV` 禁用、`PASV` 返回 IP 信任开关（防 SSRF）、UTF8 禁用、MLSD 禁用、`MDTM` 写时间、强制 `LIST -a`、时区、调试输出（`set_debug_sink`，默认关闭）

**认证**

- `Login(user, password)`：`USER` / `PASS`，成功后探测 `FEAT`，按需 `OPTS UTF8 ON`、`PBSZ 0` / `PROT P`
- `Logout`（`REIN`）、`NoOp`（`NOOP`）、`Quit`（`QUIT`）

**数据传输**

- 取文件：`Retr` / `RetrFrom(offset)` → `DataResponse`（可读、幂等 `close`；**没有** `SetDeadline`，见下。注意与只表示一条控制通道回复的 `Response` 不是同一个类型）
- 存文件：`Stor` / `StorFrom(offset)` / `Append`
- 目录列表：`List`（`MLSD` 优先，回退 `LIST [-a]`）、`NameList`（`NLST`）、`GetEntry`（`MLST`）

**文件/目录操作**

- `ChangeDir` / `ChangeDirToParent` / `CurrentDir`
- `MakeDir` / `RemoveDir` / `RemoveDirRecur` / `Delete` / `Rename`
- `FileSize` / `GetTime` / `SetTime` 及 `IsGetTimeSupported` / `IsSetTimeSupported` / `IsTimePreciseInList`
- `Walk(root) *Walker` 目录树遍历

**数据模型**

- `Entry{Name, Target, Type, Size, Time}`，`EntryType ∈ {File, Folder, Link}`
- `TransferType ∈ {Binary("I"), ASCII("A")}`
- 49 个 `status_*` 常量（其中 48 个状态码，多个常量刻意共用同一个数值，因为 RFC 本身复用了码）+ `status_text(code)`

### 1.4 关键实现要点（移植时必须保留的"隐性知识"）

1. **数据通道生命周期**：上游 `cmdDataConnFrom` 统一处理 `PRET` 预热 → 建数据连接 → 可选 `REST offset` → 发传输命令 → 校验 `125/150`；非 `2xx` 时关闭数据连接并返回 `textproto.Error`。本仓库对应 `transport.mbt` 的 `cmd_data_conn_from`，错误类型是 `FtpError::ServerError`。
2. **关闭语义**：数据传输结束后必须回控制连接读 `226/250`（上游 `checkDataShut`，本仓库 `transfer.mbt` 的 `check_data_shut`），否则后续命令会错位。`ShutTimeout` 在本仓库是 `DialOptions::set_shut_timeout_ms`，只在 `DataResponse::close` 读 `226` 前推一下控制通道 deadline。
3. **错误聚合**：Go 的 `errors.Join` 被大量使用（`Quit` / `Stor` / `Append` / `List` / `Response.Close`），即「传输错误 + 关闭错误 + 状态读取错误」要一起返回。本仓库对应 `error.mbt` 的 `join_errors` / `FtpErrors::MultipleErrors`。
4. **命令注入防护**：上游 `checkForCommandInjection` 拒绝参数中含 `\r` / `\n`，对应 `ErrInvalidCommand`；本仓库是 `control.mbt` 的 `check_for_command_injection` + `FtpError::InvalidCommand`。
5. **EPSV 回退**：`EPSV` 失败一次后置 `skipEPSV`，后续走 `PASV`；本仓库是 `Session::set_skip_epsv` / `Session::skip_epsv`。
6. **PASV 防 SSRF**：默认使用控制连接的 IP，仅当显式信任（`trust_pasv_ip`）且数据 IP 非组播/私网跨界的「可疑 IP」时才用 PASV 返回的 IP；判定在 `transport.mbt` 的 `is_bogus_data_ip`。
7. **TLS 数据连接**：不能直接用 `tls.DialWithDialer`（proftpd/pureftpd 会挂），需 `Dial` + `tls.Client` 延迟握手；零字节上传需显式 `Handshake()`。**本仓库的口径差异见第 3 节**：`@tls.Tls::client` 构造时即握手，所以「延迟到 `150` 之后」由调用时机保证，零字节分支那次调用是显式记账而非第二次握手。
8. **LIST 解析容错**：依次尝试 RFC3659 → Unix ls → DOS DIR → hostedftp 四种解析器，全部失败才报 `UnsupportedListLine`；时间字段有"半年规则"（无年份且超过 6 个月视为去年）。
9. **`Close` 幂等**：`Response.Close` 二次调用返回 nil。本仓库对应 `DataResponse::close` 的 `closed` 标志（`transfer.mbt`）。

---

## 2. 移植策略

### 2.1 总体原则

**保协议语义、改语言惯用法。** 不逐行翻译 Go，而是保留：

- 对外 API 的形状（可选参数 → MoonBit 的 `label~`，错误 → `raise`/`Result`）
- 协议行为（命令序列、状态码校验、回退逻辑）
- 兼容性细节（上面 1.4 的 9 点）

同时做以下 MoonBit 化改造：

| Go 概念 | MoonBit 对应 |
| --- | --- |
| `error` 返回值 | `raise` + 自定义 `suberror`（协议错误 / IO 错误 / 不支持） |
| `errors.Join` | 累积 `Array[Error]`，最后统一抛出（或 `ErrorGroup` 类型） |
| `io.Reader` / `io.Writer` | `@async.io.Reader` / `@async.io.Writer`（trait） |
| `net.Conn` | `@async.socket.Tcp` / `@async.tls.Tls` |
| `context.Context` | `moonbitlang/async` 的 `with_timeout` / 取消机制 |
| `tls.Config` | `@async.tls.Tls::client(trust~, host~)` |
| `time.Time` | `moonbitlang/x/time` 或自实现 RFC 时间工具 |
| `textproto.Conn` | 自实现控制通道（带行缓冲的多行响应解析） |

### 2.2 依赖选型

- **`moonbitlang/async`（native target）**：提供 `socket.Tcp`、`socket.Addr` 及 `tls.Tls`，是官方异步 I/O 库，覆盖被动/主动连接、TLS、超时、取消。
  - 移植项目的 `preferred_target` 应从当前的 `wasm` 改为 `native`（FTP 需要真实网络栈）。
- **`moonbitlang/x`**：时间、编码等工具（按需引入）。
- 不做第三方 FTP 依赖（mooncakes.io 上目前**不存在** FTP 客户端库，已检索确认）。

> 说明：选择异步栈而非阻塞 C FFI，是因为 `moonbitlang/async` 是官方维护、跨平台、且已包含 TLS；
> 同时 MoonBit 的 `async` 语法能让"控制通道等待响应"与"数据通道读写"自然并行。

### 2.3 包结构设计

源码全部平铺在仓库根目录，只有一个包 `PaiGack/ftp`，没有子目录，也没有 `src/` 中间层。
引用直接写裸符号（`Entry` / `parse_list_line`），不再有 `@types.` / `@parse.` 前缀。

```
.
├── entry.mbt                 Entry / EntryType / TransferType            纯逻辑
├── status.mbt                RFC 959 状态码常量 + status_text()            纯逻辑
├── error.mbt                 FtpError / FtpErrors（join_errors）          纯逻辑
├── parse.mbt                 RFC3659 / ls / DIR / hostedftp 列表解析      纯逻辑
│                             时间字段解析 + 空白字段扫描器
├── pathutil.mbt              远端路径 join                               纯逻辑
├── control.mbt               控制通道：命令编码、多行响应、状态码校验        IO
├── debug.mbt                 流量日志（DebugLog / MirrorWriter / TeeLogReader）IO
├── transport.mbt             EPSV / PASV / PRET / REST / 数据连接 / TLS   IO
├── client.mbt                FTPClient + Session / Options + DialOptions   IO
│                             file_size / get_time / set_file_time          IO
├── dial.mbt                  拨号 + 登录 + FEAT 能力协商                   IO
├── commands.mbt              CWD / PWD / MKD / RMD / DELE / RNFR+RNTO / QUIT 等  IO
├── list.mbt                  NLST / LIST / MLST + set_transfer_type        IO
├── transfer.mbt              DataResponse：RETR / STOR / APPE / REST       IO
├── walker.mbt                目录树遍历（walk / Walker）                   IO
├── cmd/                      CLI 与端到端程序：ftp / example / ftps / profiles
├── scripts/                  容器生命周期、就绪探测、无 Docker 自测
├── docs/                     porting.md（本文）+ proposal.md
└── testdata/                 测试与演示 fixture（`ftp/tls` 由 gen-cert.sh 现签）
```

分层依赖（文件级）：纯逻辑（`entry` / `status` / `error` / `parse` / `pathutil`）←
`control` ← `transport` ← `client` ← `walker`。
`parse` / `walker` / `pathutil` 不碰网络，可独立单测。

平铺之后编译器不再按包隔离，分层约束改由文件头部的 `// Layer:` 标记 +
本节的分组目录树守住，review 与新增文件时按它核对。

> 这棵树与仓库的实际布局之间不允许漂移：`README.mbt.md` 的"目录结构"一节是同一份
> 内容的用户视角版本，两边改动要一起改。

### 2.4 API 映射示例

```moonbit
// Go: c, err := ftp.Dial("ftp.example.org:21", ftp.DialWithTimeout(5*time.Second))
let c = try @ftp.dial("ftp.example.org:21", timeout_ms=5000) catch { ... }

// Go: err = c.Login("anonymous", "anonymous")
@ftp.login(c, "anonymous", "anonymous")

// Go: r, err := c.Retr("a.txt"); buf, _ := io.ReadAll(r); r.Close()
let r = @ftp.retr(c, "a.txt")
let buf = r.reader.read_all() catch { _ => b"" }
r.close()

// Go: entries, err := c.List(".")
let entries = @ftp.list(c, ".")

// Go: w := c.Walk("/root"); for w.Next() { fmt.Println(w.Path(), w.Stat()) }
//
// `walk` 本身是普通函数，`Walker::next` 才是 async：它要 `LIST` 一层目录，
// 所以必须让出事件循环。上游 `w.Next()` 是阻塞调用，这里把"让出"显式化。
let w = @ftp.walk(c, "/root")
while w.next() {
  println(w.path())
}
```

> 这段示例是**给人读的口径对照**，不是仓库自身的回归测试，因此代码块用普通
> `moonbit` 围栏（只做高亮、不进 `moon check`）。会被检查的文档代码块见
> `README.mbt.md` 的快速开始——那里用 `moonbit check`，且必须在
> `moon check --target native --deny-warn` 下干净通过。

设计约定：

- 所有可能失败的调用 `raise`，错误类型统一继承 `FtpError`。
- 可选参数一律用 `label=value`（如 `timeout_ms=5000`、`location=zone`、`disable_epsv=true`），
  声明处写成 `label? : T = default`，避免 Go 的 `...DialOption` 变参。
- `DialOption` 语义用 `DialOptions` 结构体承载，所有字段都有文档化的默认值，
  所以 `dial(addr)` 单独就是一个合法调用；`set_*` 方法用于构造后调整。

### 2.6 测试策略

1. **纯逻辑单测**：直接搬运上游 `parse_test.go` / `scanner_test.go` / `constants_test.go` 的用例集
   （UNIX ls、`ls -l` 变体、ACL `+` 权限、hostedftp、DOS DIR、RFC3659、符号链接、多空格文件名、非法行、半年时间规则）。
2. **真实 FTP 服务器端到端**：CI 中通过 `scripts/start-ftp.sh` 起**一个** `jmoyer/vsftpd`
   （vsftpd 3.0.5）容器，`cmd/profiles` 用它跑四个**客户端**能力画像
   （`full` / `no-mlst` / `no-time` / `no-epsv`）。画像是客户端的，不是服务器配置：
   容器照常开满能力，四个画像各拨号一次、各自关掉一个客户端的开关，所以
   "换掉一个能力"这件事只由客户端一侧构成，不需要多镜像、多容器。

   一个画像验证什么，按效果而非命令序列断言：

   | 画像 | 关掉什么 | 验证什么 |
   | --- | --- | --- |
   | `full` | — | `FEAT` 协商；`MLSD` 列表 + `EPSV` 传输；`MDTM` 读时间，并经 `MDTM <time> <path>` 写入后读回一致 |
   | `no-mlst` | `disable_mlsd` | 客户端改用 `LIST`（四种解析器回退）并给出与 `MLSD` 相同的条目与大小 |
   | `no-time` | `writing_mdtm=false` | `set_file_time` **如实拒绝**（`502`），且文件时间戳原样不动 |
   | `no-epsv` | `disable_epsv` | 所有传输走 `PASV`，`EPSV` 一次都不发 |

   每个画像都跑完 `FEAT` / `STOR` / `RETR` / `LIST` / `NLST` / `MDTM`（读+写）/
   `MKD` / `RMD` / `RemoveDirRecur`，最后 `DELE` + `RMD` 收摊，并打印服务器上剩下的整棵树，
   作为"改了什么、还剩什么"的副作用断言。

   `NLST` 的**形状由服务器决定**，不是客户端能选的：`NLST <dir>` 在 vsftpd 上返回每一项的
   完整路径（`/profiles_full/sample.txt`），在多数其它服务器上返回裸文件名，RFC 3659 §4.1
   两者都允许。所以断言只针对最后一段路径，绝不匹配整行——按裸名字匹配正是这个调用要抓的
   那类 bug。`cmd-profiles-selftest.py` 必须让 mock 按**容器**的形状回答（多一层
   `check_nlst_shape` 直接向 mock 探测），否则 mock 用裸名字、程序也按裸名字断言，两边一起
   绿，而真实容器上必红。

   `no-mlst` 与 `no-epsv` 的断言语义在真实服务器上**看不见**：容器两种被动命令都支持、
   `MLSD` 与 `LIST` 都能出结果，客户端选了哪一条在输出里没有痕迹。所以
   `scripts/profiles/cmd-profiles-selftest.py` 用 `ftp_profile_mock.py`（一个带真实文件系统
   的 mock）在**拉镜像之前**驱动真程序，再按画像逐条核对 mock 收到的命令流。
   这条自测做过反向验证：把 `disable_epsv` / `disable_mlsd` 各自摘掉，或把 mock 的 `NLST`
   换回裸名字，对应断言立即变红。

   程序里每个画像的失败都被 `fail` 重新抛出，带上画像名与真实原因；直接把 `FtpError` 抛到
   `main` 之外只会打印 `PaiGack/ftp.FtpError.ParseError`，没有画像、没有路径、没有解释。

   在 CI 里，四个画像**各自作为一次独立的 `cmd/profiles/run.sh <画像>` 调用**，每次调用前
   都插一次 `scripts/ensure-ftp.sh`。原因是这个程序一次开四个会话，而 `ensure-ftp.sh` 的
   守卫只能覆盖"客户端启动之前"那个窗口；四个会话**之间**的窗口它看不见。
   `cnb-ake-1k4qn4ukc` 就是这个形状：步骤前的守卫通过、`full` / `no-mlst` / `no-time` 全部
   跑完，第四次 `dial` 撞上一个已经死掉的容器，报出来却是

       Failure(cmd/profiles/main.mbt:61:12-61:57 FAILED: profile no-epsv: ReaderClosed)

   ——一个连问候语都没读到的 `dial`，被当成画像结果。紧跟着的
   `cmd/ftps/run.sh plain` 前的守卫发现容器没了、重启后该步通过，这才坐实问题在服务器而不在
   `disable_epsv`。`cmd/profiles` 因此接受一个可选的画像名参数（缺省仍跑全部四个），
   `ci.sh` 按名字逐个调用、逐个守卫；`ensure-ftp-selftest.py` 把 `ci.sh` 里的画像名与
   `profiles()` 对照，多一个少一个都是失败。
3. **帧解析用例**：用 `@io.MemoryReader` 精确构造畸形响应（畸形状态行、空行续行、两行 MLST），
   不需要假服务器也不需要 socket。
4. **边界用例**：命令注入、EPSV 被拒后回退、二次 `Close`、REST 断点续传、超时。
5. **FTPS 端到端**：`scripts/ftps/start-ftps.sh` 起 `bfren/ftps`（vsftpd 3.0.5，
   `force_local_data_ssl=YES`），自签名 CA 由 `gen-cert.sh` 现场签发、挂进容器，
   并以 `trust=CustomPemFile` 注入客户端（**校验保持开启**）。`cmd/ftps` 默认跑显式
   `AUTH TLS` 的 dial / login / list / retr / stor / dele，再用 `plain` 参数对明文容器
   跑同一段，确保数据通道时序的改动没有破坏无 TLS 路径。与明文演示共用 `scripts/ci.sh`
   这套编排，失败同样是硬失败。

   > 这一层不是可选的补充。1.4 第 7 条提到的"数据通道 TLS 握手时机"在本仓库里踩了四次：
   > `AUTH TLS` 发出去但没升级连接、显式 TLS 漏发 `PBSZ`/`PROT P`、隐式 TLS 根本没加密
   > 控制通道、TLS 数据连接关闭时不发 `close_notify`。四个都是"编译通过、单测全绿、
   > 连上明文服务器也一切正常"，只有对着真实 FTPS 服务器才会以"第一次读就挂住"暴露出来。
   >
   > 隐式 TLS（990）目前只到单元测试层：`dial(tls=true)` 在首个字节前包好控制通道，
   > 由 `tls_test.mbt` / `dial_wbtest.mbt` 覆盖，握手本身带超时。端到端没进 CI 是因为
   > 没有能同时讲好显式与隐式、且允许换成我们证书的镜像；在容器前套 `stunnel` 会把
   > "客户端握手时机是否正确"这个待测问题本身掩盖掉，所以宁可不跑，也不跑个假的绿灯。

   同一段编排里还有五道**无 Docker 的闸门自测**，都在任何容器之前跑：
   `probe-ftps-selftest.py` 驱动 `probe-ftps.sh`，`cmd-ftps-selftest.py` 用 `ftp_mock.py`
   驱动真实的 `cmd/ftps plain`，`fixture-isolation-selftest.py` 断言两个容器不共用可写的
   fixture 目录。第二条是这次 CI 失败的教训：`cmd/ftps` 把 `@io.MemoryReader` 直接写成
   `stor` 调用的临时参数，没人负责关它，`STOR` 被拒时它的后台生产者任务残留，事件循环以
   `Dead lock detected` panic 收场，整段 FTPS 于是看起来像 TLS 问题——而真正的错误
   （服务器回了什么）一个字都没打出来。失败路径必须有自己的测试，否则它只会在容器日志里
   现形。第三条是它把真正的错误露出来之后才看见的：`bfren/ftps` 初始化时递归 chown 自己的
   `/files` bind mount（`FTPS_VSFTPD_UID` 默认 1000），而那个目录正是明文容器的根目录，
   明文容器（uid 100）随即失去写权限、`STOR` 吃 `550`。跨容器的约定没有单容器测试看得见，
   所以单独写一条断言。

   `plain` 段还有一条自己的编排约束：它是最后一个需要明文容器的步骤，和「容器刚被探测为
   健康」之间隔着整段 FTPS（拉镜像、签 CA、二次握手、又一次 `docker run`）。在 CNB 的
   DinD 上容器确实在这中间死过，而客户端只会说

       ==> plain: dial 127.0.0.1:21
       OSError("@socket.Tcp::connect(): Connection refused")

   ——报的是端口，不是容器，看起来像明文链路回归，尽管 `cmd/example`、`cmd/ftp`、
   `cmd/profiles` 刚在同一端点上跑通。所以 `ensure-ftp.sh` 在这一步之前复检容器（既看
   是否在跑，也看是否答得出登录 + 一次被动 `LIST`；端口被发布不等于 vsftpd 在服务），
   不行就用 `start-ftp.sh` 重启，只有重启也救不回来才带着容器日志失败。
   `ensure-ftp-selftest.py` 用桩 `docker` 覆盖它的三个分支——放着健康的服务器不动、
   重启死掉的、重启无效就响亮地失败——这三者在真实容器上都看不出来，因为那里容器通常
   就是好的。

---

## 3. 与上游的差异与裁剪

**保留**：RFC 959 全量命令、EPSV/PASV、FTPS、列表四解析器、Walker、防注入、防 SSRF、调试输出、时间操作。

**调试输出**（`debug.go` → `debug.mbt` 的 `DebugLog`）与上游形似而接线点不同，
两处差异是刻意的，改动前请先读：

- 上游把开关（`DialWithDebugOutput`）编进 `wrapConn` / `wrapStream`，在 dial 时就把
  连接包成装饰器。本仓库改为**在 `Control` 上存开关、按行打点**：`AUTH TLS` 之后
  `Control::upgrade` 会整体换掉 reader/writer，dial 时装的装饰器会继续记录明文 socket，
  而真正在跑的 TLS 会话反而不进日志。按调用打点则两个方向自动同步。
- 上游只把连接包装出一个 `io.ReadWriteCloser`，方向靠"读端 tee / 写端 fan-out"隐式表达；
  本仓库给每条记录加显式方向标签（`>>> ` / `<<< `），两个方向即使被路由进不同的 sink
  也仍然自解释。`MirrorWriter` / `TeeLogReader` 就是上游 `MultiWriter` / `TeeReader` 的
  等价物，`Control` 直接走这两个装饰器。

**文件归属**：开关在 `Control` 上（`Control::set_debug`），记录器与两个装饰器在
`debug.mbt`。1.2 那张表里 `debug.go` 曾标注"已移植，见 `control.mbt`"，那既是过时的
位置，也暗示了上游那种 dial 时包连接的做法；本仓库的接线点见上面两条，位置是
`debug.mbt`。拆开的理由是这两个文件此后各自只有一个主题：`control.mbt` 讲命令成帧，
`debug.mbt` 讲记录，而 `Control` 只保留"要不要记"这一个决定。

日志是诊断，因此**不得改变协议行为**：sink 抛错只丢日志行，不影响命令与回复；回复读
的超时只包住 socket 读，装饰层不参与计时（AGENTS.md 的 deadline 规则），否则一个慢
sink 会被误报成 `RequestTimeout`。默认关闭，不装 sink 时路径上只有一次 `Option` 判断。

**Go 到 MoonBit 的取舍**（不是漏实现，是有意的口径差）：

- **`Response` 没有 `SetDeadline`。** 上游 `ftp.Response` 是 `net.Conn` 的包装， deadline
  可以逐连接设置；这里 `DataResponse` 只有 `read` / `close`，超时统一由 `Control::timeout_ms`
  管——而那条 deadline 只在**控制通道的回复读**上，数据通道的读写本身不计时（一个长列表
  只要服务器还在发就正常跑完）。取舍的理由：MoonBit 的 `@io.Reader` trait 上没有 deadline
  概念，把它加进来等于给每个 reader 装饰一层计时器，而 `AGENTS.md` 的 deadline 规则恰好要求
  计时只包住"空闲等待"那一段。需要整体超时的调用方用 `@async.with_timeout` 包住整个传输。
- **数据通道 TLS 握手是"调用即握手"，没有上游的惰性语义。** Go 的 `tls.Conn` 在首次读写时
  才握手，所以上游要在零字节上传后补一句 `Handshake()`；`@tls.Tls::client` 在**构造时**就
  握完，因此本仓库把握手放在 `cmd_data_conn_from` 收到 `150` 之后（RFC 4217 的正确时机），
  并让 `DataConn::start_tls` 幂等，`stor_from` 在零字节分支再调一次——调了不重复握手，删了
  也不影响行为。这一行保留是因为上游 1.4 第 7 条的承诺（"上传零字节文件时必须显式触发握手"）
  在 Go 里要靠它兑现，在这里它是对同一条承诺的显式记账；`transfer_wbtest.mbt` 里有一条真的
  TLS 服务器在数据口另一端断言它。

**明确不做（首版边界）**：

- `SITE` / `ACCT` / `APPE` 之外的扩展命令（如 `CCC`、`MODE`、`STRU`、`ALLO`）
- 主动模式（`PORT`/`EPRT`）——上游也只实现被动模式，保持一致
- FTP 代理（`HTTP CONNECT`）、SSH/SFTP
- 断点续传之外的并发分片下载
- WASM/JS 后端（FTP 依赖原生网络栈，首版只支持 `native`）

**可能增强**（作为项目亮点）：

- 基于 `moonbitlang/async` 的**并发传输**（`with_task_group` 并行多文件）
- 目录列表解析的**属性化测试**（对齐上游用例 + 随机 fuzz）
- 与 Go 版行为的**差分测试**记录

---

## 4. 许可证与合规

- 上游 `jlaffaye/ftp` 采用 **ISC License**（宽松，类 MIT）。
- 本仓库当前为 **Apache-2.0**。
- ISC 与 Apache-2.0 兼容：移植需在 README 与专门文档中**保留原始版权声明**并注明来源、链接、许可证及参考范围。
- 本项目将：
  1. 在 README 增加"致谢与来源"章节；
  2. 保留上游 ISC 许可证原文于 `docs/` 或 `LICENSE-THIRD-PARTY`；
  3. 若后续包含直接复制的代码片段，逐文件标注来源。

---

## 5. 风险与应对

| 风险 | 说明 | 应对 |
| --- | --- | --- |
| 异步栈 API 变动 | `moonbitlang/async` 仍在快速迭代（0.x） | 锁定版本；把 socket/TLS 调用收敛到 `transport` 一层，便于替换 |
| 无阻塞式同步 socket | MoonBit 无 Go 式阻塞 IO；需 async 语法 | 纯逻辑层与 IO 层解耦，核心解析零 IO |
| TLS 数据连接兼容性 | Go 版有 proftpd/pureftpd 的坑 | 复刻"延迟握手 + 零字节显式 handshake"逻辑 |
| 时间类型差异 | Go `time.Time` 精度/时区语义丰富 | 用 UTC 内部表示 + 自定义 `parse_time`/`format_time`，严格对齐格式串 |
| 测试需要真实网络 | 部分用例依赖 socket | 端到端用例跑真实服务器（CI 起容器），不用 mock 顶替；失败路径另由无 Docker 的闸门自测用 mock 覆盖（见 2.6） |

---

## 6. 验收清单

- [ ] MoonBit 为主要实现语言
- [ ] 源码结构清晰，可完成声明的核心功能
- [ ] README 说明目标、安装、用法、示例且可复现
- [ ] CI 覆盖检查 / 构建 / 测试
- [ ] 至少一个可运行示例（如 CLI `moon run cmd/ftp`，支持 `ls` / `get` / `put`）
- [ ] 完整测试覆盖核心路径（解析 + 协议序列 + 边界）
- [ ] 发布到 mooncakes.io
- [ ] OSI 许可证 + 上游来源注明

---
