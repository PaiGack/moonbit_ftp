# 移植方案文档集

本目录是 `jlaffaye/ftp` → MoonBit 移植的**可执行实施文档**。
`../porting-jlaffaye-ftp.md` 是总体方案（为什么做、做什么、分几期），
本目录回答「**怎么做，按什么顺序做，每步怎么验收**」。

## 文档地图

| 文档 | 定位 | 读者 |
| --- | --- | --- |
| [01-architecture.md](./01-architecture.md) | 目标架构：包结构、依赖方向、错误模型、构建配置 | 所有人，先读这篇 |
| [02-upstream-map.md](./02-upstream-map.md) | 上游 6 个文件 → MoonBit 包/文件的逐条落点映射 | 动手写代码的人 |
| [03-workplan.md](./03-workplan.md) | **核心**：W0–W8 工作包拆解、每包任务清单、验收标准、工作量 | 排期与执行 |
| [04-api-mapping.md](./04-api-mapping.md) | Go API → MoonBit API 一一对照表（含 16 个 DialWith 选项） | 写公开 API 的人 |
| [05-testing.md](./05-testing.md) | 测试双轨策略：解析用例搬迁 + mock FTP 服务器 | 写测试的人 |
| [06-compat-checklist.md](./06-compat-checklist.md) | 9 个协议兼容性要点 + 服务器画像差异的落地清单 | 所有人，验收前必过 |
| [07-risks-and-estimation.md](./07-risks-and-estimation.md) | 风险清单、应对预案、人日估算 | 排期与决策 |
| [08-acceptance.md](./08-acceptance.md) | 交付验收清单与 DoD（对照赛事验收 9 条） | 验收 |

## 一分钟速览

```
目标：MoonBit 原生 FTP 客户端，moon add PaiGack/ftp 可用
技术栈：moonbitlang/async 0.21.3（native），socket / io / tls
架构：纯逻辑层（无 IO，可单测） ← 控制层 ← 传输层 ← 客户端层 ← 遍历层
顺序：W0 骨架 → W1 纯逻辑 → W2 控制协议 → W3 数据通道 → W4 命令集
      → W5 传输 → W6 遍历/兼容 → W7 CLI → W8 发布
规模：生产代码约 2000 行，测试约 1500 行，合计 12~17 人日
不可丢的 9 个兼容性坑：见 06-compat-checklist.md，这是「能连真实服务器」的分水岭
```

## 与总体方案的关系

- 本文档集**不重复**总体方案里的上游背景、选题理由、许可证说明。
- 总体方案里的 P0–P7 是**阶段名**；本文档把 P0/P1 再细分为 W0–W8 **工作包**，粒度到「一个 PR 能做完并验证」。
- 若两者冲突，以本文档为准（更细、更新）。
