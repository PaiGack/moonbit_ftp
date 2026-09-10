# 01 目标架构

## 1. 设计原则

**纯协议逻辑与网络 IO 彻底分离。**

理由有三条，都是实打实的：

1. 上游 `parse_test.go` 有 30+ 条 `LIST` 行用例，全部是纯字符串进、结构体出。只要解析层不碰 socket，这些用例可以原样搬过来跑，不用 mock 网络。
2. `moonbitlang/async` 还是 0.x，API 会变。把 socket/TLS 调用收敛到 2 个包内，破坏性变更时只改这两层。
3. MoonBit 的 `raise` + `suberror` 在纯逻辑层能表达得很干净；混进 IO 之后错误语义会糊。

## 2. 包结构

所有源码**直接平铺在仓库根目录**，没有包目录层级。`moon.mod` 声明的模块是 `PaiGack/ftp`，
根目录就是唯一的源码包，包引用写 `Entry` / `parse_list_line` 这样的裸名字，而不是
`@types.Entry` / `@parse.parse_list_line`。

> 2026-09 的调整：最初的设计是「包平铺在根目录、但每个领域一个包」（`types/`、`parse/`、
> `client/` …）。实现完成后发现这些包加起来只有约 4.4k 行，绝大多数跨越包边界的引用
> （`@types.` 78 处、`@error.` 67 处、`@status.` 41 处）只换来了一层前缀，没有换来任何
> 可见的封装收益。于是把 12 个包全部展开成根目录下的 `.mbt` 文件。

```
.
├── entry.mbt / consts.mbt            数据模型与常量                        纯逻辑
├── status.mbt                        RFC 959 状态码 + status_text()        纯逻辑
├── error.mbt                         FtpError / FtpErrors                 纯逻辑
├── scanner.mbt                       LIST 行字段扫描器                      纯逻辑
├── parse.mbt                         四种解析器的入口                       纯逻辑
├── parse_rfc3659.mbt                 RFC 3659 MLSD/MLST                    纯逻辑
├── parse_unix_ls.mbt                 ls -l 风格                            纯逻辑
├── parse_dos_dir.mbt                 MS-DOS DIR 风格                       纯逻辑
├── parse_hostedftp.mbt               hostedftp.com 风格                    纯逻辑
├── parse_time.mbt                    LIST 时间字段解析（含半年规则）          纯逻辑
├── pathutil.mbt                      Go path.Join 语义的远端路径拼接          纯逻辑
├── control.mbt                       控制连接（reader/writer/TLS 升级）       IO
├── command.mbt                       命令编码与状态码校验                    IO
├── response.mbt                      响应解析（单行 / 多行）                  IO
├── state.mbt                         client 与 transport 共享的连接状态       IO
├── transport_epsv.mbt                EPSV                                   IO
├── transport_pasv.mbt                PASV + 防 SSRF 校验                     IO
├── transport_dataconn.mbt            数据连接开启流程 + TLS 延迟握手           IO
├── client.mbt                        FTPClient 结构与能力缓存                 IO
├── options.mbt                       DialOptions + setter                   IO
├── dial.mbt                          dial / split_addr / parse_decimal      IO
├── login.mbt                         USER/PASS/FEAT/AUTH/TYPE/PBSZ/PROT     IO
├── nav.mbt                           cwd / cd / cd_up / extract_quoted      IO
├── list.mbt                          NLST / LIST / MLSD / MLST / TYPE       IO
├── client_time.mbt                   SIZE / MDTM / MFMT                     IO
├── transfer.mbt                      RETR / STOR / APPE / 226 收尾           IO
├── fsops.mbt                         MKD / RMD / DELE / RNFR+RNTO           IO
├── lifecycle.mbt                     NOOP / REIN / QUIT                     IO
├── walker.mbt                        目录树遍历器                            IO
├── debug.mbt                         控制/数据通道原始流量日志包装             IO
├── architecture.mbt                  架构守卫检查器
├── architecture/                     架构守卫的消费者（对真实 moon.pkg 断言）
├── cmd/ftp/                          CLI 示例
├── moon.pkg                          根包清单
└── moon.mod                          模块根
```

