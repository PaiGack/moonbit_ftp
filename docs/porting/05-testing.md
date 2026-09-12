# 05 测试策略

## 1. 单轨制：只有真实服务器

这个仓库里**没有任何 mock**。所有端到端断言都打在一个真实的 FTP 守护进程上。

| 轨道 | 上游来源 | 覆盖对象 | 服务器 | 位置 |
| --- | --- | --- | --- | --- |
| **A. 纯逻辑** | `parse_test.go` / `scanner_test.go` / `constants_test.go` | `entry` / `status` / `parse` / `parse_time` / `scanner` / `pathutil` | 无 | `*_test.mbt` |
| **B. 真机端到端** | `conn_test.go` / `client_test.go` / `walker_test.go` | `control` / `transport` / `client` / `walker` | `jmoyer/vsftpd`（vsftpd 3.0.5），CI 起容器 | `cmd/example/` |
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
| 命令注入「一个字节都不发」 | 真服务器无法自证收到了什么 | `cmd/example` 断言副作用（见 3.2）|
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
`cmd/example` 第一次跑起来就在客户端里挖出 5 个 mock 永远测不出的 bug（见 6.4）。

### 3.2 命令序列断言 → 副作用断言

新方案里没有 mock 来记录「服务器收到了什么」。原来那种

```
close_conn(mock, client, ["USER", "PASS", "FEAT", "TYPE", "OPTS", "QUIT"])
```

式的**精确序列断言被删掉了**，换成**副作用可观察**：每步操作（`PWD` / `LIST` / `RETR` /
`STOR` / `MKD` / `RMD` / `QUIT`）的 stdout 都要拿到结构化结果，断言失败就是真实服务器拒绝，
不是脚本配合。

代价是丢掉了「精确序列」这个断言，收益是**这个断言不再能被我们自己伪造**。

### 3.3 真机演示程序：`cmd/example`

`cmd/example` 是一个跑在真实 vsftpd 上的端到端演示程序，由 `scripts/start-ftp.sh` 起容器后
调用。CI（GitHub Actions 的 `ftp-demo` job 与 CNB 的 `ftp-demo` stage）都会跑它。
本机也可以手工 `scripts/start-ftp.sh && moon run cmd/example && scripts/stop-ftp.sh` 一键复现。

调用顺序与覆盖的客户端分支：

| 步骤 | 客户端 API | 覆盖的客户端分支 |
| --- | --- | --- |
| `dial` → `login` | `@ftp.dial` + `@ftp.login` | 问候语解析、`USER`/`PASS` 序列、FEAT 协商 |
| `current_dir` | `current_dir` | PWD 命令编码与响应解析 |
| `list` fixture | `list` | 真机 ls -l 输出 → `Entry` 解析（File / Folder）|
| `retr` hello.txt | `retr` | 数据通道建立、ASCII 文本读取、字节比对 |
| `stor` 一个文件，再 `file_size` 比对 | `stor` | 上传 + SIZE 回包校验 |
| `rename` + `delete` | `rename` / `delete` | RNFR/RNTO + DELE |
| `make_dir` + `remove_dir` | `make_dir` / `remove_dir` | MKD/RMD 目录生命周期 |
| `walk` fixture | `walk` | walker 状态机 + 嵌套目录递归 |
| `quit` | `quit` | 221 状态码接受（bug #5）|

任何一步 raise 都意味着客户端断了，由 `run_async_main` 捕获并 exit 1。**没有兜底**——
服务器没起来 / 命令被拒 / 字节比对失败都是硬失败，绝不静默跳过。

### 3.4 服务器画像：当前不做，留给后续

历史方案里有「四画像」（full / no-mlst / no-time / no-epsv）来覆盖客户端的降级分支，
每画像一个容器。当前为了简化 `scripts/start-ftp.sh`（用户明确要求：「不是只要一句
`docker run` 加 `--network host` 就行了吗？」），**只跑 `full` 一台**。
`no-mlst` / `no-time` / `no-epsv` 三个降级分支当前由 `cmd/example` 的 happy path 间接
旁路（即：客户端确实用了 MLSD / MDTM / EPSV，因为 vsftpd 都支持它们），
但**真实拒绝 → 降级**的端到端路径**目前没有 CI 覆盖**。这个回归风险已被记下（见 6.1）。

## 4. 真实服务器与 fixture

### 4.1 服务器与 fixture

| 项 | 值 |
| --- | --- |
| 镜像 | `jmoyer/vsftpd`，即 **vsftpd 3.0.5**（Debian Trixie 基础镜像）|
| 启动脚本 | `scripts/start-ftp.sh`（CNB、GitHub Actions、云原生开发环境共用同一份）|
| fixture | `testdata/ftp/fixture/`，由 git 固定 |
| 账号 | 虚拟用户，默认 `test` / `test`（`FTP_USER` / `FTP_PASS` 可覆盖）|
| 端口 | 控制端口 `21`（`--network host` 下端口 21 在容器内 == 主机端口 21），PASV 范围由镜像 entrypoint 决定 |

