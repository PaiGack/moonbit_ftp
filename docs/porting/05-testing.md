# 05 测试策略

## 1. 双轨制

上游测试天然分两层，移植时原样保留这个划分：

| 轨道 | 上游来源 | 覆盖对象 | 服务器 | 位置 |
| --- | --- | --- | --- | --- |
| **A. 纯解析** | `parse_test.go` / `scanner_test.go` / `constants_test.go` | `types` / `status` / `scanner` / `parse` | 无 | `*_test.mbt` |
| **B1. Mock 端到端** | `conn_test.go` / `client_test.go` / `walker_test.go` | `control` / `transport` / `client` / `walker` | `@socket.TcpServer` 自建 | `*_test.mbt` |
| **B2. 真机端到端** | 同上，但换真服务器 | 同上 | `pyftpdlib`（CI 起容器） | `ftp_server_test.mbt` |

轨道 A 是资产：**字符串进、结构体出**，逐条直搬，零改动成本。轨道 B 必须用 `@socket.TcpServer` 复刻上游 mock。

B1 与 B2 是互补的，不是替代关系：B1 能**断言完整命令序列**、能构造各种服务器画像，
B2 则验证这些序列在真实实现上确实被接受。B2 第一次跑通就在客户端里挖出 5 个 B1
测不出的 bug，见第 6.4 节。

## 2. 轨道 A：解析用例直搬

### 2.1 上游 `parse_test.go` 用例清单（必须全绿）

固定 `now = 2017-03-10 23:00 UTC`（上游常量），以便「半年规则」的断言可复现。

**UNIX ls -l 风格（3 条）**

| 输入行 | 期望 |
| --- | --- |
| `drwxr-xr-x    3 110      1002            3 Dec 02  2009 pub` | name=`pub`, type=Folder, size=0, time=`2009-12-02` |
| `drwxr-xr-x    3 110      1002            3 Dec 02  2009 p u b` | name=`p u b`（空格保留） |
| `-rw-r--r--   1 marketwired marketwired    12016 Mar 16  2016 ...newsml` | name 完整, type=File, size=12016 |

**UNIX ls 变体 + 符号链接（3 条）**

| 输入行 | 期望 |
| --- | --- |
| `-rwxr-xr-x    3 110      1002            1234567 Dec 02  2009 fileName` | size=1234567 |
| `lrwxrwxrwx   1 root     other          7 Jan 25 00:17 bin -> usr/bin` | name=`bin`, target=`usr/bin`, type=Link, time=当年 01-25 00:17 |

**另一套 ls 风格（3 条）**

| 输入行 | 期望 |
| --- | --- |
| `drwxr-xr-x               folder        0 Aug 15 05:49 !!!-Tipp des Haus!` | type=Folder, name 含 `!` 与空格 |
| `drwxrwxrwx               folder        0 Aug 11 20:32 P0RN` | type=Folder |
| `-rw-r--r--        0   18446744073709551615 18446744073709551615 Nov 16  2006 VIDEO_TS.VOB` | size=UInt64 最大值（**不要溢出**） |

**Windows / WFTPD（3 条）**

| 输入行 | 期望 |
| --- | --- |
| `----------   1 owner    group         1803128 Jul 10 10:18 ls-lR.Z` | type=File |
| `d---------   1 owner    group               0 Nov  9 19:45 Softlib` | time 为**上一年**（半年规则） |
| `-rwxrwxrwx   1 noone    nogroup      322 Aug 19  1996 message.ftp` | time=1996-08-19 |

**RFC3659 风格（6 条）**

| 输入行摘要 | 期望 |
| --- | --- |
| `type=cdir; ... .` | type=Folder, name=`.` |
| `type=pdir; ... ..` | type=Folder, name=`..` |
| `type=dir; ... movies` | type=Folder |
| `type=dir; ... _upload` | type=Folder |
| `size=951;type=file; ... welcome.msg` | type=File, size=951 |
| `Modify=...;Perm=...;Size=951;Type=file; ... welcome.msg` | **键名首字母大写也要认**（大小写不敏感） |

**DOS DIR（4 条）**

| 输入行 | 期望 |
| --- | --- |
| `08-07-15  07:50PM                  718 Post_PRR_....dat` | type=File, size=718 |
| `08-10-15  02:04PM       <DIR>          Billing` | type=Folder, name=`Billing` |
| `08-07-2015  07:50PM                  718 Post_PRR_....dat` | 4 位年份格式 |
| `08-10-2015  02:04PM       <DIR>          Billing` | 4 位年份格式 |

**多空格文件名（3 条）**

