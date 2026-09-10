# 02 上游源码 → MoonBit 落点映射

基准：`jlaffaye/ftp` master 分支（ISC License，作者 Julien Laffaye）。
生产代码 1780 行 / 6 文件，测试 1400 行 / 6 文件。

## 1. 文件级映射

| 上游文件 | 行数 | MoonBit 落点 | 备注 |
| --- | --- | --- | --- |
| `ftp.go` | 1191 | `client*.mbt` + `entry.mbt` + `error.mbt` | 按职责拆 6 个文件，不整文件照搬 |
| `parse.go` | 277 | `parse*.mbt` | 四种解析器各一个文件 |
| `status.go` | 119 | `status.mbt` | 常量表 + `status_text` |
| `scanner.go` | 58 | `scanner.mbt` | 逐方法对齐 |
| `walker.go` | 98 | `walker.mbt` | 栈遍历语义完全保留 |
| `debug.go` | 37 | `debug.mbt` | 对齐 `Reader`/`Writer` trait |

## 2. `ftp.go` 细分落点

上游 `ftp.go` 一个文件里塞了 6 件事，必须拆开：

| 上游内容 | 落点文件 | 说明 |
| --- | --- | --- |
| `EntryType` / `TransferType` / `Entry` | `entry.mbt` | 纯数据 |
| `DefaultDialTimeout` / `timeFormat` | `consts.mbt` | 常量 |
| `ErrInvalidCommand` | `error.mbt` | `FtpError::InvalidCommand` |
| `ServerConn` 结构体字段 | `client.mbt` | 含 capabilities 缓存 |
| `DialOption` + 16 个 `DialWith*` 选项函数 | `options.mbt` | 见 04-api-mapping.md |
| `Dial` / `Connect` / `DialTimeout` | `dial.mbt` | |
| `Login` / `authTLS` / `feat` / `setUTF8` | `login.mbt` | 能力协商集中一处 |
| `epsv` / `parseEPSV` / `pasv` / `isBogusDataIP` / `getDataConnPort` / `openDataConn` | `transport_*.mbt` | 拆成 `transport_epsv.mbt` / `transport_pasv.mbt` / `transport_dataconn.mbt` |
| `cmd` / `checkForCommandInjection` | `command.mbt` | |
| `cmdDataConnFrom` | `transport_dataconn.mbt` | 数据通道开启流程核心 |
| `Type` / `NameList` / `List` / `GetEntry` | `list.mbt` | |
| `IsTimePreciseInList` / `ChangeDir` / `ChangeDirToParent` / `CurrentDir` | `nav.mbt` | |
| `FileSize` / `GetTime` / `IsGetTimeSupported` / `SetTime` / `IsSetTimeSupported` | `client_time.mbt` | |
| `Retr` / `RetrFrom` / `Stor` / `StorFrom` / `Append` / `checkDataShut` | `transfer.mbt` | 最核心、坑最多 |
| `Rename` / `Delete` / `RemoveDirRecur` / `MakeDir` / `RemoveDir` | `fsops.mbt` | |
| `Walk` | `nav.mbt` | 只做 `Walker` 构造 |
| `NoOp` / `Logout` / `Quit` | `lifecycle.mbt` | |
| `Response` 及其 4 个方法 | `response.mbt` | |
| `statusText` map | `status.mbt` | |

## 3. `parse.go` 细分落点

| 上游函数 | 落点 | 要点 |
| --- | --- | --- |
| `listLineParsers` 数组 | `parse.mbt` | 回退顺序固定：RFC3659 → ls → DOS → hostedftp |
| `parseRFC3659ListLine` | `parse_rfc3659.mbt` | `;` 与空格位置校验，`iSemicolon > iWhitespace` 即拒绝 |
| `parseNextRFC3659ListLine` | `parse_rfc3659.mbt` | 多行同名合并（MLST 用），名字不一致要报错 |
| `parseLsListLine` | `parse_unix_ls.mbt` | 首字段必须 10 字节，或 11 字节且第 11 位是 `+`（ACL） |
| `parseDirListLine` | `parse_dos_dir.mbt` | 4 种时间格式逐个试 |
| `parseHostedFTPLine` | `parse_hostedftp.mbt` | link count 为 0，换算成 1 后复用 ls 解析 |
| `parseListLine` | `parse.mbt` | 顶层入口，返回 `Format` 标明命中哪种 |
| `Entry::setSize` | `parse.mbt` | `ParseUint(str, 0, 64)` → MoonBit 需支持 `0x` 前缀 |
| `Entry::setTime` | `parse_time.mbt` | **半年规则**在这里 |

`setTime` 的半年规则（上游注释引 `info ls` 10.1.6）：

```
时间字段含 ":"（即 "MMM DD HH:MM" 形式，无年份）：
  用当前年份补齐 → 若结果不早于 now+6month，则年份减 1
时间字段不含 ":"（即 "MMM DD YYYY" 形式）：
  YYYY 必须恰好 4 位，否则报 UnsupportedListDate（缺失 = 错误，不是回退）
```

## 4. `scanner.go` 行为契约

这个 58 行的小东西容易写错，因为它**位置语义不直观**：

```
newScanner("foo  bar x  y")
  .next()      -> "foo"，position 停在连续空格之后
  .remaining() -> " bar x  y"     ← 注意前导空格被保留
  .next()      -> "bar"
  .remaining() -> "x  y"
  .next()      -> "x"
  .remaining() -> " y"
  .next()      -> "y"
  .next()      -> ""
  .remaining() -> ""
```

