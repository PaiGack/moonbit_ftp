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
| `walker_test.go` | 211 | `walker_test.mbt` | 纯逻辑用例直搬；依赖 mock 的用例改写 |
| `conn_test.go` | 449 | `*_test.mbt`（根包） | 需用 `TcpServer` 复刻 mock，见 05-testing.md |
| `client_test.go` | 445 | `*_test.mbt`（根包） | 需用 `TcpServer` 复刻 mock |
| `ftp_test.go` | 62 | 合并进 `client_test` | |

## 9. 不移植的部分（明确裁剪）

| 上游内容 | 处理 | 理由 |
| --- | --- | --- |
| `Connect` / `DialTimeout` | 不提供 | 上游已标 Deprecated，新库不留历史包袱 |
| `DialWithNetConn` | 不提供 | 上游已标 Deprecated，用 `dial_func` 替代 |
| 主动模式 | 上游本就没有 | 保持一致 |
| C 相关/平台特化代码 | 无 | 上游没有 |
