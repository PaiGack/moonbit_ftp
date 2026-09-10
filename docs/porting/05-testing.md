# 05 测试策略

## 1. 单轨制：只有真实服务器

这个仓库里**没有任何 mock**。所有端到端断言都打在一个真实的 FTP 守护进程上。

| 轨道 | 上游来源 | 覆盖对象 | 服务器 | 位置 |
| --- | --- | --- | --- | --- |
| **A. 纯逻辑** | `parse_test.go` / `scanner_test.go` / `constants_test.go` | `entry` / `status` / `parse` / `parse_time` / `scanner` / `pathutil` | 无 | `*_test.mbt` |
| **B. 真机端到端** | `conn_test.go` / `client_test.go` / `walker_test.go` | `control` / `transport` / `client` / `walker` | `jmoyer/vsftpd`（vsftpd 3.0.5），CI 起容器 | `ftp_server_test.mbt` |
| **C. 帧与回包解析** | 同上，但需要构造畸形输入 | `read_response` / `parse_features` / `parse_pasv` / `parse_epsv` | 直接调用（无 socket） | `control_test.mbt` / `transport_test.mbt` |

轨道 A 与 C 是纯的：**字符串进、结构体出**，或者**字节进、结构体出**，都不需要服务器。
轨道 B 是真服务器，也正是它的价值所在。

### 1.1 为什么没有 mock

上游 `conn_test.go` 的 mock 做三件事，我们都不要了：

1. 记录收到的命令以断言**完整命令序列** —— 换成断言**副作用**（见 3.2）；
2. 用脚本返回三种**服务器画像** —— 换成 vsftpd 的**真实配置开关**（见 4）；
3. 自建数据连接监听器 —— 真服务器本来就有。

mock 的根本问题不是麻烦，而是**它会配合客户端的错误**：它是照着我们以为的协议写的，
所以客户端多发一条空命令、把 `150` 判成失败，mock 都会「认可」。第 6.4 节那 5 个 bug
全是这么漏掉的。删掉 mock 之后，这类错误在下一次 CI 就会被真守护进程打回。

### 1.2 删掉了哪些用例

旧 `control_test.mbt` 里有一批用例**只能是 mock 用例**，因为真守护进程不会发出那种字节：

| 已删除的用例 | 为什么真机做不到 | 现在由谁覆盖 |
| --- | --- | --- |
| `200` 单独一行（无分隔符）| vsftpd 不会发畸形状态行 | `control_test.mbt` 内存 Reader |
| `211-\r\n\r\n211 End` 空行 | 同上 | 同上 |
| `211 End` 不当作续行 | 同上 | 同上 |
| MLST 两行被拒 | vsftpd 不支持 MLST | `control_test.mbt` 内存 Reader |
| 命令注入「一个字节都不发」 | 真服务器无法自证收到了什么 | `ftp_server_test.mbt` 断言副作用（见 3.2）|
| `FEAT` 不支持时的降级 | vsftpd 一定支持 FEAT | 未覆盖（已在 6.6 记录）|
| `PASV` 返可疑 IP | 需要能伪造 `pasv_address` 的服务器 | 未覆盖（纯逻辑分支仍有单测）|

「只能是 mock」并不等于「不重要」：前三行与 MLST 两行现在用**内存 Reader** 精确构造，
所以帧解析这条分支仍然被覆盖，只是不再需要一台假服务器。

## 2. 轨道 A：纯解析用例直搬

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

## 3. 轨道 B：真实服务器端到端

### 3.1 为什么必须用真服务器

真服务器补的正是 mock 补不了的：**命令序列在真实实现上是否被接受**。
`ftp_server_test.mbt` 第一次跑起来就在客户端里挖出 5 个 mock 永远测不出的 bug（见 6.4）。

### 3.2 命令序列断言 → 副作用断言

新方案里没有 mock 来记录「服务器收到了什么」。原来那种

```
close_conn(mock, client, ["USER", "PASS", "FEAT", "TYPE", "OPTS", "QUIT"])
```

式的**精确序列断言被删掉了**，换成**副作用可观察**：