| 输入行摘要 | 期望 |
| --- | --- |
| `... Dec 02  2009 spaces   dir   name` | name=`spaces   dir   name`（**内部空格保留**） |
| `... Dec 02  2009 file   name` | name=`file   name` |
| `... Dec 02  2009  foo bar ` | name=` foo bar `（**首尾空格也保留**） |

**hostedftp（1 条）**

| 输入行 | 期望 |
| --- | --- |
| `-r--------   0 user group     65222236 Feb 24 00:39 RegularFile` | link count=0 也能解析 |

**ACL 权限（1 条）**

| 输入行 | 期望 |
| --- | --- |
| `-rwxrw-r--+  1 521      101         2080 May 21 10:53 data.csv` | 第 11 位是 `+`，仍能解析 |

**符号链接拆分（2 条）**

| 输入行 | 期望 |
| --- | --- |
| `lrwxrwxrwx   1 root     other          7 Jan 25 00:17 bin -> usr/bin` | name=`bin`, target=`usr/bin` |
| `lrwxrwxrwx    1 0        1001           27 Jul 07  2017 R-3.4.0.pkg -> el-capitan/...` | name 与 target 正确拆分 |

**失败用例（8 条，必须报对错误类型）**

| 输入行 | 期望错误 |
| --- | --- |
| `d [R----F--] supervisor            512       Jan 16 18:53 login` | `UnsupportedListLine` |
| `- [R----F--] rhesus             214059       Oct 20 15:27 cx.exe` | `UnsupportedListLine` |
| `drwxr-xr-x    3 110      1002            3 Dec 02  209 pub` | `UnsupportedListDate`（年份只有 3 位） |
| `modify=20150806235817;invalid;UNIX.owner=0; movies` | `UnsupportedListLine` |
| `Zrwxrwxrwx   1 root     other          7 Jan 25 00:17 bin -> usr/bin` | **`ParseError`（未知 entry 类型）** |
| `total 1` | `UnsupportedListLine` |
| `000000000x ` | `UnsupportedListLine` |
| `` （空串） | `UnsupportedListLine` |

> 注意 `Zrwxrwxrwx` 那条：**上游对未知 entry 类型返回 `errUnknownListEntryType`，不是在四个解析器之间继续回退**。
> 因为 `parseLsListLine` 一旦识别出 ls 形状（首字段 10 字节），就无法再退回其他解析器。
> 移植时必须保住这个「识别出形状后错误就升级」的语义，否则错误类型会对不上。

### 2.2 半年规则用例（4 条）

固定 `now = 2017-03-10 23:00 UTC`，`thisYear = 2017`，`previousYear = 2016`：

| 输入字段 | 期望时间 | 规则 |
| --- | --- | --- |
| `Feb 10 23:00` | `2017-02-10 23:00` | 今年，过去 |
| `Sep 10 22:59` | `2017-09-10 22:59` | 未来但**不足** 6 个月 → 仍是今年 |
| `Sep 10 23:00` | `2016-09-10 23:00` | 未来**达到/超过** 6 个月 → 年份减 1 |
| `Jan 23  2019` | `2019-01-23` | 有年份，按年份解析（不套规则） |

边界判定精确到分钟：`22:59` 通过、`23:00` 触发减年。实现里必须是「不早于 `now + 6 个月`」→ 减年，不能写成「大于」。

### 2.3 scanner 用例

见 [02-upstream-map.md](./02-upstream-map.md) 第 4 节，**逐条断言中间态**（`next` 与 `remaining` 交替）。

### 2.4 常量用例

```
status_text(0)   == "Unknown status code: 0"
status_text(430) == "Invalid username or password."
to_string(EntryType::File)   == "file"
to_string(EntryType::Folder) == "folder"
to_string(EntryType::Link)   == "link"
```

## 3. 轨道 B：Mock FTP 服务器

### 3.1 为什么必须复刻

上游 `conn_test.go` 的 mock 不是随便写个假服务器，它做了三件事，缺一不可：

1. **记录收到的每条命令**（只记动词），用于断言**完整命令序列**。
2. **支持三种服务器画像**（`no-time` / `std-time` / `vsftpd`），用 FEAT 响应与 `MDTM`/`MFMT` 行为区分。
3. **有独立的数据连接监听器**（每次 PASV/EPSV 现开一个临时端口），用于验证数据通道建立。

其中 1 是最有价值的：它把「协议序列正确」变成可断言的事实，而不是靠连真实服务器碰运气。

### 3.2 MoonBit 实现骨架

已实测可用的形态（`moonbitlang/async` 0.21.3）：