文件名的前缀不是随意的：同名函数在平铺之后会互相遮蔽，所以 IO 侧与纯逻辑侧撞名的
符号带了前缀，保持「一眼能看出属于哪一层」：

| 符号 | 位置 | 重命名原因 |
| --- | --- | --- |
| `set_time` | `parse_time.mbt`（纯逻辑） | 与 `client_time.mbt` 的公开 `set_time` 同名 |
| `set_file_time` | `client_time.mbt`（IO） | 上条的 IO 侧新名字，语义更明确 |
| `DateResponse` | `response.mbt`（控制通道响应） | 与 `transfer.mbt` 的 `DataResponse` 区分：一个是控制通道应答，一个是数据传输句柄 |
| `Response::code()` / `Response::message()` | `response.mbt` | 平铺后字段名与包名不再隔离，改成方法调用避免 `.message` 歧义 |

## 3. 依赖方向

```
entry ─┬─> status ──> error
       ├─> scanner ─> parse
       └─> pathutil
                       │
                (以下可依赖上面全部纯逻辑符号)
                       ▼
                  control ──> transport ──> client ──> walker
                                   │            │
                                   └──> debug <─┘
```

硬性约束：

- 纯逻辑文件（`entry` / `consts` / `status` / `error` / `scanner` / `parse*` /
  `pathutil`）**不得**依赖 `moonbitlang/async`。
- `parse*` 只接 `String` 和 `Entry`，绝不接 `Reader`。
- `client*` 不直接调 socket，所有连接建立走 `transport_*`。
- `walker` 只依赖 `client` 的公开符号。

平铺之后这些文件同属一个包，编译器不再帮忙拦跨层引用，所以改用**两个手段**保住约束：

1. 每个文件顶部的引用注释标明它属于纯逻辑还是 IO，review 时按注释核对；
2. `architecture/` 读取真实的 `moon.pkg` 并断言 `moonbitlang/async` 没有被复制出
   第二个普通 import 块 —— 一旦有人为了绕开依赖而拆块，测试立刻失败。

纯逻辑文件清单在 `architecture.mbt` 的 `pure_logic_packages` 里，也是可执行的。

## 4. 数据模型

```moonbit
///|
pub enum EntryType {
  File
  Folder
  Link
} derive(Eq, @debug.Debug)

///|
pub struct Entry {
  mut name : String       // 文件名（不含路径）
  mut target : String     // 符号链接目标，非链接时为空串
  mut type_ : EntryType
  mut size : UInt64
  mut time : @time.ZonedDateTime   // 解析到的时间（含时区）
} derive(Eq, @debug.Debug)

///|
pub enum TransferType {
  Binary   // "I"
  ASCII    // "A"
}
```

与 Go 版的差异：

- Go `Entry.Time` 是 `time.Time`；MoonBit 用 `@time.ZonedDateTime`，因为 `LIST` 的时间是**服务器时区**的墙上时间，必须带时区才能正确处理。
- Go 用零值表示「没有」，MoonBit 用显式 `Option` 更安全；但对 `Entry` 内部字段保留默认值语义（`target = ""`），避免嵌套 Option 影响可读性。

## 5. 错误模型

Go 版用 `errors.New` + `textproto.Error` + `errors.Join`。MoonBit 版：

```moonbit
///|
pub suberror FtpError {
  /// 服务器返回非预期状态码
  ServerError(code~ : Int, msg~ : String)
  /// 客户端参数含 \r 或 \n，拒绝发送（防命令注入）
  InvalidCommand(arg~ : String)
  /// LIST 行无法用四种解析器识别
  UnsupportedListLine(line~ : String)
  /// 时间字段格式不认识
  UnsupportedListDate(field~ : String)
  /// 解析 ERROR，携带底层原因
  ParseError(msg~ : String)
} derive(@debug.Debug)
```

**`errors.Join` 怎么落**：Go 版在 `Stor` / `Append` / `List` / `Quit` / `Response.Close` 里聚合多个错误（传输错误 + 关闭错误 + 状态读取错误）。MoonBit 版用显式聚合：

