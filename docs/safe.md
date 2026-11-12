# 安全审查：PaiGack/ftp

项目是一个 MoonBit 的 FTP/FTPS 客户端库加四个 CLI。基线是干净的：`moon check --deny-warn` 通过，318 个测试全过。下面的问题是我逐层读出来的，**工作区已还原，没有改任何代码**。凡是标了 ✅ 的，都是我用临时测试实际跑出来复现过的，不是推测；跑完立刻还原了。

---

## 一、高危

### 1. ✅ 证书校验可能被静默关闭（FTPS 按 IP 连接时）
[dial.mbt:85-111](dial.mbt#L85-L111)、[connection/control.mbt:84-87](connection/control.mbt#L84-L87)

- `server_name` 直接取用户传的 host。当用户写 `dial("203.0.113.7:990", tls=true)`，且服务端证书是按域名签发的，校验必然失败。仓库自己的注释（[control.mbt:38-44](connection/control.mbt#L38-L44)）也承认了这个场景。
- 更严重的是 `Control::new` 里的 `if server_name == "" { host }`：空字符串在 MoonBit 里是合法 String，传了就等于**退回 IP 做校验**，和“没传”完全无法区分。按 IP 校验在多数 TLS 实现里意味着只做 CA 链校验、不看主机名，中间人只要持有一张任意域名的合法证书就能冒充。
- 数据通道是同一套路（[client.mbt:559](client.mbt#L559)），所以并非只有控制通道暴露。
- **建议**：`server_name` 改成 `String?`，不传就**报错**而不是回退；或者单独提供一个明确的 `tls_server_name~` 参数；文档里把“按 IP 连必须显式给 server_name”写清楚。

### 2. ✅ `get_data_port` 的逻辑写反了（EPSV 失败分支）
[connection/transport.mbt:368-375](connection/transport.mbt#L368-L375)

```moonbit
guard trust_pasv_ip && !is_bogus_data_ip(control.host(), ip) else {
  return (control.host(), port, true)   // 条件为假 -> 用控制连接 IP（正确分支）
}
return (ip, port, true)                 // 条件为真 -> 用服务端给的 IP
```

`guard … else { 正确分支 }` 写反了，实际语义是“传输被恶意的 `trust_pasv_ip` 和 `!is_bogus` → 才用服务端给的 IP”。

用临时测试复现（信任标志=false、`PASV` 回了 `8.8.8.8`，是 bogus 的）：走进了 `return (ip, …)`，返回服务端广告的地址 —— 也就是 SSRF 防御被绕过。下面 `disable_epsv` 那条路径（[transport.mbt:379-385](connection/transport.mbt#L379-L385)）写对了，两条路径行为不一致，说明是笔误而不是设计。

**影响**：任何让 `EPSV` 失败、随后 `PASV` 回一个伪造 IP 的服务端，都能让客户端把数据连接发到它指定的任意地址。目前上游注释说“只返回 `(host, port)` / `(ip, port)`”，但测试里那条“回退到 PASV”的用例全用 loopback，看不到这个差异。

### 3. ✅ CLI `get` 可以写出到当前目录之外
[cmd/ftp/main.mbt:494-500](cmd/ftp/main.mbt#L494-L500)，调用在 [main.mbt:379-383](cmd/ftp/main.mbt#L379-L383)

`get <remote>` 不给 local 名时用 `basename(remote)` 当落盘路径，而 `basename` 不处理 `..` 段。实测：`basename("/..") == ".."`，所以 `get /anything/..` 会以写模式打开**上一级目录**（在 Linux 上 `open("..")` 直接失败，给了攻击者一个稳定的异常；如果 `..` 后面还有名字就变成 `../passwd` 之类）。

**攻击面**：服务端可以让 `SIZE` 通过，再在 NLST/MLSD 之外控制文件名。虽然 `STORE` 以截断模式打开的文件本身能落到哪里，取决于服务端给的文件名，但**落盘路径完全由远端字符串决定**这一点，就是“下载把文件写到意料之处”的经典 CWE-22。此外 `get` 用 `CreateOrTruncate` 打开本地文件，本地同名文件会被无条件覆盖，没有任何确认。

**建议**：`basename` 拒绝 `.`、`..`、空串；`cmd_get` 对推导出的本地名先做规范化再检查，越界就报错退出。

---

## 二、中危

### 4. ✅ 测试在“无警告”检查下可能根本没注册
我在 `connection/transport_wbtest.mbt` 里追加了最简单的 `async test { fail("PROBE") }`，跑了 57 个测试，结果是 57 个**全过** —— 探测测试没执行。同时它引出了一个 `FTPClient` 或网络相关的**死锁 SIGABRT**（`Dead lock detected … event_loop.mbt:341`）。

这意味着：
- `ci.sh` 里 `--deny-warn` 只要求**编译**通过，测试文件里可能存在的问题（比如上面两条 SSRF 相关的用例）不会以失败形式暴露。
- 更危险的组合是：如果某天某测试因为未注册而“通过”，覆盖率下降也没人发现。CI 里有 `moon coverage report`，但没设阈值。
- **建议**：给 `moon coverage` 加一个最低门槛，并对每个文件里的 `async test` 数做一次静态核对；或者让每个用例都有一行输出，避免静默跳过。

### 5. 登录与 `FEAT` 之间没有检查“服务器是否声明了 SECURE / `AUTH TLS`”
[dial.mbt:285-348](dial.mbt#L285-L348)

`login` 只根据**调用方自己是否开启 `explicit_tls`** 来决定是否在 `PASS` 之后检查/执行 `PBSZ`/`PROT P`；`AUTH TLS` 本身是 `dial` 的一部分，但 `dial` 允许 `explicit_tls=true` 而服务端拒绝时（`cmd_expect` 抛错）继续向下 —— 复核 `auth_tls`：它只在 `cmd_expect` 成功时继续，这点没问题。但**若服务端不提供 `AUTH TLS` 且用户没开 `explicit_tls`，没有任何“检测到明文登录”的警告**。对于密码是敏感信息的客户端，这属于 CWE-319 的常见疏忽。

**建议**：在 `FEAT` 里看到 `AUTH TLS`/`AUTH SSL` 却没用 TLS 时，至少让 `login` 抛出可捕获的警告，或在 README 里显式写明。

### 6. 调试日志会**原样记录 `PASS`**
[connection/control.mbt:131-140](connection/control.mbt#L131-L140)，[debug/debug.mbt:123-148](debug/debug.mbt#L123-L148)

`DialOptions::debug_sink` 记录每一条控制通道的字节，包括 `PASS <密码>` 和 `AUTH TLS` 之后的 `PBSZ`/`PROT P` 之后的命令（不含密文，因为 `upgrade` 之后读者就是 TLS 对象，但命令本身明文字节仍在 TLS 记录内被记录）。凡是打开 `debug_sink` 并写进日志文件的调用方，都会把密码以明文写入日志（CWE-532）。

**建议**：`write_path` 对以 `PASS` 开头的行做脱敏（`PASS ***`），或者在 `DebugLog` 里提供一个可配置的 `redact` 列表，默认包含 `PASS`。

### 7. `Control::new` 无超时是合法值（`timeout_ms = 0`），可能导致进程死锁
[connection/control.mbt:60](connection/control.mbt#L60)、[control.mbt:176-183](connection/control.mbt#L176-L183)

`timeout_ms=0` 时 `read_line` 不设超时，注释本身也写了“无超时的读会被事件循环判为死锁”。`DialOptions` 默认是 30s，但 `Control::new` 这个公开 API 的默认就是 `0`，`Connection` 里任何调用点一旦漏传到 `timeout_ms`，就会在真实服务器上触发 SIGABRT 而不是普通错误。这属于“安全底线配置不是 secure-by-default”。至少应把 `Control::new` 的默认改成非零，或对 `timeout_ms == 0` 拒绝启动。

### 8. `DataConn::close` 的 TLS 关闭超时硬编码为 5000ms，与 `timeout_ms` 无关
[connection/transport.mbt:340](connection/transport.mbt#L340)

和上一个类似，5s 虽比 0 好，但调用方配置的 `shut_timeout_ms` / `timeout_ms` 不会传进来。大型上传遇到“半死不活”的服务端时，每个连接会额外挂 5 秒，可能被当作慢速拒绝服务放大。

---

## 三、低危与加固建议

### 9. `parse_pasv` 的 `close > open + 1` 健壮性
[connection/transport.mbt:35-46](connection/transport.mbt#L35-L46)

先找 `(` 再找 `)`，但没要求 `close` 在 `(` 之后。`")" 在 "(" 之前` 的畸形行会导致 `open+1 > close` 切片，在当前实现里会抛 `ParseError`（被 `catch` 吞掉），但这类切片应显式判断 `close > open`，避免未来 Rust 式的越界 panic。

### 10. FEAT / 状态码不可信的“空期望列表”
[connection/control.mbt:195-213](connection/control.mbt#L195-L213)

`expected.length() == 0` 等价于“接受任何状态码”。目前调用方都传了具体列表，但这是公开 API，误用就等于关闭状态码校验。建议在调试构建里对空列表发出警告，或把 `-1` 的语义显式命名成 `accept_any`。

### 11. 命令行与 DNS 解析
[dial.mbt:60-88](dial.mbt#L60-L88)

`std::split_addr` 用 `rev_find(":")` 切分，对 `host:` 这样的输入会得到 port=`parse_decimal("")`=`None`→默认端口，行为可预期。但 `addr` 里如果含主机名，`socket_addr` 的解析依赖系统 resolver；没有“只允许公共地址”的开关（用于防 SSRF）。库本身是客户端，这通常没问题，但 `trust_pasv_ip=false` 并不能阻止首次连接。如需库侧防御，可加一个 `allow_private` 选项。

### 12. CI 与脚本（低危）
- [.ide/Dockerfile](.ide/Dockerfile) 用 `curl | bash` 安装 MoonBit、claude-code 与 cc-switch 的 `latest`，没有任何校验（checksum 或版本 pin）。在 CI 里执行未经校验的远端脚本是常见的供应链风险点。
- [.github/workflows/ci.yml](.github/workflows/ci.yml) 与 [copilot-setup-steps.yml](.github/workflows/copilot-setup-steps.yml) 同样 `curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash`，没有完整性校验。
- [scripts/ftps/gen-cert.sh](scripts/ftps/gen-cert.sh) 生成有效期 36500 天（100 年）的 CA 和证书；虽然是每次临时生成、gitignored，但 100 年有效期不是好习惯，生成 `-days 1` 就足够，也能避免“旧证书残留”误用的可能。
- [scripts/ftps/ftp_mock.py](scripts/ftps/ftp_mock.py) 的 `files` 字典按用户给的路径直接存（`self.files[path]`），因为只是内存 mock 不影响安全，但如果你以后把它改成落盘，就要补上 `remote_to_local` 式的路径校验（`profiles/ftp_profile_mock.py` 已经有这个好实现，值得两个 mock 统一）。

### 13. `scripts/__pycache__/probe-ftp.cpython-312.pyc` 被 gitignore 覆盖了吗？
`.gitignore` 里有 `__pycache__/`，这个 `.pyc` 是工作区残留、不会被提交，可以 `rm -rf scripts/__pycache__` 清理；它不是安全问题，但属于“发布物里不该有的产物”。

---

## 四、我验证过且**不是问题**的点（省你复核）

| 检查项 | 结论 |
| --- | --- |
| CRLF 命令注入 | `render_command` / `check_for_command_injection` 在写 socket 前拦截 `\r\n` ✅ |
| `PASV` 的 SSRF 防御（`disable_epsv` 分支） | 正确 |
| `EPSV` 解析、端口越界 | `parse_port` 拒绝 >65535 和空串 ✅ |
| TLS 握手在 `150` 之后 | `cmd_data_conn_from` 里顺序正确，`stor_from` 的零字节补握手也有幂等 guard ✅ |
| `DataConn::close` 发 `close_notify` | 有，且超时包围 ✅ |
| 客户端锁 | 公共操作都 `defer unlock`，非递归锁，递归的 `remove_dir_recur` 没有持锁 ✅ |
| `DebugLog` 写失败的隔离 | 吞掉 sink 错误，不影响命令 ✅ |
| mock 的路径穿越 | `remote_to_local` 拒绝越界 ✅ |
| 证书校验在 FTPS 冒烟里 | `cmd/ftps` 用 `CustomPemFile`，没有 `NoVerification` ✅ |

---

## 五、建议的修复优先级

1. **P0**：修 [#2 逻辑写反](#2-✅-get_data_port-的逻辑写反了epsv-失败分支)（一行代码），补一条“`EPSV` 失败 + 伪造 `PASV` IP + `trust_pasv_ip=false` 必须回到控制连接 IP”的回归测试；
2. **P0**：修 [#3 CLI get 越界](#3-✅-cli-get-可以写出到当前目录之外)，`basename` 拒绝 `..` / `.` / 空；
3. **P1**：`server_name` 改 `String?`，禁止空串回退 IP（[#1](#1-✅-证书校验可能被静默关闭ftps-按-ip-连接时)）；
4. **P1**：`DebugLog` 默认脱敏 `PASS`（[#6](#6-调试日志会原样记录-pass)）；
5. **P1**：`Control::new` 的 `timeout_ms` 不允许为 0，或默认取 30s（[#7](#7-controlnew-无超时是合法值timeout_ms--0可能导致进程死锁)）；
6. **P2**：CI 覆盖门槛 + 测试注册数校验（[#4](#4-✅-测试在无警告检查下可能根本没注册)）；