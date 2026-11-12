我把结论按严重程度和维度整理出来。先说明基线：`moon test` 347 个全过，代码质量和测试覆盖度整体很高，文档里大量注释在解释「为什么这样写」。所以下面多数问题属于**边界场景 / 健壮性 / 供应链**，而不是代码写错。

另外一点：`docs/safe.md` 现在是个空文件（`c438733` 写入、`e553eda` 清空了内容），但 `AGENTS.md` 和提交历史仍引用它 —— 这是个文档一致性问题。

---

## 一、安全

### S1【中】`PASV` 的 SSRF 防护有缺口
[connection/transport.mbt:79-137](connection/transport.mbt#L79-L137)

- `EPSV` 路径直接用控制连接的 IP，很安全；`PASV` 路径在 `trust_pasv_ip=false` 时也会回落到控制连接 IP，这是对的。
- 但 `is_private` / `is_loopback` / `is_multicast` 的 IPv6 判断只是**文本前缀匹配**：`fc`/`fd` 判私有、`ff` 判组播、精确等于 `::1` 判 loopback。`::ffff:127.0.0.1`、`fe80::`（链路本地）、以及 `0.0.0.0` / `127.x` 的其他写法都没有正确归类。当 `trust_pasv_ip=true`（`cmd/example`、`cmd/ftps` 都开着）时，一个被控制的 FTP 服务器可以让数据连接打到本机服务或内网地址。
- 另外 `0.0.0.0`、`169.254.169.254`（云元数据）虽然 `is_private` 认了后者（`169.254` 已覆盖），但 `0.0.0.0` 会被当成公网。

**建议**：用 `@socket.Addr` 解析后按基础类型做判断，别用字符串前缀；把 `::ffff:x.x.x.x` 归一化。

### S2【中】数据通道没有读超时保护
[connection/transport.mbt:459-482](connection/transport.mbt#L459-L482)、[list.mbt:191-204](list.mbt#L191-L204)

`open_data_conn` 只在 `Tcp::connect` 外面套了 `with_timeout`，**连接建立后读/写完全无超时**。`read_payload` 里 `conn.reader().read_all()` 直接读到底。注释里说「数据通道无 deadline 是刻意设计」，但后果是：一个恶意或故障服务器发 `150` 之后不再发数据、也不断开，客户端会永久挂起。Android/桌面应用里这是可被利用的挂起型 DoS。

**建议**：给数据通道读写加一个可配置的空闲超时（类似 `timeout_ms`），至少超时后能抛出可处理的错误。

### S3【低-中】列表内容全量读入内存，无上限
[list.mbt:195](list.mbt#L195)、[`name_list`](list.mbt#L10)

`LIST`/`NLST`/`MLSD` 的应答用 `read_all()` 一次性读进内存再 `text()`。恶意服务器可以返回无限长的列表让客户端 OOM。控制通道有 `max_reply_line_bytes` / `max_reply_lines`，**数据通道却没有对应上限**。

**建议**：复用一个 `max_listing_bytes` 常量并流式解析，或至少限制单次列表大小。

### S4【低】`NoVerification` 对调用方完全开放
[client.mbt:404](client.mbt#L404)、[client.mbt:680](client.mbt#L680)

`TrustedRoot` 是整个传给调用方的，`DialOptions::set_trust(NoVerification)` 可以被调用（测试里就在用）。库本身没法禁止，但建议：
- 文档里在 `set_trust` 上明确标注「关闭校验 = 可被 MITM」；
- 考虑对 `NoVerification` 打一条 stderr 警告（与 `warn_plaintext_login` 同一风格），至少让人在日志里看到它。

### S5【低】明文登录警告只在登录成功后触发
[dial.mbt:354-358](dial.mbt#L354-L358)

`login` 先发 `USER`/`PASS`，再 `feat`，然后才 warn。如果服务器在 `PASS` 之后立刻拒绝（比如 `530`），**密码已经在明文里发出去了但没有任何告警**。而且这个警告依赖 `FEAT` 成功返回，`FEAT` 失败的服务器永远不会触发。

**建议**：在发送 `PASS` 之前，如果当前不是 TLS，就无条件告警（或至少 `PASS` 前检查 `explicit_tls` / `tls` 标志）。

### S6【低】`TrustedRoot::SystemRoot` 在测试中不可用的平台行为
`cmd/ftps` 的 `plain` 路径用 `SystemRoot`（无所谓，明文），但库的默认值也是 `SystemRoot`。如果宿主（如 wasm）没有系统信任库，`Tls::client` 会失败 —— 这是可接受的，但 README 里那句「wasm 档未验证的只有 FTPS」需要与 `moon.mod` 的注释保持一致。

---

## 二、健壮性 / 正确性

### C1【中】`read_response` 的续行循环边界差一，且收尾条件可能僵死
[connection/control.mbt:404-422](connection/control.mbt#L404-L422)

```moonbit
while body.length() <= max_reply_lines { ... }
```
- 结构是「先 `push` 再检查 `> max`」，等价于最多 `max + 1` 行，但错误信息写的是「exceeds max lines」，语义不精确。
- 更关键的是：循环体里如果 `read_line` 返回的正是终止行，会 `push` 后 `break`；如果不是，又会查长度。当 `body.length()` 恰好位于边界时，循环会多读/少读一行。**建议改成 `while body.length() < max_reply_lines`，并在 push 前判断。**

### C2【中】`cmd_format` 的 `{}` 替换不转义、不检查数量
[connection/control.mbt:332-368](connection/control.mbt#L332-L368)

`replace_first` 每次都替换**第一次出现的 `{}`**。如果 `args` 比 `{}` 少，多余的 `{}` 会原样发到服务器；如果 `args` 多，多余的参数会被**静默丢弃**。例如 `cmd_format(ctl, "SIZE {}", [], ...)` 会发 `SIZE {}`（`{}` 本身没有 CRLF，注入检查也拦不住），服务器多半回 `550`。这是内部 API，但 `PRET` 预览依赖同一函数，参数错配会让 `PRET` 预告的命令与实际命令不一致。

**建议**：在 `render_command` 末尾断言 `rendered.find("{}") == None`，否则抛 `ParseError`。

### C3【低】`parse_pasv` 端口可为 0
[connection/transport.mbt:29-68](connection/transport.mbt#L29-L68)

`parse_pasv` 没有拒绝 `(0,0)` 端口（`numbers[4]*256+numbers[5] == 0`）。`EPSV` 路径显式拒绝了端口 0（[transport.mbt:415-418](connection/transport.mbt#L415-L418)），`PASV` 没有。建议两边一致。

### C4【低】`split_addr` 对裸 IPv6 字面量处理不完整
[dial.mbt:172-207](dial.mbt#L172-L207)

不带方括号的 IPv6（`2001:db8::1`）会被 `rev_find(":")` 切开，导致 `host="2001:db8:"`、`port` 走默认。代码注释也承认「未加方括号的 IPv6 保留其地址」，但 `rev_find` 实际会把最后一段当端口。**建议对含多个 `:` 且不以 `[` 开头的输入直接报错，提示用户加方括号。**

### C5【低】`remove_dir_recur` 的递归深度无上限
[commands.mbt:114-132](commands.mbt#L114-L132)

递归遍历远端目录树时没有深度限制。一个构造出的深目录树（服务器可控）可以让客户端栈溢出。`Walker` 不提供递归，但 `remove_dir_recur` 是直接递归。

### C6【低】`walker.mbt` 的 `push` / `pop` 是 O(n²) 拷贝
[walker.mbt:69-94](walker.mbt#L69-L94)

每次 `push`/`pop` 都复制整个数组（`append_entry` / `drop_last`）。大目录树上会退化成 O(n²)。不影响正确性，但可以作为性能改进项。

### C7【低】`get` 的 `defer file.close()` 在错误路径上可能掩盖原始错误
[cmd/ftp/main.mbt:cmd_get](cmd/ftp/main.mbt)

如果 `read_to` 抛错、同时 `file.close()` 也抛错，后面这个错误可能覆盖前者（取决于 MoonBit 的 `defer` 语义）。`DataResponse::close` 已经处理了这类聚合，CLI 层可以同样用 `join_errors`。

---

## 三、文档与工程

| 项 | 说明 |
| --- | --- |
| **D1** `docs/safe.md` 空文件 | 被 `e553eda` 清空，但 `AGENTS.md`、`docs/AGENTS.md` 和提交历史仍引用。要么删文件并去掉引用，要么恢复内容（历史版本在 `c438733` 可查）。 |
| **D2** README 与实现脱节 | README 说的 `moon.mod` 里 `preferred_target = "native"` 与注释一致；但 README 第 230 行提到 `RemoveDirRecur`，而 `pkg.generated.mbti` 是否导出需要核对。另外 CLI 的 `put <local> [remote]` 在 `basename` 失败时会报「refusing to write」，这个错误文本和「上传」场景不匹配。 |
| **D3** `.ide/Dockerfile` 供应链 | [.ide/Dockerfile:19-25](.ide/Dockerfile#L19-L25) 用 `curl \| bash` 安装 MoonBit、Claude Code、cc-switch，且都是 `latest`，无 checksum。`.github/workflows/ci.yml` 同样。CI 机上这是典型的供应链风险。建议至少 pin 版本或校验 SHA256。 |
| **D4** CI 覆盖率下限偏低 | `scripts/ci.sh` 里 `MIN_COVERED_LINES=1600`，当前约 1655，**距离门槛只有 55 行**。一次小幅重构就可能跌破；而且在 `--enable-coverage` 下每行开销让 CI 变慢。建议把门槛提到当前值的 95%，并区分「行数」和「比例」。 |
| **D5** `.gitignore` 的 `bisect.coverage` 与 `__pycache__` | 已覆盖，没问题。 |
| **D6** `preferred_target` 注释 | `moon.mod` 注释说「wasm 档未验证的只有 FTPS」，但 `connection` 包直接 `impl` 了 `@io` 类型，wasm 上是否编译通过需要 CI 验证。建议在 CI 里加一次 `moon check --target wasm-gc`。 |

---

## 四、测试与 CI 覆盖缺口

| 缺口 | 说明 |
| --- | --- |
| **T1** FTPS 冒烟不覆盖续传 | `cmd/ftps` 只做「dial/login/list/retr/stor/delete」，**没有 `retr_from` / `stor_from` 的 TLS 续传**。续传路径里 `stor_from` 的零字节握手有专门 workaround，但 TLS 下的 `REST` + 数据连接重开没有端到端测试。 |
| **T2** 没有「服务器伪造 PASV IP」的端到端测试 | `is_bogus_data_ip` 有单测，但没有一条测试让 mock 服务器在 `trust_pasv_ip=false` 时回一个 `8.8.8.8` 并确认客户端没连过去。原 `safe.md` 里提到过的这个回归场景应该补上。 |
| **T3** 数据通道超时、列表 OOM 场景无测试 | 与 S2/S3 对应，mock 可以模拟「回 150 后静默」和「无限列表」。 |
| **T4** `cmd/profiles` 的 `no-time` 画像 | 需要确认 `remove_dir_recur` 在 `no-time` 服务器上是否真的被覆盖；目前看 profile 覆盖了 `MKD`/`RMD` 但没看到 `MLST` 单文件的边界。 |
| **T5** 覆盖率门槛 | 见 D4。 |
| **T6** `parse_fuzz_test.mbt` 存在 | 好，但只覆盖解析器；协议层（`read_response`、`parse_pasv`、`parse_epsv`）的模糊测试缺失。 |

---

## 五、架构层面（供参考，非缺陷）

- **`FTPClient` 持有的 `Session` 无法真正并发**：`lock()` 会拒绝已关闭客户端，但 `DataResponse::read` **刻意不持锁**，注释里也承认「调用方在 read 期间不能做别的操作」。这是文档约束，但**没有编译器或运行时强制**。一个不小心在 `read` 期间调用 `list` 就会把两个传输的应答混在一起。建议考虑一个「传输中」状态位，在 `lock()` 时拒绝其余公共操作。

- **`quit()` 不关闭 socket**：`commands.mbt:218` 的注释说 `Control` 没有 `close`，所以 `QUIT` 之后 socket 靠 GC 释放。在短生命周期 CLI 里没问题，但长驻进程反复 dial/quit 会泄漏文件描述符。建议给 `Control` 加 `close()` 并在 `quit` 里调用。

- **CLI `--pass` 出现在 argv 里**（[cmd/ftp/main.mbt](cmd/ftp/main.mbt) 的 `--pass`）：`ps` 可见。建议支持从 stdin / 环境变量读取（环境变量已经支持），并在 usage 里提示 `--pass` 不推荐用于脚本。

---