| 想证明的事 | 现在的断言方式 |
| --- | --- |
| 没有多发空命令导致会话错位（bug #1/#2）| 连接建立后 `PWD` 必须返回 `/`；传输结束后同一连接仍能响应命令 |
| 注入的命令没有上线 | 抛 `InvalidCommand` 之后，`SIZE` 仍然返回 12、`PWD` 仍然正常 |
| `EPSV` 失败后不重试 | `no-epsv` 画像连做两次 `RETR`，第二次也必须成功 |
| `QUIT` 被正确接受 | 真服务器回 `221`，`quit` 不抛异常 |

代价是丢掉了「精确序列」这个断言，收益是**这个断言不再能被我们自己伪造**。

### 3.3 服务器画像：用真配置，不用脚本

画像不再是 mock 的 `no-time` / `std-time` / `vsftpd` 三段脚本，而是 vsftpd 的**真实配置开关**，
每个画像一个容器（见 4）。客户端因此面对的是「真的被拒绝」，而不是「被脚本拒绝」。

## 4. 真实服务器与 fixture

### 4.1 服务器与 fixture

| 项 | 值 |
| --- | --- |
| 镜像 | `jmoyer/vsftpd`，即 **vsftpd 3.0.5**（Debian Trixie 基础镜像）|
| 启动脚本 | `scripts/start-ftp.sh`（CNB、GitHub Actions、云原生开发环境共用同一份）|
| 配置模板 | `testdata/ftp/vsftpd-base.conf` + `testdata/ftp/vsftpd-<profile>.conf` |
| fixture | `testdata/ftp/fixture/`，由 git 固定 |
| 账号 | 虚拟用户，默认 `test` / `test`（`FTP_USER` / `FTP_PASS` 可覆盖）|
| 端口 | 见 4.2 |

fixture 目录内容（**内容固定，不用脚本生成**）：

```
fixture/hello.txt        12 字节，内容 "hello world\n"
fixture/sub/nested.txt   嵌套目录，验证 Folder 类型
```

客户端在 chroot 内看到的根是 `/`；fixture 挂在 `/fixture`，可写目录是 `/upload`。
写用例用完自行清理。

容器挂载（`scripts/start-ftp.sh`）：

| 容器内路径 | 宿主机路径 | 说明 |
| --- | --- | --- |
| `/home/vsftpd/$FTP_USER` | `.tmp/ftp-root/` | 服务树，含 `fixture/` 与 `upload/`；也是 `local_root` |
| `/etc/vsftpd` | `.tmp/ftp-conf/<profile>/vsftpd/` | 该画像的 `vsftpd.conf`（镜像 entrypoint 会读这个路径）|
| `/home/vsftpd` | `.tmp/ftp-conf/home/` | 镜像 entrypoint 创建用户目录的位置（`$USER` 子目录）|

注意服务树挂的是 `local_root`（`/home/vsftpd/$FTP_USER`），不是 `/srv` —— 这是
`jmoyer/vsftpd` 与旧镜像最大的差异。配置刻意放在 `.tmp/ftp-conf/`（**不在**服务树里），
否则会被 FTP 用户从 chroot 里看到。

镜像 entrypoint（`/usr/sbin/run-vsftpd.sh`）会**强制**追加
`pasv_address` / `pasv_min_port` / `pasv_max_port` 等被动参数，其中三个 `PASV_*`
环境变量必须非空：空的 `pasv_min_port=` 会让 vsftpd 直接 exit 2 且没有任何输出。
因此 `scripts/start-ftp.sh` 总是显式传 `PASV_ADDRESS` / `PASV_MIN_PORT` /
`PASV_MAX_PORT`，而 base 配置里**不能**再写这几个指令（重复指令同样会让 vsftpd 拒绝启动）。

### 4.2 四个画像

每个画像一个容器，因为 vsftpd 只在启动时读一次配置，一个进程没法同时扮演两种能力。

| 画像 | 控制端口 | 被动端口 | 配置开关 | 覆盖的客户端分支 |
| --- | --- | --- | --- | --- |
| `full` | 2121 | 30000-30009 | 无 | 基准路径 |
| `no-mlst` | 2122 | 30010-30019 | `cmds_denied=MLST,MLSD` | `disable_mlsd` / `LIST` 回退 |
| `no-time` | 2123 | 30020-30029 | `cmds_denied=MDTM,MFMT` | 「不支持时间操作」的降级 |
| `no-epsv` | 2124 | 30030-30039 | `cmds_denied=EPSV` | EPSV 失败后永久回退 PASV |