```moonbit
///|
struct FtpMock {
  server : @socket.TcpServer
  commands : Array[String]     // 收到的命令动词序列
  modtime : String             // "no-time" | "std-time" | "vsftpd"
  bogus_pasv_ip : Bool
  ...
}

///|
async fn FtpMock::serve(self : FtpMock) -> Unit raise {
  let (conn, _) = self.server.accept()
  conn.write("220 FTP Server ready.\r\n")
  while true {
    let line = conn.read_until("\r\n").unwrap()
    let verb = line.split(" ").head()
    self.commands.push(verb)
    match verb {
      "FEAT" => // 按画像返回多行 FEAT
      "USER" => conn.write("331 Please send your password\r\n")
      ...
      "QUIT" => { conn.write("221 Goodbye.\r\n"); break }
      _ => conn.write("500 Unknown command.\r\n")
    }
  }
}
```

实测结论：`@socket.TcpServer` + `@async.with_task_group` + `spawn_bg` 的「服务端后台协程 + 客户端主协程」模式工作正常，`read_until("\r\n")` 能正确处理跨包边界的行。

### 3.3 测试辅助函数

对齐上游 `openConn` / `closeConn`：

```moonbit
///| 起 mock + 连接 + 登录
async fn open_conn(profile~ : String) -> (FtpMock, @ftp.FTPClient) raise

///| 退出并断言命令序列
///  期望序列 = ["USER","PASS","FEAT","TYPE", ...中间命令, "QUIT"]
async fn close_conn(mock, client, middle_commands : Array[String]) -> Unit raise
```

`close_conn` 的断言是轨道 B 的核心断言点，**每条端到端测试都要走一遍**。

### 3.4 服务器画像对照

| 画像 | FEAT 返回 | 行为差异 | 用途 |
| --- | --- | --- | --- |
| `no-time` | `FEAT PASV EPSV UTF8 SIZE MLST`（无时间相关） | `MDTM` 返回 `500`，`MFMT` 返回 `500` | 验证「不支持时间操作」的降级 |
| `std-time` | 上面 + `MDTM MFMT` | `MDTM <path>` 读时间；`MFMT <time> <path>` 写时间 | 标准服务器 |
| `vsftpd` | 上面 + `MDTM`（**无 MFMT**） | `MDTM <time> <path>` 用于**写**时间 | 验证 VsFtpd 怪癖分支 |

### 3.5 mock 支持的命令与响应

| 命令 | 响应 | 备注 |
| --- | --- | --- |
| `FEAT` | `211-Features:\r\n ... \r\n211 End` | 多行，按画像拼 |
| `USER anonymous` | `331 ...` | 其它用户名 → `530` |
| `PASS` | `230-Hey,\r\nWelcome to my FTP\r\n230 Access granted` | **多行，验证解析器** |
| `TYPE` | `200 Type set ok` | |
| `CWD missing-dir` | `550 ...` | 失败分支 |
| `CWD` 其它 | `250 ...` | |
| `DELE` / `MKD` / `RMD` | `250` / `257` / `250` | `RMD missing-dir` → `550` |
| `PWD` | `257 "/incoming"` | 验证引号提取 |
| `CDUP` | `250 ...` | |
| `SIZE magic-file` | `213 42` | 其它 → `550` |
| `PASV` | `227 Entering Passive Mode (127,0,0,1,p1,p2)` | `bogus` 时返回 `127,0,0,2` |
| `EPSV` | `229 Entering Extended Passive Mode (\|\|\|PORT\|)` | 可配置为报错以测降级 |
| `LIST` | `150 ...` + 数据 + `226` | 数据含一行非法行（`total 1`）验证跳过 |
| `MLSD` | `150 ...` + `Type=file;Size=0;Modify=20201213202400; lo` + `226` | |
| `MLST multiline-dir` | `250-...\r\n Type=dir;...\r\n Modify=...;\r\n250 End` | 验证多行合并 |
| `NLST` | `150 ...` + `/incoming` + `226` | |
| `RETR` | 从 `rest` 偏移开始发内容 + `226` | 验证断点续传 |
| `STOR` / `APPE` | `150` + 收数据 + `226` | |
| `RNFR` / `RNTO` | `350` / `250` | |
| `REST n` | `350 ...`，记下 n | 非数字 → `500` |
| `MDTM` | 读：`213 20201213202400`；写（vsftpd）：`213 UTIME OK` | |
| `MFMT` | `213 UTIME OK` | 非 `std-time` 画像 → `500` |
| `NOOP` | `200 NOOP ok.` | |
| `OPTS UTF8 ON` | `200 ...` | 参数不对 → `500` |
| `REIN` | `220 Logged out` | |
| `QUIT` | `221 Goodbye.` + 关闭 | |