关键点：`next()` 会消费掉字段后紧跟的**一个**空格，因此剩下的前导空格会留在 `remaining()` 里。上游测试 `TestScanner` 逐条断言了这个行为，移植时必须逐条通过（见 [05-testing.md](./05-testing.md)）。

`next_fields(count)`：连续取 `count` 个字段，取不到就提前停，返回已取到的（**不报错**）。

## 5. `walker.go` 行为契约

```
Walker {
  cur      : 当前项（首次 Next 时若为空，初始化为 root 目录项）
  stack    : 待访问项栈（LIFO，用数组尾部当栈顶）
  descend  : 是否要展开当前目录（SkipDir 置 false）
}
```

`next()` 流程：

1. `cur == nil` → 初始化为 `{path: root, entry: {type: Folder}}`。
2. 若 `descend == true` 且 `cur` 是目录 → `list(cur.path)`；失败则把错误记在 `cur.err` 并**返回 false 提前结束**（不是抛出）。
3. 目录项过滤掉 `.` 和 `..`，其余按 `path.join(cur.path, name)` 入栈。
4. 栈空 → 返回 false。
5. 弹出栈顶作为新 `cur`，重置 `descend = true`，返回 true。

注意第 2 步：**遍历中途出错不抛异常，而是停在原地并可通过 `err()` 读取**。这是上游 API 契约（`Next() bool` + `Err() error`），必须保留。

`walk(root)` 构造时：若 `root` 不以 `/` 结尾则补上，`descend = true`。这也解释了上游测试里 `w.root == "root/"`。

## 6. `status.go` 落点

47 个状态码常量 + 一张 code→text 表 + `status_text(code)`。

两个必须对齐的行为：

- `status_text(0)` → `"Unknown status code: 0"`（未知码有固定格式，不是空串）
- `status_text(430)` → `"Invalid username or password."`（取表中原文，不做本地化）

常量命名按上游语义直译：`StatusClosingDataConnection = 226` → `StatusClosingDataConnection`（MoonBit 常量风格用下划线：`status_closing_data_connection`，但导出给用户时可保留可读别名）。

## 7. `debug.go` 落点

上游做两件事：包装控制连接（读写双向 tee）、包装数据流（读单向 tee）。

MoonBit 版：

- 控制通道：实现 `@io.Reader + @io.Writer` 的装饰结构体，读到的字节同时写给日志 writer。
- 数据通道：只包装 `Reader`。
- **日志输出必须是可选注入**，默认关闭时零开销（走原始连接，不套装饰器）。

## 8. 测试文件映射

| 上游测试 | 行数 | MoonBit 落点 | 搬运方式 |
| --- | --- | --- | --- |
| `parse_test.go` | 194 | `parse_test.mbt` | **逐条直搬**（30+ 用例，字符串进结构体出） |
| `scanner_test.go` | 31 | `scanner_test.mbt` | 逐条直搬（含空串用例） |
| `constants_test.go` | 18 | `status_test.mbt` | 逐条直搬 |
| `walker_test.go` | 211 | `walker_test.mbt` | 纯逻辑用例直搬；端到端部分改写真机断言 |
| `conn_test.go` | 449 | `ftp_server_test.mbt` | 真机端到端（`jmoyer/vsftpd` 四个画像），见 05-testing.md |
| `client_test.go` | 445 | `ftp_server_test.mbt` | 同上 |
| `ftp_test.go` | 62 | 合并进 `client_test` | |

## 9. 不移植的部分（明确裁剪）

| 上游内容 | 处理 | 理由 |
| --- | --- | --- |
| `Connect` / `DialTimeout` | 不提供 | 上游已标 Deprecated，新库不留历史包袱 |
| `DialWithNetConn` | 不提供 | 上游已标 Deprecated，用 `dial_func` 替代 |
| 主动模式 | 上游本就没有 | 保持一致 |
| C 相关/平台特化代码 | 无 | 上游没有 |

## 10. 符号级映射（代码写完后的回填）

前 9 节是**写代码之前**的落点规划，本节是**代码落地之后**的回填：上游每一个公开符号
（Go 是 `导出标识符`，MoonBit 是 `pub`）现在落在哪，叫什么。写新代码或对齐行为时先查这里。

约定：

- 「Go 符号」一列是上游 `master` 的标识符，`(m)` 表示方法（`c.List()` 形式）。
- 「MoonBit 符号」一列是根包 `PaiGack/ftp` 里的名字，`::` 后面是方法/关联函数。
- 标 **改名** 的行是本仓与上游有意不同的名字，最后一列说明原因。

### 10.1 `ftp.go` — 类型与常量

