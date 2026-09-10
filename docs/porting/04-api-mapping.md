# 04 API 映射表

## 1. 类型映射

| Go | MoonBit | 说明 |
| --- | --- | --- |
| `*ServerConn` | `FTPClient` | 公开 API 载体 |
| `Entry{Name,Target,Type,Size,Time}` | `Entry{name,target,type_,size,time}` | 时间用 `ZonedDateTime` |
| `EntryType`（int 枚举） | `EntryType`（enum） | 显式枚举，`to_string()` 输出 `file`/`folder`/`link` |
| `TransferType`（string） | `TransferType`（enum） | `Binary` / `ASCII` |
| `Response`（ReadCloser） | `Response`（实现 `@io.Reader`） | `close()` 幂等 |
| `Walker` | `Walker` | 同结构，`Err()` → `err()` |
| `*textproto.Error` | `FtpError::ServerError(code~, msg~)` | 显式字段 |
| `ErrInvalidCommand` | `FtpError::InvalidCommand(arg~)` | |
| `errUnsupportedListLine` | `FtpError::UnsupportedListLine(line~)` | |
| `errUnsupportedListDate` | `FtpError::UnsupportedListDate(field~)` | |
| `errUnknownListEntryType` | `FtpError::ParseError(msg~)` | |
| `time.Time` + `*time.Location` | `@time.ZonedDateTime` | 时区显式化 |
| `context.Context` | 外层 `@async.with_timeout` / `with_task_group` | 不做成参数 |
| `io.Reader` / `io.Writer` | `@io.Reader` / `@io.Writer` | async trait |
| `net.Conn` | `@socket.Tcp` / `@tls.Tls` | 两者都实现 IO trait |
| `*tls.Config` | `trust~ : TrustedRoot` + `host~` | `Tls::client` 参数 |

## 2. 构造与选项

### Go 版 16 个 `DialWith*` 选项函数

| Go | MoonBit | 默认值 | 语义 |
| --- | --- | --- | --- |
| `DialWithTimeout(d)` | `timeout_ms~ : Int` | `30000` | 建连超时 |
| `DialWithShutTimeout(d)` | `shut_timeout_ms~ : Int` | `0` | 226 收尾读取前的 deadline 推动 |
| `DialWithDialer(net.Dialer)` | `dialer~ : @socket.Addr?` | `None` | 自定义建连方式 |
| `DialWithDialFunc(f)` | `dial_func~ : (String, Int) -> @io.Reader&@io.Writer` | `None` | 自定义建连函数（测试注入用） |
| `DialWithTLS(cfg)` | `tls~ : Bool` + `trust~` | `false` | 隐式 TLS |
| `DialWithExplicitTLS(cfg)` | `explicit_tls~ : Bool` + `trust~` | `false` | 显式 `AUTH TLS` |
| `DialWithDisabledEPSV(b)` | `disable_epsv~ : Bool` | `false` | 禁用 EPSV |
| `DialWithTrustPasvIP(b)` | `trust_pasv_ip~ : Bool` | `false` | 信任 PASV 返回 IP（**默认关闭防 SSRF**） |
| `DialWithDisabledUTF8(b)` | `disable_utf8~ : Bool` | `false` | 不发 `OPTS UTF8 ON` |
| `DialWithDisabledMLSD(b)` | `disable_mlsd~ : Bool` | `false` | 不用 MLSD，走 LIST |
| `DialWithWritingMDTM(b)` | `writing_mdtm~ : Bool` | `false` | 用 `MDTM` 写时间（VsFtpd） |
| `DialWithForceListHidden(b)` | `force_list_hidden~ : Bool` | `false` | `LIST -a`，且强制走 LIST |
| `DialWithLocation(loc)` | `location~ : @time.ZonedDateTime` | UTC 偏移 | 列表时间解析用 |
| `DialWithContext(ctx)` | — | — | 改用外层 async 取消 |
| `DialWithDebugOutput(w)` | — | — | 不移植：日志装饰器从未接线，选项只存不读，已删除 |
| `DialWithNetConn`（弃用） | — | — | 不移植，用 `dial_func` |
| （隐式由 `tls~` 承载） | `trust~ : TrustedRoot` | `SystemRoot` | 证书信任策略 |
| （隐式由 `dial_func` 承载） | — | — | — |
| （Go 特有） | — | — | — |

> Go 版实际有 **16 个 `DialWith*` 选项函数**（上游注释/文档常笼统说「19 个选项」，含已废弃的 `DialWithNetConn` 与内部字段）。
> 其中 TLS 相关 2 个、Dialer 相关 2 个在 MoonBit 侧各自合并成一个 `label~`。

### 调用形态

```moonbit
// Go:
//   c, err := ftp.Dial("ftp.example.org:21",
//       ftp.DialWithTimeout(5*time.Second),
//       ftp.DialWithDisabledEPSV(true))
let c = @ftp.dial(
  "ftp.example.org:21",
  timeout_ms=5000,
  disable_epsv=true,
)
```

设计约定：

- **可选参数一律 `label~`**，不用结构体字面量，避免调用方写出「一堆 `None`」。
- `dial` 是唯一入口；不提供 `connect` / `dial_timeout` 等废弃别名。
- 所有可能失败的方法 `raise`，不返回 `Result`（保持与 Go 版接近的调用手感）。

## 3. 方法级对照