### 3.6 数据连接模拟

上游的 mock 每次 `PASV`/`EPSV` 都新开一个临时端口监听，等客户端连上来。MoonBit 版同样做法：

```moonbit
///| 开一个临时端口，返回端口号；后台协程等待客户端连接
async fn (self : FtpMock) listen_data_conn() -> Int raise {
  let srv = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  ...
}
```

实测确认 `@socket.TcpServer(...)` + `server.addr` 能在回环拿到随机端口，且 `accept` 可与控制通道协程并行运行。

## 4. 断言风格

按项目 `AGENTS.md` 的约定：

- **稳定结果用 `assert_eq`**：状态码、命令序列、解析出的 name/size/type。
- **结构化调试输出用 `debug_inspect`**：`Entry` 整体比较时，先 `derive(@debug.Debug)`。
- **时间比较用固定 `now` + UTC**：避免依赖测试运行时的真实时间。上游把 `now` 作为显式参数传入正是为此，移植时保留这个签名。

## 5. 覆盖率目标

| 层 | 目标 | 理由 |
| --- | --- | --- |
| `types` / `status` / `error` | ≥ 90% | 简单，容易达 |
| `scanner` / `parse` / `pathutil` | ≥ 95% | 用例密集，且是纯逻辑 |
| `control` | ≥ 85% | 多行响应有边界 |
| `transport` | ≥ 80% | 含降级分支 |
| `client` | ≥ 75% | 大量方法是一行命令封装 |
| `walker` | ≥ 90% | 状态机小 |

`moon coverage analyze` 结果里，**`transport` / `client` 的降级分支必须被覆盖**（EPSV 失败、PASV 可疑 IP、时间不支持）。这些是「真实服务器上才会暴露」的路径，mock 里不测就没人测。

## 6. 真实 FTP 服务器端到端测试（轨道 B 的真机部分）

`ftp_server_test.mbt` 跑在一台**真实 FTP 守护进程**上，不是 mock。这一层
补的正是 mock 补不了的东西：命令序列在真实实现上是否被接受。它第一次跑起来
就在客户端里挖出了 5 个 mock 永远测不出的 bug（见 6.4）。

### 6.1 服务器与 fixture

| 项 | 值 |
| --- | --- |
| 守护进程 | `pyftpdlib` 2.2.0（纯 Python，支持 MLSD / MDTM / MFMT / EPSV） |
| 启动脚本 | `.github/ftp-fixture/serve.py`（GitHub CI 与 CNB 共用同一份） |
| fixture | `.github/ftp-fixture/fixture/`，由 git 固定 |
| 账号 | `test` / `test` |
| 端口 | 控制 2121，被动 30000-30009 |

fixture 目录内容（**内容固定，不用脚本生成**）：

```
fixture/hello.txt        12 字节，内容 "hello world\n"
fixture/sub/nested.txt   嵌套目录，验证 Folder 类型
```

测试在服务端写入的路径是 `/upload`（容器内为可写目录），读取的固定文件在
`/fixture`。

### 6.2 环境变量开关

测试是**按环境变量启用**的，缺省不跑：

| 变量 | 缺省 | 说明 |
| --- | --- | --- |
| `FTP_TEST_HOST` | 未设 | 未设时全部用例直接 return（不算失败） |
| `FTP_TEST_PORT` | `21` | |
| `FTP_TEST_USER` / `FTP_TEST_PASS` | `test` / `test` | |
| `FTP_TEST_FIXTURE` | `/fixture` | 只读 fixture 目录 |
| `FTP_TEST_DIR` | `/upload` | 可写目录，写用例用完自行清理 |

MoonBit 没有 skip API，所以未配置时用例**提前 return**，而不是 fail：
本机 `moon test --target native` 依旧是绿的。一旦 `FTP_TEST_HOST` 被设上，
任何断言失败都是硬失败，没有「服务器抽风」的兜底。

### 6.3 用例清单（13 条）

```
connect, login and PWD                dial → login → PWD == "/"
FEAT negotiation reports MLST/MDTM    真机 FEAT 被接受且能力位正确
MLSD listing of the fixture           MLSD 路径，校验 hello.txt 的 size/type
LIST parsing of the fixture           disable_mlsd 走 LIST，校验 ls -l 解析
SIZE and MDTM of a fixture file       213 回包解析
RETR downloads the mounted fixture    内容逐字节比对
RETR from an offset resumes           REST 偏移生效
NLST returns bare names               裸名字列表
MKD, CWD, rename and RMD round trip   目录生命周期
STOR uploads a file                   上传后 SIZE 一致
APPE appends to an uploaded file      APPE 后内容 == 两段拼接
MFMT and MDTM agree on the time       写时间后读回完全一致
a wrong password is rejected          530 变成 ServerError 而不是挂死
```

