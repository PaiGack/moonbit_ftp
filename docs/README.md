# 文档索引

| 文档 | 说明 |
| --- | --- |
| [porting.md](./porting.md) | **总体方案**：将 Go 项目 [jlaffaye/ftp](https://github.com/jlaffaye/ftp) 移植到 MoonBit。上游源码分析（1780 行实现 / 6 文件）、功能矩阵、协议实现要点、依赖选型、分层包结构、分阶段计划、测试策略、许可证合规与风险应对 |
| [porting/](./porting/) | **实施文档集**：可执行的移植步骤拆解。W0–W8 九个工作包、上游文件级落点映射、API 映射表、测试策略、9 条兼容性落地清单、风险与估算、验收标准 |
| [proposal.md](./proposal.md) | 项目申报书：项目价值与生态定位、交付范围与工程边界、实现路径与技术理解 |

## 移植实施文档集

总体方案回答「**为什么做、做什么、分几期**」；`docs/porting/` 回答「**怎么做、什么顺序、每步怎么验收**」。

| 文档 | 内容 |
| --- | --- |
| [porting/README.md](./porting/README.md) | 文档地图与一分钟速览 |
| [porting/01-architecture.md](./porting/01-architecture.md) | 目标架构：11 个包、依赖方向、错误模型、超时与生命周期、构建配置 |
| [porting/02-upstream-map.md](./porting/02-upstream-map.md) | 上游 6 个文件 → MoonBit 包/文件逐条落点；`scanner` / `walker` 行为契约 |
| [porting/03-workplan.md](./porting/03-workplan.md) | **核心**：W0–W8 工作包拆解、任务清单、验收标准、提交节奏 |
| [porting/04-api-mapping.md](./porting/04-api-mapping.md) | Go API → MoonBit API 一一对照（含 16 个 DialWith 选项、调用形态示例） |
| [porting/05-testing.md](./porting/05-testing.md) | 测试双轨：解析用例直搬清单 + mock FTP 服务器实现骨架与画像对照 |
| [porting/06-compat-checklist.md](./porting/06-compat-checklist.md) | **9 条兼容性要点**：为什么做、怎么落地、怎么测、验收勾选表 |
| [porting/07-risks-and-estimation.md](./porting/07-risks-and-estimation.md) | 已实测的 async API 清单、8 项风险与应对、人日估算、里程碑 |
| [porting/08-acceptance.md](./porting/08-acceptance.md) | 工作包级 / 阶段级 DoD、赛事验收 9 条对照、交付物清单 |

## 相关链接

- 参考项目：<https://github.com/jlaffaye/ftp>（ISC License，作者 Julien Laffaye）
- 申报仓库：<https://github.com/PaiGack/moonbit_ftp>
