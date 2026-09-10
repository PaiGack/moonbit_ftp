# jlaffaye/ftp 移植到 MoonBit 方案

> 目标仓库：`nrzhangsan/moonbit_ftp`（模块名 `PaiGack/ftp`）
> 参考项目：[github.com/jlaffaye/ftp](https://github.com/jlaffaye/ftp)（Go，FTP 客户端，RFC 959）
> 分析基准：master @ `81e548e`（2026-08-21）

## 1. 参考项目分析

### 1.1 代码规模

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `ftp.go` | 1191 | 核心：连接、命令、传输、目录操作、Walker |
| `parse.go` | 277 | LIST/MLSD 目录行解析（4 种风格） |
| `status.go` | 119 | RFC 959 状态码 + 文案 |
| `walker.go` | 98 | 目录树遍历器 |
| `scanner.go` | 58 | 空白分隔字段扫描器 |
| `debug.go` | 37 | 调试输出包装（Tee） |
| 测试 | 1400+ | mock FTP server + 协议解析单测 |

总计约 **1780 行** 生产代码，测试约 **1400 行**。规模适中，适合移植。

### 1.2 依赖分析（移植难点所在）

| Go 依赖 | 用途 | MoonBit 现状 |
| --- | --- | --- |
| `net.Dial` / `net.Conn` | TCP 连接、超时、Deadline | MoonBit **无官方 TCP 库**，`moonbitlang/async` 提供 `async/net`（实验性） |
| `net/textproto` | 控制连接「命令-响应」行协议 | 需自行实现（约 150 行） |
| `bufio` | 按行读取数据连接 | 需自行实现缓冲读取 |
| `crypto/tls` | FTPS（隐式/显式 TLS） | MoonBit 无 TLS 库，**建议一期不做** |
| `io.Reader` / `io.Writer` / `io.Copy` | 流式上传下载 | 用 `@io.Reader` / `@io.Writer` 接口 + 自实现 `copy` |
| `io.Pipe` | 「以写代上传」 | 用 `@async/pipe` 或回调式 `StorWith` |
| `time` | 时间解析/格式化、时区 | `moonbitlang/x/time`（含 `LocalTime`/`ZonedDateTime`） |
| `context` | 连接取消/超时 | 用 `async` 的取消语义或显式 `timeout` 参数 |
| `errors.Join` | 聚合多错误 | 自实现 `join_errors` |
| `path.Join` | 路径拼接 | `moonbitlang/x/fs` 或自实现 |

**结论**：移植的实质工作量在 **网络栈与 IO 抽象**，协议逻辑本身（RFC 959 命令、LIST 解析）是纯字符串处理，可 1:1 平移且易测试。

### 1.3 架构与 API 概览

Go 的 API 是「单一 `ServerConn` 结构体 + 大量方法 + 函数式 DialOption」：

```
Dial(addr, opts...) ─┬─ Login ─┬─ List/NameList/GetEntry
                     │         ├─ Retr/RetrFrom/Stor/StorFrom/Append
                     │         ├─ ChangeDir/CurrentDir/MakeDir/RemoveDir/RemoveDirRecur
                     │         ├─ Rename/Delete/FileSize/GetTime/SetTime
                     │         ├─ NoOp/Logout/Quit/Walk
                     │         └─ Type(ASCII/Binary)
                     └─ options: EPSV/PASV、UTF8、MLSD、TLS、调试输出、信任 PASV IP…
```

关键设计点：

1. **被动模式优先**：`getDataConnPort()` 先试 `EPSV`，失败后 `skipEPSV=true` 永久降级到 `PASV`。
2. **能力协商**：`Login` 后自动发 `FEAT`，解析出 `MLST/MFMT/MDTM/UTF8/PRET` 等能力，决定后续用 `MLSD` 还是 `LIST`、用 `MFMT` 还是非标准 `MDTM` 写时间。
3. **SSRF 防护**：`PASV` 返回的 IP 默认**不信任**（改用控制连接对端 IP），除非显式开启 `DialWithTrustPasvIP`；`isBogusDataIP` 复刻 lftp 的判定（组播、私网/回环不一致视为伪造）。
4. **命令注入防护**：`checkForCommandInjection` 拒绝含 `\r`/`\n` 的参数（CVE 类问题，`81e548e` 刚修）。
5. **目录行解析多风格**：依次尝试 RFC 3659（MLSD `Type=file;Size=..;Modify=..; name`）、Unix `ls -l`、MS-DOS `DIR`、hostedftp 私有风格。
6. **数据连接关闭语义**：读完数据后必须再读控制连接的 `226`，`checkDataShut` + `shutTimeout` 解决空闲超时。
7. **Entry 模型**：`{Name, Target, Type(File/Folder/Link), Size, Time}`，`String()` 输出 `file/folder/link`。

### 1.4 命令与状态码

支持的命令：`USER PASS REIN QUIT NOOP FEAT AUTH PBSZ PROT OPTS UTF8 ON TYPE EPSV PASV PRET REST RETR STOR APPE MLSD MLST LIST NLST CWD CDUP PWD SIZE MDTM MFMT RNFR RNTO DELE MKD RMD`。

状态码在 `status.go` 中常量 + 文案齐全（1xx/2xx/3xx/4xx/5xx），可直接平移。

## 2. 移植总体策略

### 2.1 三阶段路线

| 阶段 | 目标 | 交付物 | 依赖 |
| --- | --- | --- | --- |
| **P0 纯逻辑** | 不依赖网络的协议层 | `status`、`entry`、`parse`、`walker`、`scanner` + 完整单测 | 仅 `moonbitlang/x` |
| **P1 控制连接** | 可真实连接并执行命令 | `textproto`、`conn`（Dial/Login/cmd/FEAT/EPSV/PASV） | `moonbitlang/async`（TCP） |
| **P2 数据传输** | 完整客户端能力 | List/Retr/Stor/Append/Walk + CLI 示例 | P1 |
| **P3 增强（可选）** | 对齐 Go 高级特性 | FTPS、PRET、并发装饰器、断点续传便捷封装 | P2 |

**关键决策**：先做 P0。理由：P0 是无 IO 的纯函数，能 100% 覆盖测试、锁定行为；且当前仓库 CI（`moon build --target wasm-gc/native`）不依赖网络，P0 可立即接入 CI。

### 2.2 目录结构设计

```
moonbit_ftp/
├── moon.mod                       # 模块 PaiGack/ftp
├── src/
│   ├── status/                    # 状态码 + 文案（P0）
│   ├── entry/                     # Entry / EntryType / TransferType（P0）
│   ├── parser/                    # LIST/MLSD/PASV/EPSV/PWD 解析（P0）
│   ├── scanner/                   # 字段扫描器（P0）
│   ├── walker/                    # 目录遍历器（P0，依赖 Parse + List 接口）
│   ├── textproto/                 # 行协议：命令/响应/多行响应（P1）
│   ├── transport/                 # TCP 抽象层（P1）
│   └── ftp/                       # Client：Dial/Login/命令方法（P1/P2）
├── cmd/
│   └── ftpmain/                   # CLI（P2）
└── docs/
```

> 兼容考量：现有仓库根目录为单包结构（`ftp.mbt`）。若希望快速见效，可先保留根包，把 `src/*` 作为子包；`moon.pkg` 中声明依赖。迁移成本低，推荐直接采用 `src/` 分层。

### 2.3 依赖选型

- 必需：`moonbitlang/x`（`time`、`fs`/`path`、`encoding`）
- 网络：`moonbitlang/async`（`async/net`、`async/io`、`async/pipe`）——注意其 API 仍在演进，需锁定版本
- 不引入：TLS（一期不做，用 trait 预留扩展点）

## 3. 模块级映射与设计

### 3.1 类型定义（`entry`）

```moonbit
///|
pub enum EntryType {
  File
  Folder
  Link
} derive(Debug, Eq)

///|
pub fn EntryType::to_string(self : EntryType) -> String {
  match self {
    File => "file"
    Folder => "folder"
    Link => "link"
  }
}

///|
pub enum TransferType {
  Binary  // "I"
  Ascii   // "A"
}

///|
pub struct Entry {
  pub name : String
  pub target : String?     // 符号链接目标，替代 Go 的空字符串
  pub typ : EntryType
  pub size : UInt64
  pub time : @time.ZonedDateTime?   // 类型化时间，替代 time.Time
} derive(Debug, Eq)
```

差异说明：
- Go 的 `Target string` 用 `String?` 表达「无链接目标」，更贴合 MoonBit 风格。
- Go 的零值 `time.Time{}` 在 MoonBit 中用 `Option` 表达，避免魔法零值。
- `Size uint64` 保留为 `UInt64`。

### 3.2 状态码（`status`）

使用 `Int` 常量 + `match` 返回文案，天然获得穷尽性检查收益：

```moonbit
///|
pub let status_ready : Int = 220

///|
pub fn status_text(code : Int) -> String {
  match code {
    220 => "Service ready for new user."
    230 => "User logged in, proceed."
    // ... RFC 959 全集
    _ => "Unknown status code: \{code}"
  }
}
```

### 3.3 目录行解析（`parser`）—— 移植重点

Go 用「解析器切片顺序尝试」的策略，MoonBit 用数组 + 首个成功：

```moonbit
///|
pub fn parse_list_line(
  line : String,
  now : @time.ZonedDateTime,
  loc : @time.TimeZone,
) -> Entry raise ParseError {
  // 依次尝试：RFC3659 -> ls -l -> MS-DOS DIR -> hostedftp
}
```

需要逐一还原的四类风格：

1. **RFC 3659 / MLSD**：`Type=file;Size=1024;Modify=20220813133357; path`
   - 以 `;` 切分 key=value，`Modify` 用固定格式 `%Y%m%d%H%M%S` 解析
   - 同一 entry 的多行需合并（`GetEntry` 会跨行累加）
2. **Unix `ls -l`**：`-rw-r--r-- 1 user group 1024 Jan 02 15:04 name`
   - 首字段长度必须为 10（或 11 且第 10 字符为 `+`，ACL 标记）
   - 首字符判定 `-`/`d`/`l`；链接行按 ` -> ` 拆 name/target
   - **日期歧义处理**：`Jan 02 15:04`（近半年）补当年，若晚于 `now + 6M` 则减 1 年；`Jan 02 2024` 直接取日期 + `00:00`
3. **MS-DOS DIR**：`01-02-06  03:04PM  <DIR>  name`，试 4 种时间格式
4. **hostedftp**：链接数为 0 的私有格式，重写为 `ls` 风格再解析

必须移植的边界用例（对应 `parse_test.go`）：
- 未知类型首字符 → 报错而非静默跳过
- 字段不足 6/8 个 → 报错
- 非法日期 → 返回 unsupported，触发下一个解析器

### 3.4 扫描器（`scanner`）

Go 的实现按字节推进（`NextFields(n)` / `Remaining()`），移植时保持语义：

```moonbit
///|
pub fn next_fields(s : Scanner, count : Int) -> Array[String]
pub fn remaining(s : Scanner) -> String
```

注意：Go 版本对**连续空格**只按「跳前导空格 + 读非空格」处理，且 `Next()` 在返回前多走一步指针，行为需用测试锁定（`scanner_test.go` 已有用例可直接抄）。

### 3.5 遍历器（`walker`）

Go 的 `Walker` 持有一个显式栈（DFS，后进先出），`Next()` 返回 `Bool`，配合 `Path()/Stat()/Err()/SkipDir()`。MoonBit 可直接复刻：

```moonbit
///|
pub struct Walker {
  client : Client
  root : String
  cur : Item?
  stack : Array[Item]
  descend : Bool
}

///|
pub fn Walker::next(self : Walker) -> Bool
pub fn Walker::skip_dir(self : Walker) -> Unit
pub fn Walker::path(self : Walker) -> String
pub fn Walker::stat(self : Walker) -> Entry?
pub fn Walker::error(self : Walker) -> FtpError?
```

设计改进建议：额外提供 `iter()` 风格（MoonBit 无泛型 iterator 包袱，可用 `Iterator[Entry]` 或直接 `List` 收集），兼顾易用性。

### 3.6 控制连接协议层（`textproto`）

这是 Go 标准库能力的替代，需自实现约 150~200 行：

```moonbit
///|
pub struct Conn {
  reader : @io.Reader
  writer : @io.Writer
}

///|
pub fn Conn::command(self : Conn, format : String, args : Array[String]) -> Unit
pub fn Conn::read_response(self : Conn, expected : Int) -> (Int, String)
```

要点：
- **多行响应**：`250-line1\r\n line2\r\n250 End\r\n`，以 `NNN-` 开头表示续行，`NNN ` 结束；返回拼接后的 message
- **超时**：Go 用 `SetDeadline`，MoonBit 可用 `async` 的 `with_timeout` 包裹读写
- **注入防护**：命令拼接后校验不得含 `\r`/`\n`，否则返回 `InvalidCommand`
- **调试输出**：把读到的字节 `tee` 到 `@io.Writer`（对应 `debug.go`），可用装饰器实现

### 3.7 客户端（`ftp`）

Go 的 DialOption 是「闭包列表」，MoonBit 无闭包结构体糖，改用 **Builder / 显式 Options 结构**：

```moonbit
///|
pub struct Options {
  timeout : Duration
  shut_timeout : Duration
  disable_epsv : Bool
  trust_pasv_ip : Bool
  disable_utf8 : Bool
  disable_mlsd : Bool
  writing_mdtm : Bool
  force_list_hidden : Bool
  location : @time.TimeZone
  debug : @io.Writer?
}

///|
pub async fn Client::dial(addr : String, options? : Options) -> Client raise FtpError
```

方法清单（对齐 Go，一期不做 TLS 相关）：

| 分类 | 方法 |
| --- | --- |
| 连接 | `dial` `login` `quit` `logout` `noop` |
| 能力 | `feat` `type_` `is_time_precise_in_list` `is_get_time_supported` `is_set_time_supported` |
| 目录 | `list` `name_list` `get_entry` `change_dir` `change_dir_to_parent` `current_dir` `make_dir` `remove_dir` `remove_dir_recur` |
| 文件 | `retr` `retr_from` `stor` `stor_from` `append` `rename` `delete` `file_size` |
| 时间 | `get_time` `set_time` |
| 遍历 | `walk` |
| 数据通道 | `open_data_conn` `get_data_conn_port` `epsv` `pasv` |

**登录流程**（严格按序，顺序错会导致真实服务器失败）：
1. `USER` → `230` 直接成功 / `331` 继续
2. `PASS` → `230`
3. `FEAT` → 解析能力表（失败不视为错误，视为无扩展）
4. `TYPE I`（二进制）
5. `OPTS UTF8 ON`（若 FEAT 含 UTF8；`501/504/202` 视为成功）
6. 隐式 TLS 时追加 `PBSZ 0` + `PROT P`

**数据连接流程**：
```
getDataConnPort: EPSV 优先（失败置 skipEPSV）→ PASV
openDataConn:    connect(host, port)
cmdDataConnFrom: PRET?(预热) → 打开数据连接 → REST?(偏移) → 发送命令
                 期望 125/150，否则关闭数据连接并抛 ServerError(code, msg)
```

**能力开关**（`FEAT` 结果驱动）：
- `MLST` 且未禁用 → `List` 用 `MLSD`（时间精确到秒）+ 支持 `GetEntry`
- 否则 → `LIST`（`force_list_hidden` 时 `LIST -a`）
- `MFMT` → `SetTime` 用 `MFMT`；否则 `MDTM` 可写(VsFtpd 私有)时用 `MDTM`；都没有则不支持
- `PRET` → 传输前先 `PRET <cmd>`

## 4. 错误模型

Go 用 `error` + `textproto.Error`，MoonBit 建议用 **typed error enum** 而非字符串：

```moonbit
///|
pub suberror FtpError {
  IoError(String)
  ServerError(code~ : Int, msg~ : String)   // 替代 textproto.Error
  InvalidCommand                            // 控制字符注入
  InvalidResponse(String)                   // PASV/EPSV/PWD 格式错误
  Unsupported(String)                       // SetTime/GetTime 不支持
  ParseError(String)                        // 目录行解析失败
  Closed
}
```

好处：调用方可对 `ServerError(code=550)` 精确分支，比 Go 的字符串比较更安全。多错误聚合（`errors.Join`）用 `Array[FtpError]` + 组合函数实现。

## 5. 测试策略

### 5.1 移植 Go 的 mock server

`conn_test.go`/`client_test.go` 内置了一个 `ftpMock`：监听本地端口、`textproto` 对话、可脚本化返回 `FEAT`、`PASV/EPSV`、`LIST/STOR` 等。这套 mock 是**最有价值的移植资产**，应完整搬到 MoonBit：

- 放在 `src/ftp/internal/mock/`（或 `moon.pkg` 的 test-import）
- 用 `async/net` 起本地监听，`port 0` 自动分配
- 断言**命令序列**（Go 的 `mock.commands`）：例如登录后必须依次看到 `USER/PASS/FEAT/TYPE/OPTS`
- 覆盖用例：`TestConnPASV`、`TestConnEPSV`、`TestWrongLogin`、`TestPASVIgnoresServerSuppliedHost`、`TestTrustPasvIP`、`TestTimeStandard/Vsftpd*`、`TestDeleteDirRecur`、`TestDialWithDialFunc`

### 5.2 纯函数单测（P0，可立即落地）

| 模块 | 用例（来自 Go 测试） |
| --- | --- |
| `parser` | `TestParseValidListLine`、`TestParseSymlinks`、`TestParseUnsupportedListLine`、`TestSettime` |
| `status` | `TestStatusText`、`TestEntryTypeString` |
| `scanner` | `TestScanner`、`TestScannerEmpty` |
| `walker` | `TestWalkReturnsCorrectlyPopulatedWalker`、`TestSkipDirIsCorrectlySet`、`TestEmptyStackReturnsFalse`、`TestCurInit` |
| 安全 | `TestNoCommandInjection`、`TestBogusDataIP`、`TestEPSV_Parse_*` |

MoonBit 测试形态：稳定断言用 `assert_eq!` / `assert_true!`；结构化输出用 `debug_inspect` 做快照（配合 `moon test --update`）。assert 消息避免浮点误差，日期比较统一转为 UTC 时间戳整数。

### 5.3 集成测试（P2）

- 本地 Docker 起 `pure-ftpd` / `vsftpd`，跑真实上传下载、断点续传、UTF-8 文件名、递归删除
- 至少覆盖一个「不支持 MLSD」「不支持 MFMT」的服务器，验证能力降级路径

## 6. 安全要点（必须保留）

| 风险 | Go 的处理 | 移植要求 |
| --- | --- | --- |
| 命令注入 | `checkForCommandInjection` 拒绝 CR/LF | 必须保留，且在 `command()` 层统一校验 |
| SSRF via PASV | 默认忽略服务器给的 IP，除非 `trustPasvIP` | 默认关闭；`isBogusDataIP` 规则一并移植 |
| 凭证泄漏 | 调试输出会打印 `PASS` | 建议新增敏感参数脱敏（改进项） |
| TLS 校验 | `tls.Config` 交由调用方 | 一期不提供 TLS，需在文档明确「明文传输」限制 |

## 7. 工作量估算

| 阶段 | 内容 | 预估 |
| --- | --- | --- |
| P0 | status/entry/parser/scanner/walker + 测试 | 2~3 人日 |
| P1 | textproto + transport + dial/login/feat/epsv/pasv + mock server | 4~6 人日 |
| P2 | 传输与目录方法、walker 联通、CLI | 4~5 人日 |
| P3 | 集成测试、文档、并发装饰器 | 2~3 人日 |
| 合计 | | **12~17 人日** |

主要不确定性：`moonbitlang/async` 的网络 API 稳定性与 `@io.Reader/Writer` 的适配成本。

## 8. 风险与对策

1. **MoonBit 网络生态不成熟** → 抽象 `transport` trait，先提供 `async/net` 实现，后续可换后端；所有网络代码隔离在 `transport`/`textproto` 两个包内。
2. **时间类型差异**（Go `time.Time` 带位置信息）→ 统一以 `@time.ZonedDateTime` 建模，解析后立刻归一化到指定时区，测试比较用 UTC 时间戳。
3. **无 `io.Pipe`（以写代上传）** → P2 提供 `stor_with(cb : (@io.Writer) -> Unit)` 回调式 API 作为替代。
4. **错误处理风格差异** → 用 `raise FtpError` 显式声明；Go 的「忽略某个错误继续」语义改写成明确的分支，避免被 `!` 静默吞掉。
5. **API 兼容性**：不追求与 Go 完全同名，优先符合 MoonBit 命名规范（`snake_case` 方法、`Option` 替代零值），但**命令序列与协议行为必须逐字节对齐**。

## 9. 里程碑建议

- **M1**：P0 完成，`moon test` 全绿，CI 覆盖 parser/status/scanner/walker
- **M2**：P1 完成，能对本地 pure-ftpd 完成 `dial → login → pwd → feat`
- **M3**：P2 完成，能 `list / retr / stor / walk`，`cmd` 下提供可用 CLI
- **M4**：文档 + 与 Go 版行为对照表 + 集成测试报告

## 10. 与 Go 版 API 对照表（节选）

| Go | MoonBit 设计 |
| --- | --- |
| `ftp.Dial(addr, opts...)` | `Client::dial(addr, options?)` |
| `c.Login(u, p)` | `client.login(u, p)` |
| `c.List(path) ([]*Entry, error)` | `client.list(path) -> Array[Entry] raise FtpError` |
| `c.Retr(path) (*Response, error)` | `client.retr(path) -> DataConn raise FtpError` |
| `c.Stor(path, r io.Reader)` | `client.stor(path, reader)` |
| `c.Walk(root) *Walker` | `client.walk(root) -> Walker` |
| `DialWithDisabledEPSV(b)` | `Options::{ disable_epsv: true }` |
| `DialWithTrustPasvIP(b)` | `Options::{ trust_pasv_ip: true }` |
| `textproto.Error` | `FtpError::ServerError(code~, msg~)` |
| `errors.Join(errs...)` | `FtpError::join(errs)` |