### 4.3 vsftpd 的真实能力（实测）

在真机上抓到的 `FEAT` 回应：

```
211-Features:
 EPRT
 EPSV
 MDTM
 PASV
 REST STREAM
 SIZE
 TVFS
211 End
```

**`MLST` / `MLSD` / `MFMT` / `UTF8` 都不在上面**，且 `MLSD` / `MLST` / `MFMT` 会被回
`500 Unknown command.`。所以客户端断言的是「识别到不支持并正确降级」，而不是「RFC 3659 可用」——
后者在真机上永远做不到。vsftpd 3.0.5 的 `FEAT` 与 3.0.3 完全一致，换镜像不改变这组断言。

两个实测得到、值得记下来的 vsftpd 行为：

- **`REST STREAM` 会被解析成 `REST`**：`parse_features` 只取行的第一个 token（与上游一致），
  所以断言要用 `has_feature("REST")`。
- **`cmds_denied=MDTM` 不会从 `FEAT` 里摘掉 `MDTM`**：服务器仍然宣称支持，直到真的发命令才回
  `550`。客户端因此 `is_get_time_supported()` 仍为 true，失败只在调用时暴露——这正是
  `ftp_server_test.mbt` 里那条用例要钉住的。
- **`cmds_denied` 回的是 `550 Permission denied.`**，不是未编译进命令时的
  `500 Unknown command.`。两者都是服务器错误（`FtpError::ServerError`），客户端降级路径一致；
  `no-mlst` 画像因此钉的是「被拒绝后回退 `LIST`」，而不是「命令不存在」。

### 4.4 环境变量开关

测试是**按环境变量启用**的，缺省不跑：

| 变量 | 缺省 | 说明 |
| --- | --- | --- |
| `FTP_TEST_HOST` | 未设 | 未设时全部用例直接 return（不算失败）|
| `FTP_TEST_PORT` | `21` | `full` 画像的控制端口 |
| `FTP_TEST_USER` / `FTP_TEST_PASS` | `test` / `test` | |
| `FTP_TEST_FIXTURE` | `/fixture` | 只读 fixture 目录 |
| `FTP_TEST_DIR` | `/upload` | 可写目录，写用例用完自行清理 |
| `FTP_TEST_PORT_NO_MLST` | `0` | 为 0 时该画像的用例 return |
| `FTP_TEST_PORT_NO_TIME` | `0` | 同上 |
| `FTP_TEST_PORT_NO_EPSV` | `0` | 同上 |

MoonBit 没有 skip API，所以未配置时用例**提前 return**，而不是 fail：
本机 `moon test --target native` 依旧是绿的。一旦 `FTP_TEST_HOST` 被设上，
任何断言失败都是硬失败，没有「服务器抽风」的兜底。

### 4.5 用例清单

`ftp_server_test.mbt`（17 条）：

```
connect, login and PWD                              dial → login → PWD == "/"
FEAT reports the real vsftpd capability set         真机能力位：有 EPSV/MDTM/SIZE/REST，无 MLST/MFMT
LIST parsing of the fixture directory               真机 ls -l 输出，校验 hello.txt 的 size/type
disable_mlsd falls back to LIST                     no-mlst 画像，强制 LIST
SIZE and MDTM of a fixture file                     213 回包解析
RETR downloads the mounted fixture                  内容逐字节比对
RETR from an offset resumes                         REST 偏移生效
NLST returns path prefixed names                    真 vsftpd 给的是带路径前缀的名字
MKD, CWD, rename and RMD round trip                 目录生命周期
STOR uploads a file                                 上传后 SIZE 一致
APPE appends to an uploaded file                    APPE 后内容 == 两段拼接
a wrong password is rejected                        530 变成 ServerError 而不是挂死
an injected command is refused, session survives   副作用断言：注入被拒且会话仍可用
no-time profile fails the time commands cleanly     读/写时间都硬失败，会话仍可用
no-epsv profile falls back to PASV and keeps it     连续两次 RETR 都走 PASV
rename moves a file                                 RNFR/RNTO
nested MKD and RMD round trip                       嵌套目录创建与自底向上删除
```

