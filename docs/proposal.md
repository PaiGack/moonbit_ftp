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

---

## 附：飞书口径申报书框架稿（八章结构与待确认项）

> ⚠️ **状态说明 / 待补充**
> 任务要求同时参考飞书文档 <https://bxup9uklfcb.feishu.cn/wiki/Dx4Bwd6D1i3GfHkajQCcF7SznEd> 整理申报书内容。
> 该文档为**外部租户 wiki，静态访问需登录鉴权**（接口返回 `{"code":5,"msg":"Login Required"}`，页面渲染为登录门户页）。
> 机器人当前无该飞书文档的访问凭证，因此**本文件是按任务上下文先行起草的框架稿**，
> 标注 `【待确认】` 的条目需在获得文档内容（或文档原文截图/导出）后回填与校准。
> 若需要，可提供飞书文档的导出 PDF/Markdown，或授予访问权限，我会按原文重写本申报书。

### 一、项目基本信息

| 项目 | 内容 |
| --- | --- |
| 项目名称 | MoonBit FTP 客户端（moonbit_ftp） |
| 模块名 | `PaiGack/ftp` |
| 仓库 | `nrzhangsan/moonbit_ftp` |
| 参考实现 | [github.com/jlaffaye/ftp](https://github.com/jlaffaye/ftp)（Go，RFC 959 客户端） |
| 许可证 | Apache-2.0 |
| 目标平台 | wasm / wasm-gc / native |
| 当前版本 | 0.1.0（初始化模板阶段） |

### 二、项目背景与意义

【待确认】建议按以下逻辑填写，与飞书文档口径对齐：

1. **生态空白**：MoonBit 生态中尚无成熟的 FTP 客户端库；Go 的 `jlaffaye/ftp` 是使用最广的 FTP 客户端实现之一，移植可为 MoonBit 补齐基础网络协议库拼图。
2. **协议价值**：FTP（RFC 959）虽古老，但在嵌入式设备、内网文件交换、构建产物分发等场景仍广泛使用，是「网络协议库」序列中复杂度适中的标杆项目。
3. **工程验证**：移植过程能系统性验证 MoonBit 在 **TCP 网络、流式 IO、错误建模、时间处理** 上的表达能力，反向驱动标准库/生态完善。

### 三、建设目标

#### 3.1 总体目标

用 MoonBit 实现一个与 `jlaffaye/ftp` **协议行为等价**的 FTP 客户端库，覆盖控制连接、被动数据传输、目录解析与遍历，并提供可运行的示例程序。

#### 3.2 分期目标

- **P0**：协议纯逻辑层（状态码、Entry 模型、LIST/MLSD 解析、目录遍历器），不依赖网络，测试全覆盖。
- **P1**：控制连接层（`textproto` 行协议、TCP 传输抽象），可完成 `dial → login → pwd → feat`。
- **P2**：数据传输层（`list / retr / stor / append / walk` 等），提供 CLI 示例。
- **P3**：增强（可选）：FTPS、并发安全装饰器、断点续传便利 API、与 Go 版行为对照表。

#### 3.3 量化指标

| 指标 | 目标值 |
| --- | --- |
| 覆盖的 FTP 命令 | ≥ 30 条（对齐参考实现） |
| 目录行解析风格 | 4 类（RFC 3659 / ls -l / MS-DOS DIR / hostedftp） |
| 单元测试覆盖 | 核心纯逻辑包行覆盖 ≥ 85% |
| 集成验证 | 至少对接 2 种真实服务端（pure-ftpd、vsftpd） |
| 代码规模 | 生产代码约 2000 行 MoonBit |

### 四、技术方案概要

> 详见 `docs/porting-jlaffaye-ftp.md`。

- **分层架构**：`status` / `entry` / `parser` / `scanner` / `walker`（纯逻辑） + `textproto` / `transport`（IO） + `ftp`（客户端门面）。
- **关键决策**：先做无网络依赖的 P0，锁定协议行为；网络层通过 `transport` trait 隔离，降低对 `moonbitlang/async` 版本稳定性的耦合。
- **行为对齐**：命令序列、能力协商（FEAT 驱动）、EPSV→PASV 降级、PASV IP 信任策略、数据连接 226 收尾等语义逐项对齐。
- **安全**：保留命令注入防护（拒绝 CR/LF）、默认拒绝 PASV 返回的第三方 IP（SSRF 防护）。
- **测试**：移植 Go 版内置 mock FTP server，用真实 TCP 回环校验命令序列与降级路径。

### 五、实施计划

【待确认】需与飞书文档中的时间安排对齐，以下为建议排期。

| 里程碑 | 内容 | 周期 | 交付物 |
| --- | --- | --- | --- |
| M1 | P0 纯逻辑层 + 单测 | 第 1~2 周 | `src/status|entry|parser|scanner|walker`，CI 全绿 |
| M2 | P1 控制连接 + mock server | 第 3~4 周 | 可完成登录并执行基础命令 |
| M3 | P2 数据传输 + CLI | 第 5~6 周 | 可上传/下载/递归遍历，CLI 可用 |
| M4 | P3 增强 + 文档 | 第 7 周 | 集成测试报告、行为对照表、使用文档 |

总工作量估算：12~17 人日（详见移植方案第 7 节）。

### 六、预期成果

1. 可复用的 MoonBit FTP 客户端库，发布至 mooncakes 生态。
2. 完整的测试套件（≥ 40 个测试用例，含 mock server 集成测试）。
3. 移植方法论文档：`docs/porting-jlaffaye-ftp.md`（含模块映射、API 对照、风险对策）。
4. 可运行的 CLI 示例。
5. 【待确认】是否产出对外分享材料（技术博客 / 移植经验总结）。

### 七、风险与应对

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| MoonBit 网络/TLS 生态不成熟 | P1 起进度不确定 | 抽象 transport，P0 先行交付；TLS 延后 |
| `moonbitlang/async` API 演进 | 返工 | 锁定版本，网络代码隔离在两个包内 |
| 时间类型语义差异 | 解析结果偏差 | 统一 `ZonedDateTime`，测试用 UTC 时间戳比较 |
| 无真实 FTP 服务端联调条件 | 集成测试不足 | 用 Docker 起 pure-ftpd/vsftpd；先靠 mock 保底 |

### 八、与飞书文档的差异记录

【待确认】获得飞书文档后，在此列出本稿与原文的差异及回填项。
