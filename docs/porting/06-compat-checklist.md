# 06 兼容性落地清单

上游 `jlaffaye/ftp` 的价值不在 socket 封装，而在它把 FTP 四十年的服务器差异磨平了。
下面 9 条是「能不能连上真实服务器」的分水岭。**每条都必须有对应实现 + 对应测试**，
验收时逐条打勾。

---

## 1. 数据通道关闭后必须回控制通道读 226/250

**上游位置**：`checkDataShut()`，被 `StorFrom` / `Append` / `Response.Close` 调用。

**为什么要做**：FTP 是「控制通道 + 数据通道」双连接。数据传输完成后，服务器会在**控制通道**上补一条
`226 Transfer complete`。如果客户端传完就关数据连接、不回控制通道读这条，
这条 `226` 会滞留在控制通道的缓冲区里。下一条命令发出后，读到的是**上一条的 `226`**，
造成整个响应序列错位——表现为「登录正常、`ls` 正常、但 `get` 之后所有命令都报错」。

**这是 FTP 客户端最常见的实现 bug**，且症状延迟出现，极难排查。

**落地**：

```moonbit
///|
async fn FTPClient::check_data_shut(self : Self) -> Unit raise {
  // 若配置了 shut_timeout，先推一下控制连接 deadline，
  // 避免控制通道刚好处在空闲超时边界时读响应失败
  if self.options.shut_timeout_ms != 0 {
    self.nudge_control_deadline()
  }
  let (code, _) = @control.read_response(self.control, expected=226)
  ignore(code)
}
```

**测试**：

- [ ] `stor` 完成后控制连接仍可响应命令（没有多发/错发命令）
- [ ] `stor` 之后紧接一条 `size` 命令，能拿到正确结果（不错位）
- [ ] `response.close()` 之后再执行任意命令，响应正确

---

## 2. EPSV 失败一次后置 skipEPSV，后续直接走 PASV

**上游位置**：`getDataConnPort()`。

**为什么要做**：部分服务器 FEAT 里声明支持 `EPSV`，实际执行却报错（或超时）。
如果不记状态，每次建数据连接都要先白等一次 EPSV 失败，大目录遍历时开销被放大几十倍。

**落地**：

```moonbit
///|
async fn FTPClient::get_data_port(self : Self) -> (String, Int) raise {
  if !self.options.disable_epsv && !self.skip_epsv {
    match self.epsv() {
      Ok(port) => return (self.host, port)
      Err(_) => self.skip_epsv = true   // 只失败一次，之后不再尝试
    }
  }
  self.pasv()
}
```

**测试**：

- [ ] `no-epsv` 画像让 `EPSV` 返回 `550` → 客户端仍能建数据连接（走了 PASV，且两次传输都不重试 EPSV）
- [ ] 连续做两次数据操作，断言 `commands` 里 `"EPSV"` **只出现 1 次**

---

## 3. TLS 数据连接延迟握手 + 零字节上传显式握手

**上游位置**：`openDataConn()` 注释 + `StorFrom()` 的 `Handshake()` 调用。

**为什么要做（两个坑）**：

**坑一**：不能直接用 `tls.DialWithDialer`（先 Dial → 建 Client → 立即 Handshake）。
ProFTPD 和 PureFTPD 在数据连接上会挂住：它们期待客户端先发数据再握手，或者对握手时机有特殊要求。
正确做法是 `Dial` 之后只包一层 `tls.Client`，**把握手推迟到首次 `Read`/`Write`**。

**坑二**：上传零字节文件时，因为没调用 `Write`，握手永远不会触发，服务器收到一个未握手的空连接，
报 `Unable to build data connection: Operation not permitted`。
所以零字节上传路径必须**显式调一次握手**。

**落地**：