`control_test.mbt`（15 条，无 socket）：单行/多行响应、续行判定、短响应、空消息、
非数字首行、空行续行、两行 MLST、`FEAT` 解析（含 `REST STREAM` → `REST`）、
`check_for_command_injection`。

`transport_test.mbt`（15 条，无 socket）：畸形 `PASV` / `EPSV` 回包（缺括号、缺字段、
非数字、超范围）、`is_bogus_data_ip` 的 SSRF 判定、以及 `is_private` / `is_loopback` /
`is_multicast` 的 IPv4 与 IPv6 前缀规则。这些分支真守护进程不会触发，所以和畸形帧一样，
用**直接调用**而不是假服务器来覆盖。

### 4.6 真机测试挖出的客户端 bug

这些 bug 在 mock 下**不可能**被发现（mock 是我们自己写的，会「配合」客户端的
错误行为），只有真服务器会照协议回包：

| # | 位置 | 症状 | 修法 |
| --- | --- | --- | --- |
| 1 | `dial.mbt` 问候语 | 用 `cmd_expect(control, "", [220])` 读问候，**多发了一条空命令**，会话错位 | 改成只 `read_response` 不发送 |
| 2 | `transfer.mbt` `check_data_shut` | 同样多发空命令读 `226` | 同上 |
| 3 | `transport.mbt` | 用 `is_positive_completion`（2xx）判定传输起始回包，但 `125`/`150` 是 1xx，**每次都误判失败** | 改用 `is_positive_intermediate` |
| 4 | `login.mbt` | 持锁后再调 `feat`/`set_transfer_type`，非重入互斥锁**自锁死** | 锁分段，嵌套调用放在锁外 |
| 5 | `lifecycle.mbt` | `QUIT` 只接受 `200`/`220`，真服务器回 `221` | 补 `status_closing_control_connection` |

第 1/2 条的共同教训：**「读一个应答」和「发一条命令再读应答」是两件事**，
`socket` 上没有「空命令」这回事。

### 4.7 CI 接入

所有平台调的都是 `scripts/` 下的**同一份**脚本，不存在 per-CI 的副本：

| 环境 | 怎么起服务器 |
| --- | --- |
| GitHub Actions | `scripts/start-ftp.sh`，拉 `jmoyer/vsftpd` 并起四个画像容器；结束 `scripts/stop-ftp.sh` |
| CNB 流水线 | `services: [docker]`（DinD），同一份 `scripts/start-ftp.sh` / `stop-ftp.sh` |
| CNB 云原生开发 | `$: vscode:` 流水线在进入工作区前起同四个容器，IDE 里直接 `moon test` 就是真机用例 |

`scripts/` 的约定：跨 CI 复用、与平台无关的 shell 脚本放这里，流水线只负责「调用」，
不复制命令。`FTP_IMAGE` / `FTP_IMAGE_TAG` 由 CI 的环境变量传入，本地缺省即
`jmoyer/vsftpd:latest`。

本地手工跑（需要 Docker）：

```bash
export PATH="$HOME/.moon/bin:$PATH"
scripts/start-ftp.sh

export FTP_TEST_HOST=127.0.0.1 FTP_TEST_PORT=2121 \
       FTP_TEST_USER=test FTP_TEST_PASS=test \
       FTP_TEST_FIXTURE=/fixture FTP_TEST_DIR=/upload \
       FTP_TEST_PORT_NO_MLST=2122 FTP_TEST_PORT_NO_TIME=2123 FTP_TEST_PORT_NO_EPSV=2124
moon test --target native
```

`.tmp/ftp-root/`（fixture 副本）与 `.tmp/ftp-conf/`（每个画像的配置与用户目录）都是启动时
拼出来的，已进 `.gitignore`。

`scripts/start-ftp.sh` 直接复用镜像自带的 entrypoint（`/usr/sbin/run-vsftpd.sh`）：
它用 `db_load` 建虚拟用户库、把 `PASV_ADDRESS` 追加成 `pasv_address`，再执行
`vsftpd /etc/vsftpd/vsftpd.conf`。所以画像是靠**替换那一个配置文件**做的，
不用自定义 entrypoint。