### 6.4 真机测试挖出的客户端 bug

这些 bug 在 mock 下**不可能**被发现（mock 是我们自己写的，会「配合」客户端的
错误行为），只有真服务器会照协议回包：

| # | 位置 | 症状 | 修法 |
| --- | --- | --- | --- |
| 1 | `dial.mbt` 问候语 | 用 `cmd_expect(control, "", [220])` 读问候，**多发了一条空命令**，会话错位 | 改成只 `read_response` 不发送 |
| 2 | `transfer.mbt` `check_data_shut` | 同样多发空命令读 `226` | 同上 |
| 3 | `transport_dataconn.mbt` | 用 `is_positive_completion`（2xx）判定传输起始回包，但 `125`/`150` 是 1xx，**每次都误判失败** | 改用 `is_positive_intermediate` |
| 4 | `login.mbt` | 持锁后再调 `feat`/`set_transfer_type`，非重入互斥锁**自锁死** | 锁分段，嵌套调用放在锁外 |
| 5 | `lifecycle.mbt` | `QUIT` 只接受 `200`/`220`，真服务器回 `221` | 补 `status_closing_control_connection` |

第 1/2 条的共同教训：**「读一个应答」和「发一条命令再读应答」是两件事**，
`socket` 上没有「空命令」这回事。

### 6.5 CI 接入

| 环境 | 怎么起服务器 |
| --- | --- |
| GitHub Actions | 步骤内 `pip install pyftpdlib` + `serve.py`，fixture 挂 `${{ github.workspace }}/.github/ftp-fixture` |
| CNB 流水线 | `services: [docker]`（DinD），`serve.py` 只读挂进 `python:3.12-slim` 容器 |
| CNB 云原生开发 | `$: vscode:` 流水线在进入工作区前起同一个容器，IDE 里直接 `moon test` 就是真机用例 |

本地手工跑：

```bash
python3 -m pip install "pyftpdlib==2.2.0"
mkdir -p .ci/ftp-root/upload && cp -r .github/ftp-fixture/fixture .ci/ftp-root/
python3 .github/ftp-fixture/serve.py --root "$PWD/.ci/ftp-root" --port 2121 &

export PATH="$HOME/.moon/bin:$PATH"
FTP_TEST_HOST=127.0.0.1 FTP_TEST_PORT=2121   moon test --target native
```

`.ci/ftp-root/` 是启动时拼出来的目录，已进 `.gitignore`。

### 6.6 未覆盖的部分

- **TLS**：`AUTH TLS` / `PBSZ` / `PROT P` 这条路径还没在真机上跑过。
  pyftpdlib 支持 TLS，但需要一个自签证书 + 客户端信任策略，留到后续工作包。
- **VsFtpd 画像**：`writing_mdtm`（`MDTM <time> <path>` 写时间）只在 mock 里
  验证，没有真 VsFtpd 实例。`fauria/vsftpd` 镜像可用，但缺 MLSD，要另配一份
  fixture。
- **`LIST -a`**：`force_list_hidden=true` 会发 `LIST -a <path>`，pyftpdlib 把
  `-a` 当路径的一部分，回 `550`。所以真机 LIST 用例走的是 `disable_mlsd`
  （纯 `LIST`），`LIST -a` 仍由 mock 覆盖。

## 7. 不该做的事

- **不要为了测试引入 mock 网络库**。`@socket.TcpServer` 已经够用，且能验证真实 TCP 行为（含 `\r\n` 分片）。
- **不要把解析测试改成 Snapshot**。上游用例是精确断言，改成 snapshot 会掩盖字段级回归。
- **不要跳过 `close_conn` 的命令序列断言**。省这一步，等于放弃「协议序列正确」这个最有价值的断言。
- **不要在 CI 里静默跳过真机用例**。设了 `FTP_TEST_HOST` 就必须真的跑起来；
  「服务器没起来所以跳过」等于把第 6.4 节那 5 个 bug 留回去。CNB 的启动步骤
  会轮询端口并在超时时 `exit 1`，就是为了堵这个口子。
- **不要用「客户端的期望」去写真服务器**。第 6.4 节的 5 个 bug 里有 3 个是
  客户端自己**多发/错判**导致的；真机测试的价值就在于它不会配合客户端犯错。