| Go 符号 | MoonBit 符号 | 落点 | 备注 |
| --- | --- | --- | --- |
| `EntryType` | `EntryType` | `entry.mbt` | `File` / `Folder` / `Link` |
| `EntryType.String()` | `EntryType::to_string` | `entry.mbt` | 返回 `"file"` / `"folder"` / `"link"` |
| `TransferType` | `TransferType` | `entry.mbt` | `Binary` → `"I"`、`ASCII` → `"A"` |
| `TransferType.argument()` | `TransferType::argument` | `entry.mbt` | |
| `TransferType.String()` | `TransferType::to_string` | `entry.mbt` | |
| —（Go 用 `ftp.Binary` / `ftp.ASCII` 常量） | `TransferType::from_string` | `entry.mbt` | 字符串 → 枚举，供 CLI 使用 |
| `Entry` | `Entry` | `entry.mbt` | 5 个 `mut` 字段，同名 |
| `EntryType` 零值 `EntryTypeFile` | `make_entry` / `make_file` / `make_folder` / `make_link` | `entry.mbt` | Go 的零值语义在 MoonBit 里没有对应物，改用显式构造函数 |
| `timeFormat` | `time_format` | `consts.mbt` | `"yyyyMMddHHmmss"`（Go 是 `"20060102150405"`，同一含义的两种写法） |
| `DefaultDialTimeout` | `default_dial_timeout_ms` | `consts.mbt` | 改名：Go 是 `time.Duration`（纳秒），MoonBit 统一用毫秒 `Int` |
| —（隐式 `time.UTC` 回退） | `utc_offset_seconds` | `consts.mbt` | 新增：显式表达默认时区偏移，避免各处硬编码 0 |
| `ErrInvalidCommand` | `FtpError::InvalidCommand` | `error.mbt` | 改名：Go 是 `error` 变量，MoonBit 是 `suberror` 变体 |
| `errUnsupportedListLine` | `FtpError::UnsupportedListLine` | `error.mbt` | 改名：同上，且**带上了原始行**（`line~`）便于定位 |
| `errUnsupportedListDate` | `FtpError::UnsupportedListDate` | `error.mbt` | 改名：同上，带 `field~` |
| `errUnknownListEntryType` | `FtpError::ParseError(msg="unknown entry type")` | `error.mbt` | 改名：并入通用 `ParseError`，消息文案与上游逐字一致 |
| —（`errors.Join`） | `FtpErrors::MultipleErrors` + `join_errors` + `flatten_errors` | `error.mbt` | 新增：MoonBit 没有 `errors.Join`，见 10.8 |

### 10.2 `ftp.go` — `ServerConn`

| Go 符号 | MoonBit 符号 | 落点 | 备注 |
| --- | --- | --- | --- |
| `ServerConn` | `FTPClient` | `client.mbt` | 改名：对齐上游 `client_test.go` 里的叫法与 docs/porting 的用词 |
| `ServerConn.Login(user, password)` | `login` | `login.mbt` | 改名：平铺成包级函数，Go 的 `user, password string` → `user~, password~` label |
| `ServerConn.authTLS()` | `Control::upgrade` 内联 | `control.mbt` | 改名：TLS 升级是控制通道的行为，收进 `Control`，不再单独暴露 |
| `ServerConn.feat()` | `feat` | `login.mbt` | 返回 `Unit`，把 `parse_features` 的结果写回 client 的能力缓存 |
| —（`feat` 里的解析循环） | `parse_features` | `login.mbt` | 新增：把「FEAT 正文 → `Map[String, Bool]`」抽成纯函数，可单测 |
| `ServerConn.setUTF8()` | `login` 内联 + `DialOptions::disable_utf8` | `login.mbt` / `options.mbt` | 改名：不是一个独立公开步骤，只是登录流程里的一次 `OPTS UTF8 ON` |
| `ServerConn.Type(transferType)` | `set_transfer_type` | `list.mbt` | 改名：与 `TransferType` 同名易混淆 |
| `ServerConn.cmd(expected, format, ...)` | `cmd` / `cmd_expect` / `cmd_format` | `command.mbt` | 拆三个：`cmd` 只读响应，`cmd_expect` 校验状态码，`cmd_format` 做参数替换 |
| `checkForCommandInjection` | `check_for_command_injection` | `command.mbt` | 逐字符判定，见 10.9 |
| `ServerConn.cmdDataConnFrom(offset, format, ...)` | `cmd_data_conn_from` | `transport_dataconn.mbt` | 数据通道开启流程核心 |
| `ServerConn.NameList(path)` | `name_list` | `list.mbt` | |
| `ServerConn.List(path)` | `list` | `list.mbt` | 返回 `Array[Entry]`（Go 是 `[]*Entry`，MoonBit 无指针） |
| `ServerConn.GetEntry(path)` | `get_entry` | `list.mbt` | |
| `ServerConn.IsTimePreciseInList()` | `FTPClient::is_time_precise_in_list` | `client.mbt` | 读能力缓存 |
| `ServerConn.ChangeDir(path)` | `change_dir` | `nav.mbt` | |
| `ServerConn.ChangeDirToParent()` | `change_dir_to_parent` | `nav.mbt` | |
| `ServerConn.CurrentDir()` | `current_dir` | `nav.mbt` | |
| —（`CurrentDir` 里的引号提取） | `extract_quoted` | `nav.mbt` | 新增：从 `257 "/incoming" created.` 提路径，纯函数 |
| `ServerConn.FileSize(path)` | `file_size` | `client_time.mbt` | `int64` → `UInt64` |
| `ServerConn.GetTime(path)` | `get_time` | `client_time.mbt` | `time.Time` → `@time.ZonedDateTime` |
| —（`GetTime` 里的 `MDTM` 回包解析） | `parse_mdtm` | `client_time.mbt` | 新增：纯函数，可单测 |
| `ServerConn.IsGetTimeSupported()` | `FTPClient::is_get_time_supported` | `client.mbt` | |
| `ServerConn.SetTime(path, t)` | `set_file_time` | `client_time.mbt` | **改名**：与 `parse_time.mbt` 的 `set_time` 撞名，IO 侧取更明确的名字 |
| `ServerConn.IsSetTimeSupported()` | `FTPClient::is_set_time_supported` | `client.mbt` | |
| —（`SetTime` 的 `yyyyMMddHHmmss` 格式化） | `format_mdtm` | `client_time.mbt` | 新增：纯函数 |
| `ServerConn.Retr(path)` | `retr` | `transfer.mbt` | |
| `ServerConn.RetrFrom(path, offset)` | `retr_from` | `transfer.mbt` | `uint64` → `Int64`（`REST` 偏移） |
| `ServerConn.Stor(path, r)` | `stor` | `transfer.mbt` | |
| `ServerConn.StorFrom(path, r, offset)` | `stor_from` | `transfer.mbt` | 零字节 TLS 握手在 `DataConn` 内触发 |
| `ServerConn.Append(path, r)` | `append` | `transfer.mbt` | |
| `ServerConn.checkDataShut()` | `check_data_shut` | `transfer.mbt` | |
| —（`io.Copy`） | `stream` | `transfer.mbt` | 私有辅助：逐块搬运并计数，供 `stor_from` / `append` 共用 |
| `ServerConn.Rename(from, to)` | `rename` | `fsops.mbt` | |
| `ServerConn.Delete(path)` | `delete` | `fsops.mbt` | |
| `ServerConn.RemoveDirRecur(path)` | — | — | **未实现**，见第 12 节 |
| `ServerConn.MakeDir(path)` | `make_dir` | `fsops.mbt` | |
| `ServerConn.RemoveDir(path)` | `remove_dir` | `fsops.mbt` | |
| `ServerConn.Walk(root)` | `walk` | `walker.mbt` | 只做 `Walker` 构造，与上游一致 |
| `ServerConn.NoOp()` | `no_op` | `lifecycle.mbt` | |
| `ServerConn.Logout()` | `logout` | `lifecycle.mbt` | |
| `ServerConn.Quit()` | `quit` | `lifecycle.mbt` | 幂等，二次调用直接返回 |
| —（Go 里的 `closed` 字段） | `FTPClient::is_closed` | `lifecycle.mbt` | 改名：Go 是未导出字段，MoonBit 用 getter 暴露 |
| —（Go 里的 `mutex`） | `FTPClient::lock` / `FTPClient::unlock` | `client.mbt` | 改名：Go 的 `sync.Mutex` 在 MoonBit 里手写，见 10.8 |