```moonbit
///|
pub suberror FtpErrors {
  /// 多个操作同时失败，全部保留
  MultipleErrors(errors~ : Array[Error])
}
```

聚合点必须与 Go 版逐一对齐，**不能遇到第一个错误就 return**——这是上游刻意设计的语义，丢掉会导致「传输失败了但原因被吞掉」。详见 [06-compat-checklist.md](./06-compat-checklist.md) 第 5 条。

## 6. 并发与生命周期

上游 `ServerConn` 的注释写得很清楚：「A single connection only supports one in-flight data connection. It is not safe to be called concurrently.」移植版必须保持这条约束，并进一步做到：

- `FTPClient` **内部加 `@async.Mutex`**，把这条注释变成运行时保证（超越上游的改进点，且不改变语义）。
- 数据连接生命周期严格遵循：`openDataConn → (REST) → 发传输命令 → 校验 125/150 → 传输 → 关闭数据连接 → 回控制通道读 226/250`。
- 收尾那一步（上游叫 `checkDataShut`）**不可省略**，否则下一条命令会读到上一条的响应。

## 7. 超时与取消

| Go 机制 | MoonBit 对应 |
| --- | --- |
| `DialWithTimeout` | `dial(addr, timeout_ms=30000)`，内部 `@async.with_timeout` |
| `DialWithContext` | 使用方在外层包 `@async.with_timeout` / `with_task_group` 取消 |
| `DialWithShutTimeout` | `dial(addr, shut_timeout_ms=0)`，仅作用于 226 收尾读取 |
| `Response.SetDeadline` | 因 async 无 per-conn deadline，改为 `response.with_deadline(ms, async fn)` 作用域包装 |

**这里必须诚实记录一个有意的行为差异**：Go 版 `Response.SetDeadline` 可以设置一个绝对时间点，之后所有读写受其约束。MoonBit 侧的 async IO 模型没有等价的「给连接设置绝对 deadline」原语，因此改为「在限时作用域内完成操作」。对调用方而言能力不降级（一样能限制超时），但 API 形状变了，需要在文档中明说。

## 8. 构建配置

`moon.mod`：

```moonbit
name = "PaiGack/ftp"
version = "0.1.0"
repository = "https://github.com/PaiGack/moonbit_ftp"
license = "Apache-2.0"
keywords = ["ftp", "network", "client", "protocol", "async"]
description = "FTP client library for MoonBit, ported from jlaffaye/ftp"
preferred_target = "native"     // FTP 需要真实 TCP + TLS，wasm 后端给不了

import {
  "moonbitlang/async@0.21.3",
  "moonbitlang/x@0.4.6",        // 时间工具，按需
}
```

CI 需要补的构建目标：

```bash
moon check --target native --deny-warn
moon test  --target native --enable-coverage
moon build --target native --release
```

**不再构建 wasm 后端**：`preferred_target = native` 后，原来 CI 里的 `moon build --target wasm-gc` 必须去掉，否则 async 的 native-only 实现会直接失败。这是 W0 的必做项。

## 9. 与上游的架构差异一览

| 项 | 上游 Go | 本项目 MoonBit | 原因 |
| --- | --- | --- | --- |
| 包划分 | 单包 6 文件 | 11 个包分层 | 隔离 async 版本风险，纯逻辑层可独立测 |
| 可选参数 | `...DialOption` 变参 | `DialOptions` 结构体 + `label~` | MoonBit 无 Go 式函数式选项语法糖 |
| 错误 | `error` 接口 | `suberror FtpError` | 显式、可穷举、可模式匹配 |
| 多错误聚合 | `errors.Join` | `FtpErrors::MultipleErrors` | 保留聚合语义 |
| 并发安全 | 注释声明不安全 | `Mutex` 强制串行 | 把文档约束变成编译期/运行期保证 |
| deadline | `SetDeadline(绝对时间)` | `with_deadline(限时作用域)` | async IO 模型无逐连接 deadline |
| 时间 | `time.Time` + `Location` | `ZonedDateTime` | 显式时区，避免解析偏差 |
