# 03 工作包拆解与实施顺序

这是本方案的核心文档。总体方案里的 P0–P7 是**阶段名**，本文把它们细化成 W0–W8 九个**工作包**，
每个工作包对应一个可独立提交、可独立验收的 PR。

## 0. 总览

| 工作包 | 名称 | 产出 | 依赖 | 估时 | 对应阶段 |
| --- | --- | --- | --- | --- | --- |
| W0 | 工程骨架 | native target、依赖、包骨架、CI 修正 | — | 0.5 人日 | P0 |
| W1 | 纯逻辑层 | `types` / `status` / `error` / `scanner` / `parse` / `pathutil` | W0 | 3 人日 | P1 |
| W2 | 控制协议层 | `control`：命令编码、多行响应、状态校验 | W1 | 2 人日 | P2 |
| W3 | 数据通道层 | `transport`：EPSV / PASV / PRET / REST / TLS 建连 | W2 | 2.5 人日 | P3 |
| W4 | 客户端骨架 | `client`：dial / login / feat / 目录导航 / 生命周期 | W3 | 2 人日 | P4 |
| W5 | 文件传输 | `client`：list / retr / stor / append / 列表解析接入 | W4 | 2 人日 | P4 |
| W6 | 遍历与兼容 | `walker` + 服务器画像差异 + 兼容性清单全过 | W5 | 2 人日 | P5/P6 |
| W7 | CLI 示例 | `cmd/ftp`：ls / get / put / walk / mkdir / rm | W6 | 1 人日 | P7 |
| W8 | 文档与发布 | README、移植说明、LICENSE-THIRD-PARTY、mooncakes 发布 | W7 | 1.5 人日 | P7 |

合计 **16.5 人日**（含缓冲后 12~17 人日区间）。

关键路径：`W0 → W1 → W2 → W3 → W4 → W5 → W6 → W7 → W8`，全串行，因为每层都依赖下一层的接口稳定。

W1 之后有并行机会：W7 的 CLI 骨架可以在 W4 完成后先起一个能跑 `ls` 的版本，边开发边用真实服务器冒烟。

---

## W0 工程骨架（0.5 人日）

**目标**：仓库从「只有文档」变成「能编译、能跑测试、CI 全绿的 MoonBit native 项目」。

### 任务

- [ ] `moon.mod` 确认 `preferred_target = "native"`（已改过，复核一次）
- [ ] `moon add moonbitlang/async`，锁定版本 `0.21.3`（当前最新）
- [ ] 按 [01-architecture.md](./01-architecture.md) 第 2 节建包骨架：各包**直接平铺在仓库根目录**（无 `src/` 中间层），每个包放一个 `moon.pkg` 和一个占位 `.mbt`
- [ ] 删除模板文件 `ftp.mbt` / `ftp_test.mbt` / `ftp_wbtest.mbt`（内容为 3 行注释）+ 根目录空 `moon.pkg`
- [ ] `cmd/main` 改名为 `cmd/ftp`，`main.mbt` 换成参数解析骨架（打印 usage 即可）
- [ ] 每个纯逻辑包加一条架构守卫测试：断言包内不引用 `moonbitlang/async`
- [ ] **修正 CI**：
  - `.github/workflows/ci.yml` 删掉 `moon build --target wasm-gc`（native-only 会挂）
  - `.cnb.yml` 增加 `gcc` / `libc6-dev`（native 后端需要 C 编译器；当前 `.ide/Dockerfile` 只装了 `gcc libssl-dev`，缺 `libc6-dev` 会编译失败）
  - 测试步骤加 `--target native`
- [ ] `.ide/Dockerfile` 补 `libc6-dev`（否则容器内 `moon test --target native` 直接报 `stdint.h: No such file`）

### 验收

```bash
export PATH="$HOME/.moon/bin:$PATH"
moon check --target native --deny-warn   # 0 warning 0 error
moon test  --target native               # 通过
moon fmt --check                         # 干净
moon info && git diff --exit-code        # 干净
```

CI 两条流水线（GitHub Actions / CNB）都绿。

### 风险

`.ide/Dockerfile` 改动会触发镜像重建（`.cnb.yml` 里 `versionBy` 绑定该文件），首次 CI 会慢。属预期。

---

## W1 纯逻辑层（3 人日）