### 10.3 `ftp.go` — 传输与选项

> 补充说明：`dial` 的选项既可走 label（`dial(addr, timeout_ms~, ...)`），也可以先构造
> `DialOptions` 再逐项 `set_*`。`options.mbt` 里的 15 个 `set_*` 是后者的写法，与
> `dial` 的 label 一一对应；上游的 `...DialOption` 变参因此有了两种等价表达。



| Go 符号 | MoonBit 符号 | 落点 | 备注 |
| --- | --- | --- | --- |
| `epsv()` | `epsv` | `transport_epsv.mbt` | |
| `parseEPSV(line)` | `parse_epsv` | `transport_epsv.mbt` | |
| —（`parseEPSV` 内的数字扫描） | `is_all_digits` / `parse_port` | `transport_epsv.mbt` | 新增：拆成两个可单测的小函数 |
| `pasv()` | `pasv` | `transport_pasv.mbt` | |
| `parsePasv`（内联在 `pasv` 里） | `parse_pasv` | `transport_pasv.mbt` | 新增：从方法体里提出来 |
| `isBogusDataIP(cmdIP, dataIP)` | `is_bogus_data_ip` | `transport_pasv.mbt` | |
| —（`isBogusDataIP` 内的 IP 分类） | `is_private` / `is_loopback` / `is_multicast` | `transport_pasv.mbt` | 新增：`net.IP` 的分类逻辑改成字符串实现 |
| —（`parsePasv` 内的单段解析） | `parse_octet` | `transport_pasv.mbt` | 新增：解析 `.` 分隔的十进制段 |
| `getDataConnPort()` | `get_data_port` | `transport_dataconn.mbt` | 改名：`get` → `get`，但去掉了缩写 `Conn` |
| `openDataConn()` | `open_data_conn` | `transport_dataconn.mbt` | 返回 `DataConn`（连接 + 延迟握手状态） |
| —（`net.Conn` 包装） | `DataConn` + `DataConn::reader` / `::writer` / `::close` | `transport_dataconn.mbt` | 新增：Go 直接用 `net.Conn`，MoonBit 需要显式持有 reader/writer |
| `dialOptions.wrapConn(netConn)` | `TeeReader` / `TeeWriter` 的选择 | `debug.mbt` + `Control::new` | `debug_log` 非空时才包装，见 10.7 |
| `dialOptions.wrapStream(rd)` | `TeeReader` 用于 `DataConn` | `debug.mbt` + `transport_dataconn.mbt` | 只包装读方向，与上游一致 |
| `Dial(addr, options...)` | `dial` | `dial.mbt` | Go 变参 → MoonBit label 参数 |
| `Connect(addr)` | — | — | **不移植**，上游已 Deprecated（见第 9 节） |
| `DialTimeout(addr, timeout)` | — | — | **不移植**，同上 |
| `splitAddr`（`Dial` 内联） | `split_addr` | `dial.mbt` | 新增：`host:port` / `[ipv6]:port` / 裸 host |
| —（`strconv.Atoi`） | `parse_decimal` | `dial.mbt` | 新增：十进制整数解析，失败返回 `None` |
| `DialWithTimeout(d)` | `DialOptions::set_timeout_ms` | `options.mbt` | 改名：`time.Duration` → 毫秒 `Int`（另有同名 `dial` label） |
| `DialWithShutTimeout(d)` | `DialOptions::set_shut_timeout_ms` | `options.mbt` | 同上 |
| `DialWithDialer(dialer)` | —（合并进 `timeout_ms`） | `dial.mbt` | **未实现**：`net.Dialer` 的字段在 MoonBit 侧无对应物，现在只有超时被保留，见第 12 节 |
| `DialWithNetConn(conn)` | — | — | **不移植**，上游已 Deprecated，用 `dial_func~` 替代 |
| `DialWithDialFunc(f)` | `dial_func~`（计划中的 label） | — | **未实现**：用于注入自定义连接，随 W2–W6 补，见第 12 节 |
| `DialWithDisabledEPSV(b)` | `DialOptions::set_disable_epsv` | `options.mbt` | 改名：`Disabled` → `disable`，与 MoonBit 命名习惯一致 |
| `DialWithTrustPasvIP(b)` | `DialOptions::set_trust_pasv_ip` | `options.mbt` | |
| `DialWithDisabledUTF8(b)` | `DialOptions::set_disable_utf8` | `options.mbt` | |
| `DialWithDisabledMLSD(b)` | `DialOptions::set_disable_mlsd` | `options.mbt` | |
| `DialWithWritingMDTM(b)` | `DialOptions::set_writing_mdtm` | `options.mbt` | |
| `DialWithForceListHidden(b)` | `DialOptions::set_force_list_hidden` | `options.mbt` | |
| `DialWithLocation(loc)` | `DialOptions::set_location` | `options.mbt` | `*time.Location` → `@time.Zone` |
| `DialWithContext(ctx)` | — | — | **不移植**，取消交给 `async` 的取消机制，见 10.9 |
| `DialWithTLS(cfg)` | `DialOptions::set_tls` | `options.mbt` | 隐式 TLS（FTPS） |
| `DialWithExplicitTLS(cfg)` | `DialOptions::set_explicit_tls` | `options.mbt` | 显式 TLS（`AUTH TLS`） |
| `DialWithDebugOutput(w)` | `DialOptions::set_debug_log` | `options.mbt` | 改名：`io.Writer` → `&@io.Writer` |
| `dialOptions` | `Options` | `state.mbt` | 改名 + 搬家：挪进 `state.mbt`，让 `client` 与 `transport` 共享它而不互相 import |
| —（无对应物） | `DialOptions` | `options.mbt` | 新增：`dial` 的 label 默认值来源（`Options` 是传输层只读视图），两层结构见 10.9 |

