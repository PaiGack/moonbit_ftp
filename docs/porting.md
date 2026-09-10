# `jlaffaye/ftp` → MoonBit 移植方案

> 目标项目：[jlaffaye/ftp](https://github.com/jlaffaye/ftp)（Go 语言 FTP 客户端库，RFC 959）
> 分析对象：`master` 分支（约 1.4k stars / 382 forks，ISC License）
> 本文档用于指导 `PaiGack/ftp` 的 MoonBit 移植工作。

---

## 1. 上游项目分析

### 1.1 项目定位

`jlaffaye/ftp` 是一个纯 Go 实现的 FTP 客户端库，遵循 RFC 959，并额外支持：

- RFC 2389（`FEAT` 特性协商）
- RFC 3659（`MLST` / `MLSD` / `SIZE` / `MDTM`）
- RFC 4217（显式 / 隐式 FTPS，`AUTH TLS` / `PBSZ` / `PROT P`）
- 主动/被动模式，`EPSV`（RFC 2428）优先、`PASV` 回退
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
| `debug.go` | 37 | 调试输出包装（TeeReader / MultiWriter） |

### 1.3 功能矩阵

**连接与选项（Dial + 16 个 `DialWith*` 选项函数）**

- `Dial` / `Connect` / `DialTimeout`，默认 30s 超时
- 超时、上下文、自定义 dialer、自定义 dial 函数
- TLS：隐式 TLS、显式 TLS（`AUTH TLS` 升级）
- `EPSV` 禁用、`PASV` 返回 IP 信任开关（防 SSRF）、UTF8 禁用、MLSD 禁用、`MDTM` 写时间、强制 `LIST -a`、时区、调试输出

**认证**

- `Login(user, password)`：`USER` / `PASS`，成功后探测 `FEAT`，按需 `OPTS UTF8 ON`、`PBSZ 0` / `PROT P`
- `Logout`（`REIN`）、`NoOp`（`NOOP`）、`Quit`（`QUIT`）

**数据传输**

- 取文件：`Retr` / `RetrFrom(offset)` → `Response`（可读、可 `SetDeadline`、幂等 `Close`）
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
- 约 50 个 `Status*` 状态码常量 + `StatusText(code)`

### 1.4 关键实现要点（移植时必须保留的"隐性知识"）

1. **数据通道生命周期**：`cmdDataConnFrom` 统一处理 `PRET` 预热 → 建数据连接 → 可选 `REST offset` → 发传输命令 → 校验 `125/150`；非 `2xx` 时关闭数据连接并返回 `textproto.Error`。
2. **关闭语义**：数据传输结束后必须回控制连接读 `226/250`（`checkDataShut`），否则后续命令会错位。`ShutTimeout` 用于空闲超时场景"推一下"控制连接 deadline。
3. **错误聚合**：Go 的 `errors.Join` 被大量使用（`Quit` / `Stor` / `Append` / `List` / `Response.Close`），即"传输错误 + 关闭错误 + 状态读取错误"要一起返回。
4. **命令注入防护**：`checkForCommandInjection` 拒绝参数中含 `\r` / `\n`，对应 `ErrInvalidCommand`。
5. **EPSV 回退**：`EPSV` 失败一次后置 `skipEPSV`，后续走 `PASV`。
6. **PASV 防 SSRF**：默认使用控制连接的 IP，仅当显式信任且数据 IP 非组播/私网跨界的"可疑 IP"时才用 PASV 返回的 IP。
7. **TLS 数据连接**：不能直接用 `tls.DialWithDialer`（proftpd/pureftpd 会挂），需 `Dial` + `tls.Client` 延迟握手；零字节上传需显式 `Handshake()`。
8. **LIST 解析容错**：依次尝试 RFC3659 → Unix ls → DOS DIR → hostedftp 四种解析器，全部失败才报 `UnsupportedListLine`；时间字段有"半年规则"（无年份且超过 6 个月视为去年）。
9. **`Close` 幂等**：`Response.Close` 二次调用返回 nil。

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

```
src/
├── pkg                        # 门面包：对外 API 聚合与再导出
├── types/                     # Entry / EntryType / TransferType / Status 常量
├── error/                     # 错误类型：InvalidCommand / UnsupportedListLine / ServerError ...
├── control/                   # 控制通道：命令编码、多行响应、状态码解析、状态码表
├── scanner/                   # 空白字段扫描器（List line 解析用）
├── parse/                     # RFC3659 / ls / DIR / hostedftp 四种列表解析
├── transport/                 # EPSV / PASV / 数据连接 / TLS / PRET / REST 统一入口
├── client/                    # ServerConn 等价物：Dial/Login/Retr/Stor/List/...
├── walker/                    # 目录树遍历
└── debug/                     # 调试输出包装（对齐 io.Reader/Writer）
```

分层依赖：`types` ← `scanner`/`parse`/`control` ← `transport` ← `client` ← `walker`。
`parse` / `scanner` / `walker` 为纯逻辑包，可独立单测，不依赖网络。

### 2.4 API 映射示例

```moonbit
// Go: c, err := ftp.Dial("ftp.example.org:21", ftp.DialWithTimeout(5*time.Second))
let c = try @ftp.dial("ftp.example.org:21", timeout=5000) catch { ... }

// Go: err = c.Login("anonymous", "anonymous")
c.login("anonymous", "anonymous")

// Go: r, err := c.Retr("a.txt"); buf, _ := io.ReadAll(r); r.Close()
let r = c.retr("a.txt")
let buf = r.read_all()
r.close()

// Go: entries, err := c.List(".")
let entries = c.list(".")

// Go: w := c.Walk("/root"); for w.Next() { fmt.Println(w.Path(), w.Stat()) }
let w = c.walk("/root")
while w.next() {
  println(w.path())
}
```

设计约定：

- 所有可能失败的调用 `raise`，错误类型统一继承 `FtpError`。
- 可选参数一律用 `label~`（如 `timeout~`、`location~`、`disable_epsv~`），避免 Go 的 `...DialOption` 变参。
- `DialOption` 语义用 `DialOptions` 结构体承载，内部字段私有、通过 `with_*` 构造函数生成，保持可读性。

### 2.5 分阶段实施计划

| 阶段 | 内容 | 产物 |
| --- | --- | --- |
| P0 | 工程初始化：native target、依赖、CI、目录骨架 | 可编译空框架 |
| P1 | 纯逻辑层：`types` / `status` / `scanner` / `parse`（含 4 种解析器） | 单测全覆盖，对齐上游 `parse_test.go` 用例 |
| P2 | `control`：命令编码、多行响应、状态码校验、注入防护 | 纯内存单测 |
| P3 | `transport`：EPSV/PASV/PRET/REST/数据连接/TLS | mock 服务器联调 |
| P4 | `client`：Dial/Login/Quit/List/Retr/Stor/目录操作/时间操作 | mock 服务器端到端 |
| P5 | `walker`：目录树遍历 + `SkipDir` | 与上游 `walker_test.go` 对齐 |
| P6 | 兼容性：VsFtpd `MDTM` 写、`LIST -a`、hostedftp、DOS DIR、IIS | 差异化测试用例 |
| P7 | 示例 + README + 发布 mooncakes.io | 可运行示例、`moon add PaiGack/ftp` |

### 2.6 测试策略

1. **纯逻辑单测**：直接搬运上游 `parse_test.go` / `scanner_test.go` / `constants_test.go` 的用例集
   （UNIX ls、`ls -l` 变体、ACL `+` 权限、hostedftp、DOS DIR、RFC3659、符号链接、多空格文件名、非法行、半年时间规则）。
2. **Mock FTP 服务器**：用 `moonbitlang/async` 的 `TcpServer` 实现上游 `conn_test.go` 的 `ftpMock`
   （`FEAT` 特性协商、`PASV`/`EPSV` 数据通道、`STOR`/`RETR`/`LIST`/`MLSD`/`MLST`/`MDTM`/`MFMT`、`no-time`/`std-time`/`vsftpd` 三种服务器画像），
   并断言命令序列为 `USER, PASS, FEAT, TYPE, OPTS, ..., QUIT`。
3. **边界用例**：命令注入、EPSV 畸形响应、PASV 可疑 IP、二次 `Close`、零字节上传、REST 断点续传、超时。
4. **端到端（可选）**：CI 中启动 `pyftpdlib`/`vsftpd` 容器做真实服务器冒烟测试（runner 支持时才启用）。

---

## 3. 与上游的差异与裁剪

**保留**：RFC 959 全量命令、EPSV/PASV、FTPS、列表四解析器、Walker、防注入、防 SSRF、调试输出、时间操作。

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
| 测试需要真实网络 | 部分用例依赖 socket | 优先 mock 服务器；真实服务器用例放 CI 可选阶段 |

---

## 6. 验收清单（对齐赛事要求）

- [ ] MoonBit 为主要实现语言
- [ ] 源码结构清晰，可完成声明的核心功能
- [ ] README 说明目标、安装、用法、示例且可复现
- [ ] CI 覆盖检查 / 构建 / 测试
- [ ] 至少一个可运行示例（如 CLI `moon run cmd/ftp`，支持 `ls` / `get` / `put`）
- [ ] 完整测试覆盖核心路径（解析 + 协议序列 + 边界）
- [ ] 发布到 mooncakes.io
- [ ] OSI 许可证 + 上游来源注明

---

## 附：实施文档集

本文档是总体方案（范围与阶段划分）。**具体实施步骤**见 `docs/porting/` 文档集：

| 文档 | 内容 | 对应本文档 |
| --- | --- | --- |
| [porting/README.md](./porting/README.md) | 文档地图与速览 | 全文 |
| [porting/01-architecture.md](./porting/01-architecture.md) | 包结构、依赖方向、错误模型、超时与生命周期、`moon.mod` 配置 | 2.2 / 2.3 |
| [porting/02-upstream-map.md](./porting/02-upstream-map.md) | 上游文件 → MoonBit 落点逐条映射 | 1.2 |
| [porting/03-workplan.md](./porting/03-workplan.md) | **W0–W8 工作包拆解**（P0–P7 的细化版） | 2.5 |
| [porting/04-api-mapping.md](./porting/04-api-mapping.md) | Go/MoonBit API 与 16 个 DialWith 选项对照 | 2.4 |
| [porting/05-testing.md](./porting/05-testing.md) | 解析用例清单 + mock 服务器骨架 | 2.6 |
| [porting/06-compat-checklist.md](./porting/06-compat-checklist.md) | 9 个兼容性要点的落地与验收 | 1.4 |
| [porting/07-risks-and-estimation.md](./porting/07-risks-and-estimation.md) | 风险、已实测 API 清单、人日估算 | 5 |
| [porting/08-acceptance.md](./porting/08-acceptance.md) | 验收标准与交付物清单 | 6 |

> 冲突处理：阶段划分上本文档是 P0–P7，`porting/03-workplan.md` 是 W0–W8 工作包。**以 `porting/` 为准**（更细）。