```moonbit
///| 建数据连接：TLS 时只包不握手（握手交给首次读写）
async fn open_data_conn(self : Self) -> DataConn raise {
  let (host, port) = self.get_data_port()
  let raw = @socket.Tcp::connect_to_host(host, port=port)
  guard self.options.tls is false else { return raw }   // 无 TLS 直接返回
  // 关键：只构造，不握手
  @tls.Tls::client(raw, trust=self.options.trust, host=self.host)
}

///| 上传：零字节时显式握手，否则 Write 不会被调用
async fn FTPClient::stor_from(self, path, reader, offset) -> Unit raise {
  let conn = self.cmd_data_conn_from(offset~, cmd="STOR", args=[path])
  let mut errs : Array[Error] = []
  let n = conn.copy_from(reader) catch { e => errs.push(e); 0 }
  if n == 0 && self.options.tls {
    conn.handshake() catch { e => errs.push(e) }   // 零字节特例
  }
  conn.close() catch { e => errs.push(e) }
  self.check_data_shut() catch { e => errs.push(e) }
  raise_multiple(errs)
}
```

**已实测**：`@tls.Tls::client(raw, trust=..., host=...)` 在 `moonbitlang/async` 0.21.3 中是
async 构造函数，形态与「只包不握手」的需求吻合（实测编译通过，`moon check --target native` 无错误）。

**测试**：

- [ ] 上传空文件（0 字节）到真实服务器 → 服务器正常返回 `226`，不报 `425` / `Operation not permitted`
- [ ] 数据连接建立后立即开始读写，无额外握手阻塞

---

## 4. 命令参数拒绝 CR / LF

**上游位置**：`checkForCommandInjection()`，被 `cmd()` 在**发命令之前**调用。

**为什么要做**：FTP 是纯文本行协议。如果文件名来自用户输入（比如 `rename(evil, "a\r\nDELE important")`），
攻击者可以注入第二条命令。这是**真实的远程命令注入漏洞**，不是理论风险。

**落地**：

```moonbit
///|
fn check_for_command_injection(arg : String) -> Unit raise {
  if arg.contains("\r") || arg.contains("\n") {
    raise @error.FtpError::InvalidCommand(arg~)
  }
}

///|
async fn FTPClient::cmd(self, expected, cmd, args) -> (Int, String) raise {
  check_for_command_injection(cmd)
  for arg in args { check_for_command_injection(arg) }
  ...
}
```

**关键**：检查必须在**任何字节写到 socket 之前**。检查晚了就没意义了。

**测试**：

- [ ] `rename("a\r\nDELE x", "b")` 抛 `InvalidCommand`
- [ ] 抛异常后会话仍可用（`SIZE` 仍返回 12、`PWD` 正常），证明一个字节都没发
- [ ] 含 `\n` 的文件名上传/下载同样被拒

---

## 5. `errors.Join` 语义：多个错误一起报

**上游位置**：`Quit` / `Stor` / `StorFrom` / `Append` / `List` / `NameList` / `Response.Close`。

**为什么要做**：这些操作都有「多阶段收尾」结构：传输 → 关数据连接 → 读控制响应。
如果遇到第一个错误就 `return`，剩下的错误被吞掉，用户只能看到表象（比如「传输失败」），
看不到真正原因（比如「226 读取时连接被服务器断了」）。上游刻意用 `errors.Join` 把所有错误都带出来。

**落地**：

```moonbit
///| 收集所有错误后统一抛出；空数组不抛
fn raise_multiple(errs : Array[Error]) -> Unit raise {
  match errs.length() {
    0 => ()
    1 => raise errs[0]
    _ => raise @error.FtpErrors::MultipleErrors(errors=errs)
  }
}

///|
async fn Response::close(self : Self) -> Unit raise {
  if self.closed { return }        // 幂等（见第 9 条）
  let mut errs : Array[Error] = []
  self.conn.close() catch { e => errs.push(e) }
  self.client.check_data_shut() catch { e => errs.push(e) }
  self.closed = true
  raise_multiple(errs)
}
```

**必须逐一对齐的聚合点**：

| 方法 | 聚合的阶段 |
| --- | --- |
| `Response::close` | 关数据连接 + 226 收尾 |
| `stor_from` | 传输 + 关连接 + 226 收尾 |
| `append` | 传输 + 关连接 + 226 收尾 |
| `list` | scanner 错误 + 关连接 + 226 |
| `name_list` | scanner 错误 + 关连接 + 226 |
| `quit` | 发 `QUIT` + 关控制连接 |