### 10.4 `ftp.go` — 响应

| Go 符号 | MoonBit 符号 | 落点 | 备注 |
| --- | --- | --- | --- |
| `Response` | `DataResponse` | `transfer.mbt` | **改名**：Go 的 `ftp.Response` 是数据传输句柄，平铺后与 `response.Response`（控制通道应答）撞名，IO 侧改叫 `DataResponse` |
| `Response.Read(buf)` | `DataResponse::read` | `transfer.mbt` | |
| `Response.Close()` | `DataResponse::close` | `transfer.mbt` | 幂等；同时做 `check_data_shut` 的 `226` 收尾 |
| `Response.SetDeadline(t)` | — | — | **不提供**，形状变化见 docs/porting/01-architecture.md 第 7 节 |
| —（`ReadResponse` 的返回三元组） | `Response` + `Response::code` / `Response::message` | `response.mbt` | 新增：控制通道应答类型，字段改成方法调用（`.message()`），避免与字段名歧义 |
| `readResponse`（`conn.go`） | `read_response` | `response.mbt` | 多行响应 `211-...211 End` 在这里归一 |
| —（状态码提取） | `parse_code` / `is_continuation` | `response.mbt` | 新增：拆成两个纯函数 |

### 10.5 `parse.go`

| Go 符号 | MoonBit 符号 | 落点 | 备注 |
| --- | --- | --- | --- |
| `parseFunc` | — | — | 不需要：MoonBit 直接用 `match` 顺序调用四个解析器 |
| `listLineParsers` | `parse_list_line` 里的调用顺序 | `parse.mbt` | 回退顺序硬编码：RFC3659 → ls → DOS → hostedftp |
| `parseRFC3659ListLine` | `parse_rfc3659_line` | `parse_rfc3659.mbt` | 返回 `Entry?`：`None` = 不是这种格式（可回退） |
| `parseNextRFC3659ListLine` | `parse_next_rfc3659_line` | `parse_rfc3659.mbt` | MLST 多行合并 |
| `parseLsListLine` | `parse_ls_line` | `parse_unix_ls.mbt` | |
| —（`parseLsListLine` 内的日期定位） | `find_date_start_pub` | `parse_unix_ls.mbt` | 新增：对外暴露，测试用 |
| `parseDirListLine` | `parse_dos_dir_line` | `parse_dos_dir.mbt` | |
| `dirTimeFormats` | `parse_dos_date` 里的四种格式 | `parse_dos_dir.mbt` | 四种布局逐个试 |
| `parseHostedFTPLine` | `parse_hostedftp_line` | `parse_hostedftp.mbt` | |
| `parseListLine` | `parse_list_line` | `parse.mbt` | 返回 `(Entry, ListFormat)`，比 Go 的裸 `*Entry` 多带一个「命中了哪种格式」 |
| —（无对应物） | `ListFormat` | `parse.mbt` | 新增：`Rfc3659` / `UnixLs` / `DosDir` / `HostedFtp`，供测试与调试断言 |
| `Entry.setSize(str)` | `set_size` | `parse.mbt` | 改名：平铺后不再是方法；保留 `ParseUint(s, 0, 64)` 的进制语义 |
| —（`strconv.ParseUint`） | `parse_uint` | `parse.mbt` | 新增：显式带 `radix` 参数 |
| `Entry.setTime(fields, now, loc)` | `apply_list_time` | `parse_time.mbt` | **改名**：与 `client_time.mbt` 的 `set_file_time` 语义区分，一个用于解析、一个用于发 `MFMT` |
| —（`time.ParseInLocation`） | `new_datetime` | `parse_time.mbt` | 新增：`(year, month, day, hour, minute, zone)` → `@time.ZonedDateTime` |
| —（`fields[2]` 的形状判定） | `ListDateField` + `parse_list_date_field` | `parse_time.mbt` | 新增：把「有时间 / 只有年份」的字段解析成一个小结构体 |
| —（半年规则） | `ListDateField::has_time` / `::year` / `::day` / `::hour` / `::minute` / `::next` | `parse_time.mbt` | 新增：字段访问器，保持半年规则可单测 |
| —（月份名表） | `month_names` + `parse_month` | `parse_time.mbt` | 新增：`Jan`…`Dec` → `1`…`12` |
| —（`ls -l` 时间字段整体） | `parse_ls_time` | `parse_time.mbt` | 新增：`MMM DD HH:MM` 与 `MMM DD  YYYY` 的统一入口 |

