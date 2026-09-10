# moon_ftp 项目申报书

- 项目名称：moon_ftp —— Go `jlaffaye/ftp` 的 MoonBit 移植
- 参赛者：Pai2s
- 联系方式：GitHub [@PaiGack](https://github.com/PaiGack)
- GitHub 仓库：<https://github.com/PaiGack/moonbit_ftp>
- 项目方向：MoonBit 网络协议基础库 / FTP 客户端
- 移植来源：[jlaffaye/ftp](https://github.com/jlaffaye/ftp)（ISC License）
- 本项目许可证：Apache-2.0

## 一、项目价值与生态定位

我要解决的问题很具体：**MoonBit 里连不上 FTP**。mooncakes.io 目前没有任何 FTP 实现，所以任何用
MoonBit 写运维脚本、数据管道、构建发布工具的人，一旦要对接 FTP，就得退回 Go/Python，或者自己
从零趟一遍协议坑。

FTP 看着老，但它今天仍然是设备固件升级、厂商数据拉取、整站备份、内网文件交换的默认协议——这些
场景的服务器往往是十年以上的 VsFtpd / ProFTPD / IIS / Serv-U，行为各不相同。这正是不该自己造轮子
的原因：RFC 959 只规定了"应该怎样"，而这些服务器之间的差异（目录列表格式、时间字段写法的怪癖、
数据连接的 TLS 握手时机）才是"能不能真的连上"的分水岭。

所以我选择移植 `jlaffaye/ftp`：它是 Go 生态里使用最广的 FTP 客户端，1.86k 行实现里很大比例是兼容性
补丁，而不是 socket 封装。它补齐的生态位是 **MoonBit 网络协议库拼图里的"真实世界兼容性"一环**——
比 HTTP 客户端更底层、比裸 TCP 更有实战价值，也是验证 MoonBit 在流式 IO、错误建模、超时取消上
表达能力的合适靶子。生态位重要的另一个原因：它没有竞品，不存在重复建设，做出来就是唯一可用。

## 二、交付范围与工程边界

**要交付的**：

- 可 `moon add PaiGack/ftp` 使用的库：`Dial` / `Login` / `Quit`，EPSV 优先 + PASV 回退的被动模式，
  `List`（MLSD 优先，回退 LIST）/ `NameList` / `GetEntry`，`Retr` / `RetrFrom` / `Stor` / `Append`
  与 `REST` 断点续传，目录与文件操作（`Rename` / `Delete` / `MakeDir` / `RemoveDirRecur` / `FileSize`），
  时间操作（`GetTime` / `SetTime`，兼容 VsFtpd 的 MDTM 写法），`Walk` 目录树遍历，FTPS 显式加密。
- 一个可运行 CLI 示例（`moon run cmd/ftp`，支持 `ls` / `get` / `put` / `walk`）。
- 完整测试：解析用例 + 本地 mock FTP 服务器端到端测试，覆盖命令序列、降级路径和边界输入。
- README、移植说明、上游来源与许可证标注，并发布到 mooncakes.io。

**明确不做的**：主动模式（`PORT`/`EPRT`，上游同样不做）；SFTP/SSH、HTTP 代理；`MODE`/`STRU`/`ALLO`
等冷门扩展命令；单文件并发分片下载（只做多文件并发 + 单文件断点续传）；WASM/JS 后端——FTP 需要
真实网络栈，首版只支持 native，这一点我会在 `moon.mod` 里显式声明 `preferred_target = "native"`，
不给自己留"目标平台写着 wasm 却跑不起来"的含糊空间。

## 三、实现路径与技术理解

**选型**：底层用官方 `moonbitlang/async`（native），它提供了 `socket.Tcp`、`socket.Addr` 和
`tls.Tls`，覆盖连接、TLS、超时与取消。不用 C FFI 阻塞式 socket——那会把平台相关的线程与超时问题
引进来，而 async 栈是官方维护且有内置 TLS。**分层**：把纯协议解析和网络 IO 彻底切开。`types` /
`status` / `scanner` / `parse` 四个包零 IO 依赖，可以直接搬上游用例先跑通；`control` 管命令编码与
多行响应；`transport` 收敛所有数据通道建立逻辑；`client` 是对外 API，`walker` 建在 `client` 上。
这样即使 async 栈将来有破坏性改动，也只需要改 `transport` 一层。接口上把 Go 的 `...DialOption`
变参映射成 MoonBit 的 `label~`，把 `error` 返回值换成 `raise` + 自定义 `suberror`。

**我对这个项目的核心理解：难点不在协议，在兼容性。** 上游代码里最有价值的不是命令行收发，而是下面
这些"踩过坑才写得出来"的细节。移植时必须逐条保住，否则代码能编译、测试能过，却连不上真实服务器：

1. **数据通道关闭后必须回控制通道读 `226/250`**，否则下一条命令会读到上一条的残留响应而错位——这是
   同类实现里最常见的 bug。
2. **EPSV 失败一次就要记住并改用 PASV**，不能每次重试都白等一个超时。
3. **TLS 数据连接不能 dial 后立刻握手**（ProFTPD / PureFTPD 会挂），要延迟到首次读写；上传零字节
   文件时必须显式触发握手。
4. **命令参数要拒绝 `\r` / `\n`**，否则改名或上传路径能被注入第二条 FTP 命令。
5. **`errors.Join` 语义要保留**：传输错误、关闭错误、状态读取错误一起报，而不是遇到第一个就吞掉。
6. **PASV 返回的 IP 默认不信任**，用控制连接的 IP，防止被恶意服务器拿来做 SSRF。
7. **`LIST` 时间字段有"半年规则"**：没有年份时，超过 6 个月视为去年，否则文件时间会整体偏移一年。
8. **四种列表解析器逐个回退**（RFC 3659 → UNIX `ls -l` → DOS DIR → hostedftp），全部失败才报
   `UnsupportedListLine`，否则在老服务器上目录都列不出来。
9. **`Response.Close` 必须幂等**，二次调用返回 nil。

**测试思路**：环回测试比连真实服务器更可复现。上游测试本来就分两层——`parse_test.go` 的纯解析用例
（覆盖四种格式、ACL 权限、符号链接、多空格文件名、非法行）和 `conn_test.go` 的 mock 服务器端到端
用例（模拟 no-time / std-time / vsftpd 三种服务器画像，断言完整命令序列）。我把这两类都复刻：解析
用例直接搬，mock 服务器用 `TcpServer` 重写。这样"协议序列正确"是可验证的事实，而不是靠碰运气。

**分期**：P0 纯逻辑层（零 IO，上游解析用例全绿）→ P1 控制连接 → P2 数据通道 → P3 客户端门面 →
P4 遍历与兼容性打磨 → P5 示例、文档、发布。估算 12~17 人日。

**预期交付物**

- 可 `moon add PaiGack/ftp` 使用的 MoonBit 库
- 一个 CLI 示例（`moon run cmd/ftp`，支持 `ls` / `get` / `put` / `walk`）
- mock FTP 服务器测试 + 解析测试，覆盖全部核心路径
- README、移植说明、上游许可证与来源标注
- 发布到 mooncakes.io

---

## 附：移植方案文档集

`porting.md` 是总体方案（为什么做、做什么、分几期）；`porting/` 目录回答「**怎么做，按什么顺序做，每步怎么验收**」。

| 文档 | 定位 | 读者 |
| --- | --- | --- |
| [porting/01-architecture.md](./porting/01-architecture.md) | 目标架构：包结构、依赖方向、错误模型、构建配置 | 所有人，先读这篇 |
| [porting/02-upstream-map.md](./porting/02-upstream-map.md) | 上游 6 个文件 → MoonBit 包/文件的逐条落点映射 | 动手写代码的人 |
| [porting/03-workplan.md](./porting/03-workplan.md) | **核心**：W0–W8 工作包拆解、每包任务清单、验收标准、工作量 | 排期与执行 |
| [porting/04-api-mapping.md](./porting/04-api-mapping.md) | Go API → MoonBit API 一一对照表（含 16 个 DialWith 选项） | 写公开 API 的人 |
| [porting/05-testing.md](./porting/05-testing.md) | 测试双轨策略：解析用例搬迁 + mock FTP 服务器 | 写测试的人 |
| [porting/06-compat-checklist.md](./porting/06-compat-checklist.md) | 9 个协议兼容性要点 + 服务器画像差异的落地清单 | 所有人，验收前必过 |
| [porting/07-risks-and-estimation.md](./porting/07-risks-and-estimation.md) | 风险清单、应对预案、人日估算 | 排期与决策 |
| [porting/08-acceptance.md](./porting/08-acceptance.md) | 交付验收清单与 DoD（对照赛事验收 9 条） | 验收 |

### 一分钟速览

```
目标：MoonBit 原生 FTP 客户端，moon add PaiGack/ftp 可用
技术栈：moonbitlang/async 0.21.3（native），socket / io / tls
架构：纯逻辑层（无 IO，可单测） ← 控制层 ← 传输层 ← 客户端层 ← 遍历层
顺序：W0 骨架 → W1 纯逻辑 → W2 控制协议 → W3 数据通道 → W4 命令集
      → W5 传输 → W6 遍历/兼容 → W7 CLI → W8 发布
规模：生产代码约 2000 行，测试约 1500 行，合计 12~17 人日
不可丢的 9 个兼容性坑：见 porting/06-compat-checklist.md，这是「能连真实服务器」的分水岭
```

### 与总体方案的关系

- 本文档集**不重复**总体方案里的上游背景、选题理由、许可证说明。
- 总体方案里的 P0–P7 是**阶段名**；本文档把 P0/P1 再细分为 W0–W8 **工作包**，粒度到「一个 PR 能做完并验证」。
- 若两者冲突，以本文档为准（更细、更新）。