**测试**：

- [ ] 构造「传输失败 + 226 也失败」的场景，断言错误里**同时**含两条信息
- [ ] 全部成功时不抛异常

---

## 6. PASV 返回 IP 默认不信任

**上游位置**：`pasv()` + `isBogusDataIP()`。

**为什么要做**：`PASV` 响应里服务器会给出它认为的数据连接 IP。部分服务器（尤其在 NAT / 多网卡后面）
会返回一个客户端**根本连不上**的内网 IP，导致数据连接失败。更严重的是 SSRF：
恶意服务器可以诱导客户端去连任意内网地址。

上游策略：**默认使用控制连接的 IP**；仅当显式 `trustPasvIP` 且返回的 IP 不是「可疑 IP」时才用服务器给的。

「可疑 IP」判定（抄自 lftp）：

```
dataIP 是组播地址
或 控制 IP 与数据 IP 的「私网性」不一致（一个私网一个公网）
或 两者的「回环性」不一致
```

**落地**：

```moonbit
///|
fn is_bogus_data_ip(cmd_ip : @socket.Addr, data_ip : @socket.Addr) -> Bool {
  data_ip.is_multicast() ||
  cmd_ip.is_private() != data_ip.is_private() ||
  cmd_ip.is_loopback() != data_ip.is_loopback()
}
```

> 注意：`@socket.Addr` 目前提供 `is_multicast()`，`is_private` / `is_loopback` 若缺失需要按 IP 段自行判断
> （10/8、172.16/12、192.168/16、127/8、169.254/16、fc00::/7、::1）。**这是 W3 要确认的一个 API 缺口**。

**测试**：

- [ ] 控制连接 `127.0.0.1`，PASV 返回 `127,0,0,2` → 默认**连 `127.0.0.1`**（断言实际连的地址）
- [ ] `trust_pasv_ip=true` 时 → 连 `127.0.0.2`
- [ ] 对照组：控制连接公网 IP、PASV 返回私网 IP → 判定为可疑，仍用控制 IP

---

## 7. LIST 时间「半年规则」

**上游位置**：`Entry::setTime()`。

**为什么要做**：`ls -l` 的时间字段在**最近 6 个月内**显示为 `MMM DD HH:MM`（无年份），
更早的显示为 `MMM DD YYYY`。所以遇到 `MMM DD HH:MM` 时必须自己推断年份：

- 先按**当前年份**补年份
- 如果补出来的时间**不早于 `now + 6 个月`**，说明是「未来」，实际应该是**去年**

不做这一步，目录里所有近半年外的文件时间都会漂到今年，增量同步逻辑全错。

**边界的精确语义**：判定条件是 `!time.Before(now.AddDate(0, 6, 0))`，即
**`time >= now + 6个月`** 才减年。等于边界时要减年。

**落地**（边界测试用固定 `now = 2017-03-10 23:00 UTC`）：

| 输入 | 期望 | 说明 |
| --- | --- | --- |
| `Feb 10 23:00` | 2017-02-10 | 今年，过去 |
| `Sep 10 22:59` | 2017-09-10 | 未来 5 个月 29 天 → 不减 |
| `Sep 10 23:00` | 2016-09-10 | 未来正好 6 个月 → **减** |
| `Jan 23  2019` | 2019-01-23 | 有年份，不套规则 |

另外：`MMM DD YYYY` 形式里**年份必须恰好 4 位**，否则报 `UnsupportedListDate`（不是回退到别的解析器）。

见 [05-testing.md](./05-testing.md) 第 2.2 节的用例表。

---

## 8. 四种解析器逐级回退

**上游位置**：`parseListLine()` + `listLineParsers` 数组。

**回退顺序（固定）**：

```
parseRFC3659ListLine   →   parseLsListLine   →   parseDirListLine   →   parseHostedFTPLine
```

**关键语义（容易做错的地方）**：