**目标**：把上游 `parse.go` / `scanner.go` / `status.go` 的功能完整搬过来，测试用例全绿。
**这一层不 import `moonbitlang/async`**，全部可在内存里验证。

### W1.1 `types`（0.3 人日）

- [ ] `EntryType` 三值枚举 + `to_string()` 返回 `"file"` / `"folder"` / `"link"`
- [ ] `TransferType` 枚举，值对应 FTP 命令参数 `"I"` / `"A"`
- [ ] `Entry` 结构体（字段见 01-architecture.md 第 4 节）
- [ ] 常量 `default_dial_timeout_ms = 30000`

验收：`entry_type_to_string` 三个值各一条测试。

### W1.2 `status`（0.3 人日）

- [ ] 47 个状态码常量（含 `1xx` 中间态、`2xx` 成功、`3xx` 需补全、`4xx` 暂不可用、`5xx` 永久失败）
- [ ] `status_text(code : Int) -> String`：
  - 命中表 → 返回原文
  - 未命中 → `"Unknown status code: {code}"`
- [ ] 便捷判断：`is_positive_completion(code)`（2xx）、`is_positive_intermediate(code)`（1xx）

验收（对齐上游 `constants_test.go`）：

```
status_text(0)   == "Unknown status code: 0"
status_text(430) == "Invalid username or password."
```

### W1.3 `error`（0.3 人日）

- [ ] `FtpError` suberror（5 个变体，见 01-architecture.md 第 5 节）
- [ ] `FtpErrors::MultipleErrors` 聚合类型 + 构造 helper
- [ ] 与 `@async` 错误的桥接：IO 错误原样冒泡，不包成 `FtpError`

验收：每个变体能构造、能 `Debug`、能模式匹配取出字段。

### W1.4 `scanner`（0.5 人日）

- [ ] `Scanner` 结构体（内部按字节位置推进，**不是**按字符）
- [ ] `next()` / `next_fields(n)` / `remaining()`
- [ ] 严格复刻「消费字段后紧跟的一个空格」行为

验收（对齐上游 `scanner_test.go`，**逐条断言中间态**）：

```
"foo  bar x  y" → next="foo",  remaining=" bar x  y"
                → next="bar",  remaining="x  y"
                → next="x",    remaining=" y"
                → next="y"
                → next=""
                → remaining=""
""              → next=""  next=""  remaining=""
```

这是**最容易写错**的一个包：只要 `remaining()` 的语义理解错一位，`parse` 里所有依赖 `remaining()` 取文件名的解析器全错。

### W1.5 `parse`（1.4 人日）

- [ ] `rfc3659.mbt`：`parse_rfc3659_line` + `parse_next_rfc3659_line`（多行合并）
- [ ] `unix_ls.mbt`：`parse_ls_line`（含 ACL `+`、folder/0 特例、符号链接 ` -> ` 切分）
- [ ] `dos_dir.mbt`：`parse_dos_dir_line`（4 种时间格式逐个试）
- [ ] `hostedftp.mbt`：`parse_hostedftp_line`（link count 0 → 换算 1 后复用 ls）
- [ ] `time.mbt`：`set_time`（**半年规则**，见 [02-upstream-map.md](./02-upstream-map.md) 第 3 节）
- [ ] `parse.mbt`：`parse_list_line` 顶层入口，按固定顺序回退，全部失败报 `UnsupportedListLine`
- [ ] `set_size`：支持 `0x` / `0o` 前缀（对齐 Go `ParseUint(str, 0, 64)`）

验收（对齐上游 `parse_test.go`，**30+ 条用例全绿**）：

- 15 条正常行（UNIX ls 3 种变体、DOS DIR 2 种、RFC3659 6 条、hostedftp 1 条、ACL 1 条、多空格文件名 3 条）
- 2 条符号链接（含 name / target 拆分）
- 8 条失败行（`unsupported` / `unsupported date` / `unknown entry type` 三类错误要分得清）
- 4 条 `set_time` 半年规则边界（过去 / 6 个月内未来 / 超过 6 个月 / 远未来）

### W1.6 `pathutil`（0.2 人日）

- [ ] `join(base : String, name : String) -> String`，对齐 Go `path.Join` 语义（清理多余 `/`、处理 `.` 和 `..`）

验收：`join("root/", "lo")` == `"root/lo"`；`join("root", "a")` == `"root/a"`。

### 风险