`setSize` 的进制语义（上游 `strconv.ParseUint(str, 0, 64)`）在 `set_size` 里逐条保住：

| 输入形态 | 进制 | 例 |
| --- | --- | --- |
| `0x` / `0X` 前缀 | 16 | `0xff` → 255 |
| `0o` / `0O` 前缀 | 8 | `0o17` → 15 |
| 前导 `0` | 8 | `0755` → 493 |
| 其他 | 10 | `951` → 951 |

### 10.6 `status.go` / `scanner.go` / `debug.go`

| Go 符号 | MoonBit 符号 | 落点 | 备注 |
| --- | --- | --- | --- |
| `StatusRestartMarker` … `StatusBadFileName`（47 个常量） | `status_restart_marker_answer` … `status_bad_filename`（47 个 `pub let`） | `status.mbt` | **改名**：`UpperCamelCase` → `snake_case`；数值逐条对齐，见 10.10 |
| `statusText` map | `status_text` 的 `match` 分支 | `status.mbt` | 改名：Go 的 `map[int]string` 写成 `match`，未知码走 `_` 分支 |
| `StatusText(code)` | `status_text(code)` | `status.mbt` | 未知码 `"Unknown status code: {code}"`，与上游逐字一致 |
| —（无对应物） | `is_positive_completion` / `is_positive_intermediate` | `status.mbt` | 新增：`2xx` / `1xx` 判定，`list` 与 `login` 流程共用 |
| `scanner` | `Scanner` | `scanner.mbt` | 改名：Go 未导出类型，MoonBit 作为公开工具类型 |
| `newScanner(str)` | `Scanner::new` | `scanner.mbt` | |
| `scanner.Next()` | `Scanner::next` | `scanner.mbt` | 位置语义见第 4 节 |
| `scanner.NextFields(count)` | `Scanner::next_fields` | `scanner.mbt` | |
| `scanner.Remaining()` | `Scanner::remaining` | `scanner.mbt` | 保留前导空格 |
| —（无对应物） | `Scanner::at_end` | `scanner.mbt` | 新增：替代 Go 里的 `s.pos >= len(s.str)` 判断 |
| `newDebugWrapper(conn, w)` | `TeeReader::new` + `TeeWriter::new` | `debug.mbt` | 改名：Go 一个双向 wrapper → MoonBit 拆成读/写两个装饰器 |
| `streamDebugWrapper(rd, w)` | `TeeReader` | `debug.mbt` | 数据流只包装读方向 |
| `debugWrapper.Close()` | — | — | 不需要：装饰器不拥有底层连接，关闭由 `Control` / `DataConn` 负责 |

### 10.7 `walker.go`

| Go 符号 | MoonBit 符号 | 落点 | 备注 |
| --- | --- | --- | --- |
| `Walker` | `Walker` | `walker.mbt` | 字段改成私有 + getter |
| `item{entry, path}` | `(Entry, String)` 元组 | `walker.mbt` | 改名：不需要专门的私有结构体 |
| `w.Next()` | `Walker::next` | `walker.mbt` | `async`：遍历要发 `LIST` |
| `w.SkipDir()` | `Walker::skip_dir` | `walker.mbt` | 只清 `descend` |
| `w.Err()` | `Walker::err` | `walker.mbt` | `error` → `Error?` |
| `w.Stat()` | `Walker::stat` | `walker.mbt` | `*Entry` → `Entry?` |
| `w.Path()` | `Walker::path` | `walker.mbt` | |
| —（直接读 `w.stack` 的测试） | `Walker::entries` / `set_stack` / `pending` / `push` / `pop` | `walker.mbt` | 新增：白盒测试用，语义与上游栈一致 |

### 10.8 跨文件新增（上游没有对应物）

这些符号不是单个上游符号的翻译，而是移植过程中为了保住语义补进来的：