## 5. 断言风格

按项目 `AGENTS.md` 的约定：

- **稳定结果用 `assert_eq`**：状态码、解析出的 name/size/type。
- **结构化调试输出用 `debug_inspect`**：`Entry` 整体比较时，先 `derive(@debug.Debug)`。
- **时间比较用固定 `now` + UTC**：避免依赖测试运行时的真实时间。上游把 `now` 作为显式参数传入正是为此，移植时保留这个签名。

## 6. 覆盖率目标

| 层 | 目标 | 理由 |
| --- | --- | --- |
| `entry` / `status` / `error` | ≥ 90% | 简单，容易达 |
| `parse` / `parse_time` / `scanner` / `pathutil` | ≥ 95% | 用例密集，且是纯逻辑 |
| `control` | ≥ 85% | 多行响应有边界 |
| `transport` | ≥ 80% | 含降级分支 |
| `client` | ≥ 75% | 大量方法是一行命令封装 |
| `walker` | ≥ 90% | 状态机小 |

`moon coverage analyze` 结果里，**`transport` / `client` 的降级分支必须被覆盖**
（EPSV 失败、时间不支持、MLSD 回退）。这些分支现在由 `no-epsv` / `no-time` / `no-mlst`
三个真实画像覆盖，不再靠 mock。

### 6.1 未覆盖的部分

- **TLS**：`AUTH TLS` / `PBSZ` / `PROT P` 这条路径还没在真机上跑过。
  `jmoyer/vsftpd` 的 vsftpd 3.0.5 链的是 OpenSSL 3（`libssl.so.3`）且编译进了 `ssl_enable` /
  `rsa_cert_file` 等指令，但镜像**默认没有开**（`ssl_enable` 未设置，配置里也没有证书），
  `FEAT` 里没有 `AUTH TLS`，`AUTH TLS` 回 `530`。要覆盖必须另开一个挂自签证书、
  `ssl_enable=YES` 的画像；留到后续工作包。
- **`FEAT` 不被支持**：vsftpd 一定回 `211`，所以「FEAT 失败 → 无能力」的降级没有真机覆盖。
  纯逻辑分支（`parse_features`）仍有单测。
- **`PASV` 返回可疑 IP**：需要一台能伪造 `pasv_address` 的服务器。`is_bogus_data_ip` 的
  纯逻辑分支有单测（`is_private` / `is_loopback` / `is_multicast`），但「真服务器 + 可疑 IP +
  客户端拒绝」这条端到端路径未覆盖。
- **VsFtpd `writing_mdtm` 画像**：`MDTM <time> <path>` 写时间的分支需要 `mdtm_write=YES` 的
  vsftpd；`jmoyer/vsftpd` 的默认配置没有开，暂未覆盖。
- **`LIST -a`**：`force_list_hidden=true` 会发 `LIST -a <path>`。这个 flag 在 vsftpd 上的行为
  没有单独画像覆盖。

## 7. 不该做的事

- **不要重新引入 mock 网络库**。要构造畸形字节，用 `@io.MemoryReader` 直接喂 `read_response`
  （`control_test.mbt` 就是这么做的）；那不需要一台假服务器，也不需要 socket。
- **不要把解析测试改成 Snapshot**。上游用例是精确断言，改成 snapshot 会掩盖字段级回归。
- **不要为了「方便」把用例写回相对路径或跳过**。真机用例断了就是客户端断了，
  第 6.4 节那 5 个 bug 就是这么回来的。
- **不要在 CI 里静默跳过真机用例**。设了 `FTP_TEST_HOST` 就必须真的跑起来；
  「服务器没起来所以跳过」等于把第 6.4 节那 5 个 bug 留回去。`scripts/start-ftp.sh`
  会轮询每个画像的端口并在超时时 `exit 1`，就是为了堵这个口子。
- **不要用「客户端的期望」去写真服务器**。第 6.4 节的 5 个 bug 里有 3 个是
  客户端自己**多发/错判**导致的；真机测试的价值就在于它不会配合客户端犯错。
