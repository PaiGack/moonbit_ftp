# moon_ftp 项目申报书

## 基本信息

- 项目名称：moon_ftp —— Go `jlaffaye/ftp` 的 MoonBit 移植
- 参赛者：（待填写）
- 联系方式：（待填写）
- GitHub 仓库链接：https://github.com/nrzhangsan/moonbit_ftp
- 项目方向：MoonBit 网络协议基础库 / FTP 客户端
- 是否为移植项目：是（ISC License）
- 参考项目：<https://github.com/jlaffaye/ftp>

## 项目简介

`moon_ftp` 把 Go 生态里最常用的 FTP 客户端库 `jlaffaye/ftp` 移植到 MoonBit，目标是在
MoonBit 里提供一个能直接连真实 FTP 服务器的客户端库：支持 RFC 959 的控制/数据双通道协议、
EPSV/PASV 被动模式、MLSD/LIST 目录列表、上传下载（含断点续传）、FTPS 加密、目录树遍历。

FTP 看起来"老"，但它是设备固件升级、老旧系统对接、网站整站备份、内网文件交换里最常用的
落地协议，今天仍在大量生产环境跑。Go/Python/Rust 都有成熟的 FTP 客户端，MoonBit 没有——
mooncakes.io 上目前搜不到任何 FTP 实现。这意味着任何用 MoonBit 写工具链、运维脚本、
数据管道的人，需要连 FTP 时只能退回其他语言，或者自己从零踩一遍协议的坑。这个项目要补的就是这个缺口。

选 `jlaffaye/ftp` 而不是自己从零设计，是因为这个库不是简单的 socket 封装：它把 FTP 四十年来
积累的服务器差异都处理掉了——`LIST` 的四种输出格式（UNIX ls、DOS DIR、RFC3659、hostedftp）、
`FEAT` 特性协商、VsFtpd 用 `MDTM` 写时间的怪癖、ProFTPD/PureFTPD 的 TLS 数据连接握手问题、
PASV 返回内网 IP 的 SSRF 防护、EPSV 失败自动回退 PASV。这些细节是"能不能连通真实服务器"的分水岭，
单靠读 RFC 是写不出来的，直接移植比重新发明一个能用的轮子更划算。

## 三个预期使用场景

1. **整站备份 / 迁移工具**：用 `walk` 递归遍历远端目录树，按 `Entry` 的路径、大小、时间做
   增量同步，跳过未变更文件；大目录用并发传输加速。
2. **数据管道落盘**：定时从厂商 FTP 拉取 CSV/日志（`retr_from` 断点续传，防止大文件中断后重传），
   处理后写入下游；服务器只支持 `LIST` 老格式时依然能解析出文件名和时间。
3. **CI / 部署脚本**：构建产物通过 `stor` 上传到运维 FTP，`mft`/`mdtm` 校准文件时间戳，
   保证发布时间一致；FTPS 显式加密满足内网合规要求。

## 拟实现的核心功能

- 连接与登录：`dial`（超时/自定义 dialer/上下文）、`login`（含 `FEAT` 探测、UTF8 协商）、`quit`
- 被动模式：`EPSV` 优先 + `PASV` 回退，PASV 可疑 IP 防护
- 目录列表：`list`（MLSD 优先，回退 LIST）、`name_list`（NLST）、`get_entry`（MLST）
- 四种列表行解析：RFC3659 / UNIX ls / DOS DIR / hostedftp，含符号链接、ACL 权限、多空格文件名
- 文件传输：`retr` / `retr_from` / `stor` / `stor_from` / `append`，含 `REST` 断点续传
- 文件操作：`rename` / `delete` / `remove_dir_recur` / `make_dir` / `remove_dir` / `file_size`
- 时间操作：`get_time` / `set_time`（`MFMT`，兼容 VsFtpd 的 `MDTM` 写法）
- 安全：`AUTH TLS` 显式加密、隐式 TLS、命令注入防护
- 目录树遍历：`walk` / `next` / `skip_dir` / `stat` / `path`
- 调试：控制通道与数据通道的原始流量日志

## 明确不做

- 主动模式（`PORT`/`EPRT`）——上游同样只做被动模式
- SFTP/SSH、HTTP 代理、`MODE`/`STRU`/`ALLO` 等冷门命令
- WASM/JS 后端（需要有真实网络栈），首版只支持 native
- 并发分片下载（只做"多文件并发 + 单文件断点续传"）

## 实现路径与技术理解

**技术选型**：底层用官方 `moonbitlang/async`，它已经提供 `socket.Tcp`、`socket.Addr` 和
`tls.Tls`，覆盖了 TCP 连接、TLS 握手、超时与取消。不选 C FFI 阻塞式 socket，是因为那会把
平台相关的线程/超时问题引进来，而 async 栈是官方维护、跨平台、且自带 TLS 的。

**分层设计**：把**纯协议解析**和**网络 IO**彻底分开。
`types` / `status` / `scanner` / `parse` 四个包零 IO 依赖，可以拿上游的测试用例直接跑，
不用 mock 网络；`control` 负责命令编码、多行响应、状态码校验；`transport` 收敛
EPSV/PASV/PRET/REST/TLS 的数据通道建立逻辑；`client` 才是对外 API；`walker` 建在 client 上。
这样即使以后 `moonbitlang/async` 出破坏性改动，也只需改 `transport` 一层。

**关键实现点**（都是上游代码里"踩过坑"的地方，移植时必须保住）：

1. 数据通道关闭后必须回控制通道读 `226/250`，否则后续命令会错位——这是最常见的实现 bug。
2. EPSV 失败一次要记状态，后续直接走 PASV，避免每次白等一次超时。
3. TLS 数据连接不能直接 dial+TLS（ProFTPD/PureFTPD 会挂），要延迟到首次读写再握手；
   上传零字节文件时要显式触发握手。
4. 命令参数要检查 `\r`/`\n`，防止改名/上传路径被注入第二条 FTP 命令。
5. `LIST` 的时间字段没有年份时要用"半年规则"：超过 6 个月视为去年。
6. Go 的 `errors.Join` 语义要保留：传输错误、关闭错误、状态读取错误要一起报出来，
   而不是遇到第一个就吞掉。

**测试理解**：上游测试其实分两层——纯解析测试（`parse_test.go`，用例极全）和 mock 服务器
端到端测试（`conn_test.go`，自建 TCP mock，能模拟 no-time/std-time/vsftpd 三种服务器画像，
并断言完整命令序列）。移植时我会把这两类都复刻：解析用例直接搬，mock 服务器用
`TcpServer` 重写，这样"协议序列正确"这件事是可验证的，而不是靠连真实服务器碰运气。

**预期交付物**

- 可 `moon add PaiGack/ftp` 使用的 MoonBit 库
- 一个 CLI 示例（`moon run cmd/ftp`，支持 `ls` / `get` / `put` / `walk`）
- mock FTP 服务器测试 + 解析测试，覆盖全部核心路径
- README、移植说明、上游许可证与来源标注
- 发布到 mooncakes.io