| MoonBit 符号 | 落点 | 为什么需要 |
| --- | --- | --- |
| `FtpErrors` + `join_errors` + `flatten_errors` | `error.mbt` | MoonBit 没有 `errors.Join`；`stor_from` / `append` / `DataResponse::close` 要一次报出「传输错误 + 关闭错误 + 状态读取错误」 |
| `Session` + `Session::control` / `options` / `skip_epsv` / `use_pret` | `state.mbt` | 打破 `client` 与 `transport` 的循环依赖：两边都持有同一个 `Session` |
| `Options` | `state.mbt` | `dialOptions` 的传输层只读视图，避免 `transport` 依赖 `client` |
| `DialOptions` | `options.mbt` | 对外的可变选项包（对齐 Go 的 `...DialOption` 变参） |
| `DataConn` | `transport_dataconn.mbt` | Go 直接返回 `net.Conn`；MoonBit 需要显式表达「连接 + 是否已握手」 |
| `Control` | `control.mbt` | Go 的 `conn` 结构体（未导出），平铺后需要一个公开类型承载控制通道 |
| `ListFormat` | `parse.mbt` | 比 Go 多带「命中了哪种列表格式」，供测试断言与 `list` 分支 |
| `TeeReader` / `TeeWriter` | `debug.mbt` | Go 的 `io.TeeReader` 在 MoonBit 侧没有等价物 |

### 10.9 行为等价性备注

改名只是表面，下面这几条是**语义**层面的差异，逐条说明为什么可以接受：

**`errors.Join` → `FtpErrors`。** 上游 `StorFrom` 的结构是「累积 `errs` 数组 → 最后
`errors.Join`」，遇到第一个错误**不**提前返回。MoonBit 版保留了这个结构：`transfer.mbt`
里先 `errors.push(err)` 再继续走 `conn.close()` 与 `check_data_shut`，最后 `join_errors`
一次性抛出。`io.Copy` 的返回值语义（写到第几个字节错了）在 `stream` 里以「已写字节数」
形式保留。

**`sync.Mutex` → `lock` / `unlock`。** 上游每个公开方法开头 `c.mutex.Lock(); defer Unlock()`。
MoonBit 版在 `client.mbt` 里手写同一把锁，`defer` 语义由显式的 `defer client.unlock()` 承担，
加锁范围与上游逐个方法对齐。

**`context.Context` → async 取消。** `DialWithContext` 在 MoonBit 侧没有对应物：`async` 的
取消是结构化的，跟着 `async fn` 的调用链传播。因此超时由 `timeout_ms` / `shut_timeout_ms`
两个显式选项表达，取消由调用方的 `async` 作用域承担。

**`Response.SetDeadline` → 无。** 上游用它给数据连接设读截止时间。MoonBit 版的
`DataResponse` 不暴露 deadline 方法，`shut_timeout_ms` 只在 `226` 收尾那一次读上生效。
差异写进 docs/go-compat.md（待补）。

**`uint64` 偏移 → `Int64`。** `retr_from` / `stor_from` 的 `offset` 参数在 MoonBit 侧是
`Int64`，与 `@time` / `async` 生态的整数宽度保持一致；`REST` 命令本身仍是十进制文本，
超出 `Int64` 的偏移量在真实场景里不存在。

**命令注入防护逐字符对齐。** `check_for_command_injection` 检查的是**替换后的完整参数**，
不是格式串；只要含 `\r` 或 `\n` 就在发出任何字节之前抛 `FtpError::InvalidCommand`。

### 10.10 状态码常量对照（47 个，数值逐条核对）

| Go 常量 | MoonBit 常量 | 值 |
| --- | --- | --- |
| `StatusInitiating` | —（未导出，值已被 `status_data_connection_open_no_transfer` 覆盖） | 100 |
| `StatusRestartMarker` | `status_restart_marker_answer` | 110 |
| `StatusReadyMinute` | `status_restart_marker_reply` / `status_service_ready_soon` | 120 |
| `StatusAlreadyOpen` | `status_data_conn_already_in_use` / `status_data_connection_already_open` | 125 |
| `StatusAboutToSend` | —（值已在 `status_text` 表中） | 150 |
| `StatusCommandOK` | `status_data_connection_open_no_transfer` / `status_cmd_ok` / `status_enter_port` / `status_enter_extended_port` | 200 |
| `StatusCommandNotImplemented` | `status_cmd_not_implemented_superfluous` | 202 |
| `StatusSystem` | `status_system_status` | 211 |
| `StatusDirectory` | `status_dir_status` | 212 |
| `StatusFile` | `status_file_status` | 213 |
| `StatusHelp` | `status_help_message` | 214 |
| `StatusName` | `status_name_status` | 215 |
| `StatusReady` | `status_service_ready_for_new_user` | 220 |
| `StatusClosing` | —（值已在 `status_text` 表中） | 221 |
| `StatusDataConnectionOpen` | `status_session_opened_data_connection` | 225 |
| `StatusClosingDataConnection` | `status_closing_data_connection` | 226 |
| `StatusPassiveMode` | `status_enter_passive_mode` / `status_entering_passive_mode_from_ip` | 227 |
| `StatusLongPassiveMode` | —（值已在 `status_text` 表中） | 228 |
| `StatusExtendedPassiveMode` | `status_enter_extended_passive_mode` | 229 |
| `StatusLoggedIn` | `status_user_logged_in_proceed` | 230 |
| `StatusLoggedOut` | —（值已在 `status_text` 表中） | 231 |
| `StatusLogoutAck` | —（值已在 `status_text` 表中） | 232 |
| `StatusAuthOK` | `status_auth_ok` | 234 |
| `StatusRequestedFileActionOK` | `status_file_action_ok` | 250 |
| `StatusPathCreated` | `status_dir_create` | 257 |
| `StatusUserOK` | `status_username_ok_need_password` / `status_username_ok` | 331 |
| `StatusLoginNeedAccount` | `status_need_account_for_login` | 332 |
| `StatusRequestFilePending` | `status_file_action_pending_further_info` | 350 |
| `StatusNotAvailable` | `status_service_unavailable` | 421 |
| `StatusCanNotOpenDataConnection` | `status_cannot_open_data_connection` | 425 |
| `StatusTransfertAborted` | `status_transfer_aborted` | 426 |
| `StatusInvalidCredentials` | —（值已在 `status_text` 表中） | 430 |
| `StatusHostUnavailable` | —（值已在 `status_text` 表中） | 434 |
| `StatusFileActionIgnored` | `status_file_action_not_taken` / `status_action_not_taken` | 450 |
| `StatusActionAborted` | `status_file_action_aborted_local_error` | 451 |
| `Status452` | —（值已在 `status_text` 表中） | 452 |
| `StatusBadCommand` | `status_syntax_error_unknown_cmd` | 500 |
| `StatusBadArguments` | `status_syntax_error_unknown_params` / `status_restart_marker_not_understood` | 501 |
| `StatusNotImplemented` | `status_not_implemented` | 502 |
| `StatusBadSequence` | —（值已在 `status_text` 表中） | 503 |
| `StatusNotImplementedParameter` | `status_not_implemented_for_param` | 504 |
| `StatusNotLoggedIn` | `status_not_logged_in` | 530 |
| `StatusStorNeedAccount` | `status_need_account` | 532 |
| `StatusFileUnavailable` | `status_request_denied` / `status_file_action_aborted` | 550 |
| `StatusPageTypeUnknown` | `status_page_type_unknown` | 551 |
| `StatusExceededStorage` | `status_exceeded_storage_allocation` | 552 |
| `StatusBadFileName` | `status_bad_filename` | 553 |