| Go | MoonBit | 备注 |
| --- | --- | --- |
| `Dial(addr, opts...)` | `dial(addr, ...labels)` | 首行期望 220 |
| `Login(user, pass)` | `login(user, password)` | 含 FEAT 协商 |
| `Logout()` | `logout()` | `REIN`，期望 220 |
| `NoOp()` | `no_op()` | `NOOP`，期望 200 |
| `Quit()` | `quit()` | 聚合错误 |
| `Type(t)` | `set_transfer_type(t)` | `Type` 是保留感较强的名字，改名更清晰 |
| `NameList(path)` | `name_list(path)` | `NLST` |
| `List(path)` | `list(path)` | MLSD 优先 |
| `GetEntry(path)` | `get_entry(path)` | `MLST` |
| `IsTimePreciseInList()` | `is_time_precise_in_list()` | |
| `ChangeDir(path)` | `change_dir(path)` | `CWD` |
| `ChangeDirToParent()` | `change_dir_to_parent()` | `CDUP` |
| `CurrentDir()` | `current_dir()` | `PWD` |
| `FileSize(path)` | `file_size(path)` | `SIZE` |
| `GetTime(path)` | `get_time(path)` | `MDTM` 读 |
| `IsGetTimeSupported()` | `is_get_time_supported()` | |
| `SetTime(path, t)` | `set_time(path, t)` | `MFMT` / `MDTM` 写 |
| `IsSetTimeSupported()` | `is_set_time_supported()` | |
| `Retr(path)` | `retr(path)` | |
| `RetrFrom(path, off)` | `retr_from(path, offset~)` | |
| `Stor(path, r)` | `stor(path, reader)` | |
| `StorFrom(path, r, off)` | `stor_from(path, reader, offset~)` | |
| `Append(path, r)` | `append(path, reader)` | |
| `Rename(from, to)` | `rename(from, to)` | |
| `Delete(path)` | `delete(path)` | |
| `RemoveDirRecur(path)` | `remove_dir_recur(path)` | |
| `MakeDir(path)` | `make_dir(path)` | `MKD` |
| `RemoveDir(path)` | `remove_dir(path)` | `RMD` |
| `Walk(root)` | `walk(root)` | |
| `Response.Read` | `@io.Reader` 实现 | |
| `Response.Close` | `close()` | 幂等 |
| `Response.SetDeadline(t)` | `with_deadline(ms, f)` | **形状变化**，见 01-architecture.md 第 7 节 |
| `Walker.Next()` | `next()` | |
| `Walker.SkipDir()` | `skip_dir()` | |
| `Walker.Err()` | `err()` | |
| `Walker.Stat()` | `stat()` | |
| `Walker.Path()` | `path()` | |
| `EntryType.String()` | `to_string()` | |
| `StatusText(code)` | `@status.text(code)` | 纯逻辑包，可独立用 |

## 4. 典型调用对照

### 下载文件

```go
// Go
c, err := ftp.Dial("ftp.example.org:21", ftp.DialWithTimeout(5*time.Second))
if err != nil { return err }
defer c.Quit()
if err := c.Login("anonymous", "anonymous"); err != nil { return err }
r, err := c.Retr("a.txt")
if err != nil { return err }
defer r.Close()
buf, err := io.ReadAll(r)
```

```moonbit
// MoonBit
let c = @ftp.dial("ftp.example.org:21", timeout_ms=5000)
c.login("anonymous", "anonymous")
let r = c.retr("a.txt")
let buf = r.read_all()
r.close()
c.quit()
```

### 递归遍历

```go
// Go
w := c.Walk("/root")
for w.Next() {
    if w.Stat().Type == ftp.EntryTypeFile {
        fmt.Println(w.Path(), w.Stat().Size)
    }
}
if err := w.Err(); err != nil { return err }
```

```moonbit
// MoonBit
let w = c.walk("/root")
while w.next() {
  let e = w.stat()
  if e.type_ is File {
    println("\{w.path()} \{e.size}")
  }
}
if w.err() is Some(e) { raise e }
```

### 带超时的单次操作

```go
// Go
r, err := c.Retr("big.bin")
r.SetDeadline(time.Now().Add(3 * time.Second))
io.Copy(dst, r)
```

```moonbit
// MoonBit：能力等价，形状改为限时作用域
let r = c.retr("big.bin")
r.with_deadline(3000, fn() {
  // 在此作用域内的读写超过 3s 会被取消
})
r.close()
```

## 5. 命名约定

- **公开类型/构造函数**：`FTPClient` / `Entry` / `dial` / `walk`
- **方法用 snake_case**：`change_dir` / `name_list` / `retr_from`
- **可选参数后缀 `~`**：`offset~` / `timeout_ms~` / `trust_pasv_ip~`
- **时间参数带单位后缀**：`timeout_ms` / `shut_timeout_ms`，不写裸 `timeout`
- **布尔选项一律用肯定式**：`disable_epsv` / `trust_pasv_ip`（与上游字段同名，便于对照源码）

## 6. 有意不提供的 API

| 上游 API | 不提供的原因 |
| --- | --- |
| `Connect(addr)` | 上游已 Deprecated，是 `Dial` 的别名 |
| `DialTimeout(addr, d)` | 上游已 Deprecated，用 `timeout_ms~` |
| `DialWithNetConn(conn)` | 上游已 Deprecated，用 `dial_func~` |
| `DialWithDialer(net.Dialer)` 原样暴露 | 直接暴露 `net.Dialer` 形状不适用，收敛成 `dialer~` |