fixture 目录内容（**内容固定，不用脚本生成**）：

```
fixture/hello.txt        12 字节，内容 "hello world\n"
fixture/sub/nested.txt   嵌套目录，验证 Folder 类型
```

客户端在 chroot 内看到的根是 `/`；fixture 整体挂在 `/home/vsftpd/test`，因此
fixture 内 `hello.txt` 在客户端看是 `/hello.txt`，`sub/nested.txt` 看是 `/sub/nested.txt`。

容器挂载（`scripts/start-ftp.sh`）：

| 容器内路径 | 宿主机路径 | 说明 |
| --- | --- | --- |
| `/home/vsftpd/test` | `testdata/ftp/fixture/` | 服务树，也是 `local_root` |

注意挂载的是 `local_root`（`/home/vsftpd/$FTP_USER`），不是 `/srv` —— 这是
`jmoyer/vsftpd` 与旧镜像最大的差异。`testdata/ftp/fixture/` 直接来自 git，
**不复制到 `.tmp/`**，启动零 IO 成本。

镜像 entrypoint（`/usr/sbin/run-vsftpd.sh`）会**强制**追加 `pasv_address` 等被动参数，
其中 `PASV_ADDRESS` / `PASV_MIN_PORT` / `PASV_MAX_PORT` 三个环境变量必须非空：
空的 `pasv_min_port=` 会让 vsftpd 直接 exit 2 且没有任何输出。因此 `scripts/start-ftp.sh`
总是显式传这三个变量。

### 4.2 单容器、`--network host`

历史方案里有「四画像」（full / no-mlst / no-time / no-epsv）来覆盖客户端的降级分支，
每画像一个容器。当前简化为：

- **一个容器**，不挂额外配置文件
- **`--network host`**，让 vsftpd 自己挑 PASV 端口，**不再显式映射 PASV 端口范围**
- 控制端口绑定 `127.0.0.1:2121`（fixture 内的 chroot 用 `--network host` + 容器内 listen 21
  实现；对外通过 vsftpd 默认行为即可）

降级分支（MLSD → LIST、EPSV → PASV、MDTM 写失败）当前由 6.1 跟踪，待后续工作包回到
「多画像容器」方案时再补。

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
`500 Unknown command.`。vsftpd 3.0.5 的 `FEAT` 与 3.0.3 完全一致，换镜像不改变这组断言。

实测得到的 vsftpd 行为细节：

- **`REST STREAM` 会被解析成 `REST`**：`parse_features` 只取行的第一个 token（与上游一致），
  所以断言要用 `has_feature("REST")`。

### 4.4 环境变量开关

`cmd/example` 是**按环境变量启用**的，缺省值就让它跑通本机自检：

| 变量 | 缺省 | 说明 |
| --- | --- | --- |
| `FTP_TEST_HOST` | `127.0.0.1` | 控制通道主机 |
| `FTP_TEST_PORT` | `21` | 控制通道端口 |
| `FTP_TEST_USER` / `FTP_TEST_PASS` | `test` / `test` | 虚拟用户凭据 |
| `FTP_TEST_FIXTURE` | `/` | 只读 fixture 目录根（fixture 挂在 chroot 根）|

CI 与本地手工演示使用同一份脚本与同一组环境变量，没有「CI 专用」开关。

### 4.5 用例清单

`cmd/example/main.mbt`（演示程序，非测试）：

```
connect, login and PWD                              dial → login → PWD == "/"
LIST parsing of the fixture directory               真机 ls -l 输出，校验 hello.txt 的 size/type
RETR downloads the mounted fixture                  内容逐字节比对
STOR uploads a file and SIZE matches                上传后 file_size 一致
rename moves a file                                 RNFR/RNTO
delete removes the uploaded file                    DELE
MKD, RMD round trip                                 目录生命周期
walk visits all fixture entries                     walker 状态机 + 嵌套递归
QUIT is accepted                                    真服务器回 221，quit 不抛异常
```

任何一步 raise 都意味着客户端断了，exit 1。**没有兜底**——服务器没起来 / 命令被拒 /
字节比对失败都是硬失败，绝不静默跳过。

`control_test.mbt`（15 条，无 socket）：单行/多行响应、续行判定、短响应、空消息、
非数字首行、空行续行、两行 MLST、`FEAT` 解析（含 `REST STREAM` → `REST`）、
`check_for_command_injection`。

`transport_test.mbt`（15 条，无 socket）：畸形 `PASV` / `EPSV` 回包（缺括号、缺字段、
非数字、超范围）、`is_bogus_data_ip` 的 SSRF 判定、以及 `is_private` / `is_loopback` /
`is_multicast` 的 IPv4 与 IPv6 前缀规则。这些分支真守护进程不会触发，所以和畸形帧一样，
用**直接调用**而不是假服务器来覆盖。