- MoonBit 的时间库（`moonbitlang/x/time`）格式化能力若不足，`set_time` 需要自实现定长日期解析。**这是 W1 最大的不确定性**，建议 W1.5 一开始就先用最小样例探通时间 API。

---

## W2 控制协议层（2 人日）

**目标**：能对着一个真实 TCP 连接收发 FTP 命令，正确解析单行/多行响应，校验状态码。

### 任务

- [ ] `control.mbt`：带行缓冲的读取器
  - 从 `@io.Reader` 按行读（`\r\n` 分隔），支持跨包边界的行拼接
- [ ] `response.mbt`：FTP 响应解析
  - 单行：`220 Server ready`
  - 多行：`211-Features:` 开头，中间行以空格开头，结束行为 `211 End`（**结束行以 `211 ` 开头且不含 `-`**）
  - 返回 `{code : Int, message : String}`，与 Go `textproto.ReadResponse` 逐字节一致：**保留**首尾状态行的正文（`211-Features:\n FEAT\n PASV\nEnd`）。这一点被下游依赖——`FEAT` 靠前导空格过滤掉首尾行，`MLST` 靠 `lines[1:lc-1]` 取事实行；正文若丢掉边界行，`GetEntry` 会直接报 `invalid response`。另外三字节无分隔符的行（`200`）按 Go 判为 `short response` 错误
- [ ] `command.mbt`：
  - `send(client, cmd : String) -> Unit`（追加 `\r\n` 写出）
  - `cmd(client, expected~ : Int, format~ : String, args~ : Array[String]) -> (Int, String)`
    - `expected == -1` 表示接受任意码
    - 不匹配则返回 `FtpError::ServerError`
  - `check_for_command_injection(arg)`：含 `\r` 或 `\n` → `FtpError::InvalidCommand`
- [ ] `debug.mbt`：可选流量日志装饰（对齐上游 `debug.go`）

### 验收

用 `@socket.TcpServer` 起一个假服务器，脚本化返回：

- 单行 `220`
- 多行 `211-Features:\r\n FEAT\r\n PASV\r\n211 End`，断言解析出 3 行正文且 code == 211
- 状态码不匹配时抛 `ServerError` 且携带原始 message
- 命令含 `\n` 时抛 `InvalidCommand` 且**不写任何字节到 socket**

### 关键点

多行响应的结束判定是上游 `textproto` 的隐含契约：`211-` 开始、`211 ` 结束。
写错会导致 FEAT 解析把后续命令的响应也吃进去。必须单测覆盖。

---

## W3 数据通道层（2.5 人日）

**目标**：能把被动模式数据连接建起来，含 EPSV→PASV 降级、PASV 防 SSRF、REST 偏移、TLS 延迟握手。

### 任务

- [ ] `transport_epsv.mbt`
  - [ ] `epsv(client) -> Int`：发 `EPSV`，期望 `229`
  - [ ] `parse_epsv(line) -> Int`：找 `|||` 与最后一个 `|`，位置非法报 `ParseError`
- [ ] `transport_pasv.mbt`
  - [ ] `pasv(client) -> (String, Int)`：发 `PASV`，期望 `227`
  - [ ] 解析 `(h1,h2,h3,h4,p1,p2)`，端口 = `p1*256 + p2`，6 段不足报错
  - [ ] **防 SSRF**：默认用控制连接的 IP；只有显式 `trust_pasv_ip=true` 且数据 IP 不是「可疑 IP」时才用服务器给的 IP
  - [ ] `is_bogus_data_ip(cmd_ip, data_ip)`：`data_ip` 是组播，或两者私网性不同，或两者回环性不同 → 可疑
- [ ] `transport_dataconn.mbt`
  - [ ] `get_data_port(client) -> (String, Int)`：EPSV 优先；**失败一次后置 `skip_epsv = true`**，后续直接 PASV
  - [ ] `open_data_conn(client) -> @io.Reader + @io.Writer`：
    - 无 TLS → 直接连
    - 有 TLS → **先连，再包 `Tls::client`，不在此时握手**（延迟到首次读写）
  - [ ] `cmd_data_conn_from(client, offset~, cmd~, args~) -> DataConn`：
    1. `use_pret` 为真 → 先发 `PRET <cmd>`
    2. `open_data_conn`
    3. `offset != 0` → 发 `REST <offset>`，期望 `350`；失败则关数据连接并抛
    4. 发传输命令，期望 `125` 或 `150`
    5. 非 `2xx` → 关数据连接并抛 `ServerError`