`status_text` 覆盖的码比 `pub let` 常量多（`100` / `150` / `221` / `231` / `232` / `228`
/ `430` / `434` / `452` / `503` 只在文本表里），这与上游一致：上游也有常量没有全部导出成
可读名字，但 `StatusText` 认得它们。

## 11. 测试落点回填

对照 05-testing.md 的两条轨道，当前真实情况：

| 上游测试 | 用例数 | MoonBit 落点 | 状态 |
| --- | --- | --- | --- |
| `parse_test.go` | 30+ | `parse_test.mbt`（根包黑盒） | 四种格式、ACL、符号链接、多空格文件名、非法行、`UInt64` 抗溢出已覆盖 |
| `parse_test.go` 的时间部分 | 8 | `parse_time` 相关用例（根包） | 半年规则 4 条边界（`22:59` 不减年 / `23:00` 减年）已覆盖 |
| `scanner_test.go` | 6 | `scanner_test.mbt` | 含空串与中间态断言，逐条搬 |
| `constants_test.go` | 5 | `status_test.mbt` | 逐条搬 |
| `walker_test.go` | 10+ | `walker` 用例（待补） | **部分覆盖**：纯逻辑部分待补，见第 12 节 |
| `conn_test.go` | 20+ | `ftp_server_test.mbt` | 真机端到端 17 条，见 05-testing.md |
| `client_test.go` | 20+ | `ftp_server_test.mbt` | 同上 |
| `ftp_test.go` | 3 | 合并进 client 用例 | **未覆盖**：同上 |

白盒用例：`entry_wbtest.mbt`（entry 内部不变量）、`parse_time` 的字段级用例。

## 12. 缺口与后续动作

本节的每一条都是**已知未完成**，不写「已支持」：

1. **`RemoveDirRecur` 缺失**。上游用它做递归删除，MoonBit 版的 `fsops.mbt` 只有
   `make_dir` / `remove_dir` / `delete` / `rename`。补法是建在已有的 `Walker` 上（下游
   是「先遍历收集，再从深到浅删」），归到 W6。
2. **`walker_test.go` 的纯逻辑用例未搬**。`skip_dir`、空栈、`cur` 初始化可以在没有服务器的
   情况下断言，随 W6 一起补。
3. **端到端测试已落地为真机单轨**。`conn_test.go` / `client_test.go` 覆盖的用例现在跑在
   `jmoyer/vsftpd`（vsftpd 3.0.5）上，四个画像区分能力；命令序列断言改为副作用断言，
   取舍见 05-testing.md 3.2。
4. **`docs/go-compat.md` 未写**。本文件已经逐条记录了差异（10.9、10.10），但它还没有被
   整理成面向用户的「与 Go 版行为对照表」，归到 W8。
5. **`LICENSE-THIRD-PARTY` 未落地**。上游是 ISC，源码头部注释已标注，但仓库里还没有
   第三方许可证原文，归到 W8。
6. **`status.mbt` 的常量名与上游不是一一对应**。上游 47 个常量里有一部分在 MoonBit 侧
   用了更贴近 RFC 名字的写法（重名值散开成多个 `pub let`，见 10.10）。这是有意的，但如果
   后续要「按上游名字查找」，10.10 的表是唯一索引。
7. **`dial_func~` 未实现**。`dial` 现在只能真的去连地址，测试无法注入自定义连接；
   真机测试不需要它，所以不再阻塞，但仍未实现。
8. **`DialWithDialer` 只剩超时**。上游允许传入完整的 `net.Dialer`（含 `LocalAddr`、
   `KeepAlive` 等），MoonBit 侧目前只保留了超时；这些字段在 `moonbitlang/async` 里还没有
   对应表达，暂不做。
