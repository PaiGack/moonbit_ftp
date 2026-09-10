# 申报书：MoonBit FTP 客户端（moonbit_ftp）

> ⚠️ **状态说明 / 待补充**
> 任务要求同时参考飞书文档 <https://bxup9uklfcb.feishu.cn/wiki/Dx4Bwd6D1i3GfHkajQCcF7SznEd> 整理申报书内容。
> 该文档为**外部租户 wiki，静态访问需登录鉴权**（接口返回 `{"code":5,"msg":"Login Required"}`，页面渲染为登录门户页）。
> 机器人当前无该飞书文档的访问凭证，因此**本文件是按任务上下文先行起草的框架稿**，
> 标注 `【待确认】` 的条目需在获得文档内容（或文档原文截图/导出）后回填与校准。
> 若需要，可提供飞书文档的导出 PDF/Markdown，或授予访问权限，我会按原文重写本申报书。

## 一、项目基本信息

| 项目 | 内容 |
| --- | --- |
| 项目名称 | MoonBit FTP 客户端（moonbit_ftp） |
| 模块名 | `PaiGack/ftp` |
| 仓库 | `nrzhangsan/moonbit_ftp` |
| 参考实现 | [github.com/jlaffaye/ftp](https://github.com/jlaffaye/ftp)（Go，RFC 959 客户端） |
| 许可证 | Apache-2.0 |
| 目标平台 | wasm / wasm-gc / native |
| 当前版本 | 0.1.0（初始化模板阶段） |

## 二、项目背景与意义

【待确认】建议按以下逻辑填写，与飞书文档口径对齐：

1. **生态空白**：MoonBit 生态中尚无成熟的 FTP 客户端库；Go 的 `jlaffaye/ftp` 是使用最广的 FTP 客户端实现之一，移植可为 MoonBit 补齐基础网络协议库拼图。
2. **协议价值**：FTP（RFC 959）虽古老，但在嵌入式设备、内网文件交换、构建产物分发等场景仍广泛使用，是「网络协议库」序列中复杂度适中的标杆项目。
3. **工程验证**：移植过程能系统性验证 MoonBit 在 **TCP 网络、流式 IO、错误建模、时间处理** 上的表达能力，反向驱动标准库/生态完善。

## 三、建设目标

### 3.1 总体目标

用 MoonBit 实现一个与 `jlaffaye/ftp` **协议行为等价**的 FTP 客户端库，覆盖控制连接、被动数据传输、目录解析与遍历，并提供可运行的示例程序。

### 3.2 分期目标

- **P0**：协议纯逻辑层（状态码、Entry 模型、LIST/MLSD 解析、目录遍历器），不依赖网络，测试全覆盖。
- **P1**：控制连接层（`textproto` 行协议、TCP 传输抽象），可完成 `dial → login → pwd → feat`。
- **P2**：数据传输层（`list / retr / stor / append / walk` 等），提供 CLI 示例。
- **P3**：增强（可选）：FTPS、并发安全装饰器、断点续传便利 API、与 Go 版行为对照表。

### 3.3 量化指标

| 指标 | 目标值 |
| --- | --- |
| 覆盖的 FTP 命令 | ≥ 30 条（对齐参考实现） |
| 目录行解析风格 | 4 类（RFC 3659 / ls -l / MS-DOS DIR / hostedftp） |
| 单元测试覆盖 | 核心纯逻辑包行覆盖 ≥ 85% |
| 集成验证 | 至少对接 2 种真实服务端（pure-ftpd、vsftpd） |
| 代码规模 | 生产代码约 2000 行 MoonBit |

## 四、技术方案概要

> 详见 `docs/porting-jlaffaye-ftp.md`。

- **分层架构**：`status` / `entry` / `parser` / `scanner` / `walker`（纯逻辑） + `textproto` / `transport`（IO） + `ftp`（客户端门面）。
- **关键决策**：先做无网络依赖的 P0，锁定协议行为；网络层通过 `transport` trait 隔离，降低对 `moonbitlang/async` 版本稳定性的耦合。
- **行为对齐**：命令序列、能力协商（FEAT 驱动）、EPSV→PASV 降级、PASV IP 信任策略、数据连接 226 收尾等语义逐项对齐。
- **安全**：保留命令注入防护（拒绝 CR/LF）、默认拒绝 PASV 返回的第三方 IP（SSRF 防护）。
- **测试**：移植 Go 版内置 mock FTP server，用真实 TCP 回环校验命令序列与降级路径。

## 五、实施计划

【待确认】需与飞书文档中的时间安排对齐，以下为建议排期。

| 里程碑 | 内容 | 周期 | 交付物 |
| --- | --- | --- | --- |
| M1 | P0 纯逻辑层 + 单测 | 第 1~2 周 | `src/status|entry|parser|scanner|walker`，CI 全绿 |
| M2 | P1 控制连接 + mock server | 第 3~4 周 | 可完成登录并执行基础命令 |
| M3 | P2 数据传输 + CLI | 第 5~6 周 | 可上传/下载/递归遍历，CLI 可用 |
| M4 | P3 增强 + 文档 | 第 7 周 | 集成测试报告、行为对照表、使用文档 |

总工作量估算：12~17 人日（详见移植方案第 7 节）。

## 六、预期成果

1. 可复用的 MoonBit FTP 客户端库，发布至 mooncakes 生态。
2. 完整的测试套件（≥ 40 个测试用例，含 mock server 集成测试）。
3. 移植方法论文档：`docs/porting-jlaffaye-ftp.md`（含模块映射、API 对照、风险对策）。
4. 可运行的 CLI 示例。
5. 【待确认】是否产出对外分享材料（技术博客 / 移植经验总结）。

## 七、风险与应对

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| MoonBit 网络/TLS 生态不成熟 | P1 起进度不确定 | 抽象 transport，P0 先行交付；TLS 延后 |
| `moonbitlang/async` API 演进 | 返工 | 锁定版本，网络代码隔离在两个包内 |
| 时间类型语义差异 | 解析结果偏差 | 统一 `ZonedDateTime`，测试用 UTC 时间戳比较 |
| 无真实 FTP 服务端联调条件 | 集成测试不足 | 用 Docker 起 pure-ftpd/vsftpd；先靠 mock 保底 |

## 八、与飞书文档的差异记录

【待确认】获得飞书文档后，在此列出本稿与原文的差异及回填项。