- [ ] `transport_dataconn.mbt`：`use_pret` 状态维护

### 验收

复用 W2 的 fake 服务器，扩展支持 `EPSV` / `PASV`：

- EPSV 正常 → 建连成功，命令序列含 `EPSV`
- EPSV 返回 `500` → **降级 PASV**，且第二次调用**不再发 EPSV**（断言 commands 里 `EPSV` 只出现一次）
- PASV 返回 `227 ... (127,0,0,2,p1,p2)` 而控制连接是 `127.0.0.1` → **默认仍连控制 IP**；`trust_pasv_ip=true` 时才连 `127.0.0.2`
- `REST 42` → 后续数据从偏移 42 开始
- TLS 模式下建连不挂起（无握手阻塞），首次读触发握手

### 关键点

「EPSV 失败后不再重试」和「TLS 延迟握手」是上游两个刻意的设计，**不是疏忽**。丢掉任何一个都会在特定服务器上表现为超时或挂死。

---

## W4 客户端骨架（2 人日）

**目标**：能 `dial → login → pwd / cwd / mkdir / quit`，能力协商（FEAT）正确落地。

### 任务

- [ ] `options.mbt`：`DialOptions` 结构体 + 16 个构造（见 [04-api-mapping.md](./04-api-mapping.md)）
- [ ] `client.mbt`：`FTPClient` 结构体
  - 字段：`options` / `control` / `net_conn` / `host` / `features : Map` / `skip_epsv` / `mlst_supported` / `mfmt_supported` / `mdtm_supported` / `mdtm_can_write` / `use_pret` / `mutex`
- [ ] `dial.mbt`：`dial(addr, options)` 流程
  1. 应用 options，`location` 默认 UTC
  2. 建连（超时默认 30s），**取 socket 的对端 IP 作为 `host`**（不用域名，避免解析到不同 IP）
  3. 读首行响应，期望 `220`
  4. `explicit_tls` → 发 `AUTH TLS`，期望 `234`，然后把连接升级为 TLS，重建控制通道
- [ ] `login.mbt`
  - [ ] `login(user, password)`：`USER` → `331` → `PASS` → `230`
  - [ ] `feat()`：`FEAT`，非 `211` 视为「不支持特性」（**不算错误**）；解析 `xxx-` 多行，格式 ` COMMAND DESC`
  - [ ] 按 FEAT 结果设置：`mlst_supported`（有 `MLST` 且未禁用 MLSD）、`use_pret`（有 `PRET`）、`mfmt_supported`、`mdtm_supported`、`mdtm_can_write`
  - [ ] 切二进制：`TYPE I`，期望 `200`
  - [ ] `set_utf8()`：**仅当 FEAT 里有 `UTF8` 才发**；`501` / `504` / `202` 视为可接受
  - [ ] 隐式 TLS → 发 `PBSZ 0` 和 `PROT P`，期望均 `200`
- [ ] `nav.mbt`：`change_dir` / `change_dir_to_parent` / `current_dir`（`PWD` 取引号内内容）
- [ ] `fsops.mbt`：`make_dir` / `remove_dir` / `delete` / `rename`（`RNFR` → `350` → `RNTO` → `250`）
- [ ] `lifecycle.mbt`：`no_op` / `logout`（`REIN`，期望 `220`）/ `quit`（发 `QUIT` + 关连接，**聚合错误**）
- [ ] 加 `mutex` 保护：每个公开方法进入时获取

### 验收（对齐上游 `conn_test.go` 的 `closeConn`）

上游靠 mock 记录命令序列，本方案改为**真机 + 副作用断言**（见
[05-testing.md](./05-testing.md) 3.2）。落地后的断言是：

- 登录后会话可用：`PWD` 返回 `"/"`（证明没有多发空命令导致错位）
- `FEAT` 的能力位与真机一致：有 `EPSV` / `MDTM` / `SIZE` / `REST`，无 `MLST` / `MFMT`
- `AUTH TLS` 模式的手工断言仍未做（见 05-testing.md 6.1）
- `current_dir` 从 `257 "/home/vsftpd"` 之类的回包解析出引号里的路径

---

## W5 文件传输（2 人日）

**目标**：`list` / `retr` / `stor` / `append` 全部可用，含 226 收尾与错误聚合。

### 任务