- 每个解析器返回 `UnsupportedListLine` 表示「**这不是我的格式**」，于是继续试下一个。
- 但如果解析器**已经识别出形状、只是在细节上出错**（比如 ls 形状里出现未知的 entry 类型字符 `Z`），
  它返回的是 `ParseError`（上游 `errUnknownListEntryType`），此时**立刻停止回退并报错**。
- 四个都不认 → 报 `UnsupportedListLine`。

**这条「形状对了就不能再回退」的规则必须保住**，否则 `Zrwxrwxrwx ...` 这类行会被误判，
错误类型也会和上游对不上。

**测试**：

- [ ] `Zrwxrwxrwx ...` → `ParseError`（**不是** `UnsupportedListLine`）
- [ ] `drwxr-xr-x ... Dec 02  209 pub` → `UnsupportedListDate`（ls 形状认出、年份错）
- [ ] `total 1` → `UnsupportedListLine`（四个都不认）
- [ ] `list()` 遇到 `total 1` 这类行**跳过不报错**（列表层面容错）
- [ ] RFC3659 行不会被 ls 解析器抢先命中（各解析器的前置条件不重叠）

---

## 9. `Response.Close` 幂等

**上游位置**：`Response.Close()` 的 `if r.closed { return nil }`。

**为什么要做**：`Response` 是「可读句柄 + 资源持有者」。调用方常写成 `defer r.Close()`，
后面又手动 `Close()` 一次做错误检查。若不幂等，第二次会去关一个已关的连接、再读一次 226，
把控制通道的响应序列彻底搞乱。

**落地**：

```moonbit
///|
async fn Response::close(self : Self) -> Unit raise {
  if self.closed { return }
  self.closed = true
  // ... 聚合错误
}
```

> 注意实现细节：**先把 `closed` 置 true，再做收尾**。
> 如果先收尾再置标志，收尾过程中出错抛出，标志就永远置不上，第二次调用还会再来一遍。

**测试**：

- [ ] `close()` 两次，第二次不抛异常
- [ ] 第一次之后行为没有因第二次调用而变化（`no-epsv` 画像连做两次 `RETR`）

---

## 附：服务器画像 → 兼容性条目 覆盖矩阵

| 画像 | 特征 | 覆盖的条目 |
| --- | --- | --- |
| `no-time` | `MDTM` / `MFMT` 均不支持 | — |
| `std-time` | `MDTM` 读 + `MFMT` 写 | — |
| `vsftpd` | 只有 `MDTM`，用 `MDTM <time> <path>` 写时间 | — |
| `bogus-pasv-ip` | PASV 返回 `127,0,0,2` | **6** |
| `no-epsv` | EPSV 报错 | **2** |
| `multi-line-pass` | `PASS` 返回多行 | 解析器 |
| `list-with-noise` | LIST 数据里混 `total 1` | **8** |
| `zero-byte-upload` | 上传 0 字节 | **3** |
| `tls-data` | 数据连接走 TLS | **3** |
| `multiline-mlst` | MLST 多行同名 | 解析器 |

## 验收勾选表

```
[ ] 1. 数据通道关闭后读 226        —— 实现 + 测试
[ ] 2. EPSV 失败后 skipEPSV        —— 实现 + 测试（断言只发一次）
[ ] 3. TLS 延迟握手 + 零字节握手    —— 实现 + 测试
[ ] 4. 参数拒 CR/LF 且发送前检查   —— 实现 + 测试（断言零字节发出）
[ ] 5. 多错误聚合                  —— 实现（6 个聚合点逐一对照）+ 测试
[ ] 6. PASV 默认不信任返回 IP      —— 实现 + 测试（两种配置对比）
[ ] 7. 半年规则                    —— 实现 + 4 条边界测试
[ ] 8. 四解析器回退 + 形状锁定      —— 实现 + 5 条测试
[ ] 9. Response.Close 幂等         —— 实现 + 测试
```

**这 9 条全部打勾之前，不要进入 W7（CLI）**——CLI 会直接暴露这些问题的症状，
而 CLI 层面的症状远不如单测断言好定位。