### 4.6 真机演示挖出的客户端 bug

这些 bug 在 mock 下**不可能**被发现（mock 是我们自己写的，会「配合」客户端的
错误行为），只有真服务器会照协议回包：

| # | 位置 | 症状 | 修法 |
| --- | --- | --- | --- |
| 1 | `dial.mbt` 问候语 | 用 `cmd_expect(control, "", [220])` 读问候，**多发了一条空命令**，会话错位 | 改成只 `read_response` 不发送 |
| 2 | `transfer.mbt` `check_data_shut` | 同样多发空命令读 `226` | 同上 |
| 3 | `transport.mbt` | 用 `is_positive_completion`（2xx）判定传输起始回包，但 `125`/`150` 是 1xx，**每次都误判失败** | 改用 `is_positive_intermediate` |
| 4 | `dial.mbt` | 持锁后再调 `feat`/`set_transfer_type`，非重入互斥锁**自锁死** | 锁分段，嵌套调用放在锁外 |
| 5 | `commands.mbt` | `QUIT` 只接受 `200`/`220`，真服务器回 `221` | 补 `status_closing_control_connection` |

第 1/2 条的共同教训：**「读一个应答」和「发一条命令再读应答」是两件事**，
`socket` 上没有「空命令」这回事。

### 4.7 CI 接入

所有平台调的都是 `scripts/` 下的**同一份**脚本，不存在 per-CI 的副本：

| 环境 | 怎么起服务器 | 跑什么 |
| --- | --- | --- |
| GitHub Actions | `scripts/start-ftp.sh`（`ftp-demo` job，`needs: moonbit`）| `moon run cmd/example --target native` + `moon run cmd/ftp -- ls /` 冒烟；结束 `scripts/stop-ftp.sh` |
| CNB 流水线 | `services: [docker]`（DinD），同一份 `scripts/start-ftp.sh` / `stop-ftp.sh` | `ftp-demo` stage 跑 `moon run cmd/example --target native` |
| CNB 云原生开发 | `$: vscode:` 流水线不自动起容器（IDE 内手动）| 本机起容器后 `moon run cmd/example --target native` 即可 |

`scripts/` 的约定：跨 CI 复用、与平台无关的 shell 脚本放这里，流水线只负责「调用」，
不复制命令。

本地手工跑（需要 Docker）：

```bash
export PATH="$HOME/.moon/bin:$PATH"
scripts/start-ftp.sh

export FTP_TEST_HOST=127.0.0.1 FTP_TEST_PORT=21 \
       FTP_TEST_USER=test FTP_TEST_PASS=test
moon run cmd/example --target native

scripts/stop-ftp.sh
```

`scripts/start-ftp.sh` 直接复用镜像自带的 entrypoint（`/usr/sbin/run-vsftpd.sh`）：
它用 `db_load` 建虚拟用户库、把 `PASV_ADDRESS` 追加成 `pasv_address`，再执行
`vsftpd /etc/vsftpd/vsftpd.conf`。所以单容器、零配置覆盖就是这么省出来的——
不挂任何 `vsftpd.conf` overlay，直接吃镜像默认配置。

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
（EPSV 失败、时间不支持、MLSD 回退）。当前 `cmd/example` 只覆盖 `full` 画像，所以
这些降级分支的**真机覆盖暂时缺失**，需要在后续工作包回到「多画像容器」方案时再补。
`parse_features` / `is_bogus_data_ip` 等纯逻辑分支仍有单测覆盖。

### 6.1 未覆盖的部分

- **TLS**：`AUTH TLS` / `PBSZ` / `PROT P` 这条路径还没在真机上跑过。
  `jmoyer/vsftpd` 的 vsftpd 3.0.5 链的是 OpenSSL 3（`libssl.so.3`）且编译进了 `ssl_enable` /
  `rsa_cert_file` 等指令，但镜像**默认没有开**（`ssl_enable` 未设置，配置里也没有证书），
  `FEAT` 里没有 `AUTH TLS`，`AUTH TLS` 回 `530`。要覆盖必须另开一个挂自签证书、
  `ssl_enable=YES` 的画像；留到后续工作包。
- **降级分支的真机覆盖**：MLSD → LIST 回退、EPSV → PASV 永久降级、MDTM 写失败——这三条
  客户端降级路径当前**只有纯逻辑单测**，没有真机覆盖。后续回到「多画像容器」方案时再补
  `no-mlst` / `no-epsv` / `no-time` 三台容器。
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
- **不要在 CI 里静默跳过真机演示**。`scripts/start-ftp.sh` 轮询端口并在超时时
  `exit 1`，就是为了堵「服务器没起 → 跳过 demo」的口子。Demo 失败就是硬失败。
- **不要用「客户端的期望」去写真服务器**。第 6.4 节的 5 个 bug 里有 3 个是
  客户端自己**多发/错判**导致的；真机测试的价值就在于它不会配合客户端犯错。