- [ ] `response.mbt`：`Response` 结构体
  - [ ] 实现 `@io.Reader`
  - [ ] `close()`：**幂等**（二次调用返回 Unit，不报错）；内部等价 `errors.Join`：关数据连接错误 + 226 收尾错误
- [ ] `transfer.mbt`
  - [ ] `check_data_shut()`：读控制通道期望 `226`；若配置了 `shut_timeout`，先**推一下控制连接 deadline**再读
  - [ ] `retr(path)` / `retr_from(path, offset)` → `Response`
  - [ ] `stor(path, reader)` / `stor_from(path, reader, offset)`
    - 写入后若**写入 0 字节且无错误**，且连接是 TLS → **显式触发握手**（否则 ProFTPD 上传空文件报 `Unable to build data connection`）
    - 关闭数据连接
    - `check_data_shut`
    - 聚合三个阶段的错误
  - [ ] `append(path, reader)` 同 `stor`，命令为 `APPE`
- [ ] `list.mbt`
  - [ ] `name_list(path)`：`NLST`，按行收集，关连接收尾
  - [ ] `list(path)`：
    - `mlst_supported && !force_list_hidden` → `MLSD`，用 RFC3659 解析器
    - 否则 → `LIST`（`force_list_hidden` 时加 `-a`），用四解析器回退
    - **解析失败的行直接跳过**（不中断列表），与上游一致
    - 聚合 scanner 错误 + close 错误
  - [ ] `get_entry(path)`：`MLST`，期望 `250`，只取中间行（1 到 n-1），多行合并；不足 3 行报错
  - [ ] `type_(transfer_type)`：`TYPE I` / `TYPE A`
- [ ] `client_time.mbt`
  - [ ] `file_size(path)`：`SIZE`，期望 `213`，解析整数
  - [ ] `get_time(path)`：`MDTM`，期望 `213`，按 `yyyyMMddHHmmss` 解析（UTC）；不支持时报错
  - [ ] `set_time(path, t)`：优先 `MFMT`，退化 `MDTM <time> <path>`（VsFtpd 怪癖），都不支持则报错
  - [ ] `is_get_time_supported()` / `is_set_time_supported()` / `is_time_precise_in_list()`
- [ ] `fsops.mbt` 补 `remove_dir_recur(path)`：`CWD` → `PWD` → `LIST` → 递归；跳过 `.` 和 `..`

### 验收

- `list(".")` 对 `full` 画像 → 走 `LIST`（vsftpd 无 MLSD），解析出 fixture 目录
- `list(".")` 对 `no-mlst` 画像 + `disable_mlsd=true` → 同样走 `LIST`
- `list(".")` 对 LIST 输出里的垃圾行 → 只返回能解析的行，不报错
- `retr("magic-file")` → 能读出内容并在 `close()` 时收尾
- `response.close()` 调两次 → 第二次不报错
- `stor` 零字节 + TLS → 未覆盖（见 05-testing.md 6.1）
- `retr_from(path, 4)` → 读到的内容是对应偏移之后的字节
- `set_time` 对 `no-time` 画像 → 硬失败；对 `full` 画像 → vsftpd 无 `MFMT`，走「不支持」分支

---

## W6 遍历与兼容（2 人日）

**目标**：`walker` 可用；9 个兼容性要点全部有测试覆盖。

### 任务

- [ ] `walker.mbt`
  - [ ] `Walker` 结构（`cur` / `stack` / `descend` / `root`）
  - [ ] `next() -> Bool`：完全复刻 [02-upstream-map.md](./02-upstream-map.md) 第 5 节的 5 步
  - [ ] `skip_dir()` / `err()` / `stat()` / `path()`
  - [ ] `client.walk(root)`：补尾部 `/`，`descend = true`
- [ ] `fsops.mbt` 补 `remove_dir_recur`（真机覆盖）
- [ ] **兼容性专项**（逐条对照 [06-compat-checklist.md](./06-compat-checklist.md)）：

| 画像 | 特征 | 必须验证 |
| --- | --- | --- |
| `no-time` | FEAT 无 `MDTM`/`MFMT` | `get_time` / `set_time` 报「不支持」；`LIST` 走四解析器 |
| `std-time` | FEAT 有 `MDTM` + `MFMT` | `set_time` 走 `MFMT` |
| `vsftpd` | FEAT 只有 `MDTM`；`MDTM t path` 写时间 | `set_time` 走 `MDTM <time> <path>` |
| `bogus-pasv-ip` | PASV 返回 `127.0.0.2` | 默认不信任；`trust_pasv_ip` 时才跟随 |
| `no-epsv` | EPSV 报错 | 降级 PASV 且 `EPSV` 只发一次 |
| `multiline-mlst` | MLST 多行同名 | `get_entry` 合并成功 |

### 验收

- `walker` 对齐上游 `walker_test.go` 的语义用例（字段读取、`skip_dir` 后不再展开、空栈返回 false、`cur` 初始化后第一条是 `root/lo`）
- 上表 6 个画像各至少 1 条测试

---

## W7 CLI 示例（1 人日）

**目标**：`moon run cmd/ftp -- <子命令>` 能对真实 FTP 服务器工作。

### 任务

- [ ] `cmd/ftp/main.mbt`：子命令解析（手写，不引入依赖）
- [ ] 子命令
  - [ ] `ls <path>`：列表，输出 `类型 大小 时间 名称`
  - [ ] `get <remote> [local]`：下载，支持断点续传（本地已存在则用 `retr_from`）
  - [ ] `put <local> [remote]`：上传
  - [ ] `walk <root>`：递归遍历，打印路径与大小
  - [ ] `mkdir` / `rmdir` / `rm`：目录与文件操作
- [ ] 全局参数：`--host` / `--port` / `--user` / `--pass` / `--timeout` / `--tls` / `--trust-pasv-ip`
- [ ] 未给 `--port` 时按 `--tls` 决定默认端口（21 / 990）
- [ ] 错误输出到 stderr，退出码非 0
- [ ] README 里给出可复现的示例（含用 `scripts/start-ftp.sh` 起本地真实服务器的命令）

### 验收

```bash
# 起本地真实 FTP 服务器（需要 Docker）
scripts/start-ftp.sh

# 示例可跑通
moon run cmd/ftp -- --host 127.0.0.1 --port 2121 --user anonymous --pass "" ls /
moon run cmd/ftp -- --host 127.0.0.1 --port 2121 --user anonymous --pass "" put ./README.mbt.md /README.md
moon run cmd/ftp -- --host 127.0.0.1 --port 2121 --user anonymous --pass "" walk /
```

README 中的每一条命令都要能照着跑通。

---

## W8 文档与发布（1.5 人日）

### 任务

- [ ] `README.mbt.md` 补全：项目目标、安装（`moon add PaiGack/ftp`）、快速开始（可复现的 API 示例）、CLI 用法、致谢与来源
- [ ] 新增 `LICENSE-THIRD-PARTY`，保留上游 ISC 原文 + 版权署名 + 来源链接 + 参考范围说明
- [ ] `docs/` 补齐：把本目录文档集接进 `docs/proposal.md` 末尾的「移植方案文档集」索引
- [ ] 写「与 Go 版行为对照表」：逐条列出有意差异（超时 API 形状、`Mutex`、`Response` 边界）
- [ ] `moon.mod` 的 `description` / `keywords` / `repository` 最终复核
- [ ] 跑一次完整验收（见 [08-acceptance.md](./08-acceptance.md)）
- [ ] 发布 mooncakes.io：`moon publish`（需先在 mooncakes 注册并配置 token）
- [ ] 打 tag 并发布 Release

### 验收

- `moon add PaiGack/ftp` 在干净项目里可用
- mooncakes.io 上能搜到并打开项目页
- README 每条命令可复现

---

## 提交节奏建议

每个工作包按「小步提交」推进，避免最后一次性大提交。建议粒度：

```
W0: chore: 初始化 native 包骨架与 CI 修正
W1: feat: 新增 types/status/error/scanner 纯逻辑层
    feat: 新增 LIST 四种格式解析器
    test: 搬运上游 parse/scanner/constants 用例
W2: feat: 新增控制通道命令编码与多行响应解析
W3: feat: 新增 EPSV/PASV 数据通道建立与降级
W4: feat: 新增 dial/login/FEAT 能力协商
W5: feat: 新增 list/retr/stor 文件传输
W6: feat: 新增目录树遍历与服务器兼容画像测试
W7: feat: 新增 CLI 示例
W8: docs: 补齐 README 与许可证说明
```

每个提交都要能通过 `moon check --deny-warn` 和 `moon test --target native`。
