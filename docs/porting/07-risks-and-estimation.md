# 07 风险与估算

## 1. 环境与依赖

| 项 | 版本 | 说明 |
| --- | --- | --- |
| MoonBit 工具链 | `0.1.20260904`（实测） | `moonc v0.10.12` |
| `moonbitlang/async` | `0.21.3` | 实测可用 |
| `preferred_target` | `native` | FTP 需要真实 TCP + TLS |
| C 工具链 | `gcc` + `libc6-dev` | **native 后端必需**，见风险 R4 |

### 已实测确认的 async API（0.21.3）

| 能力 | API | 实测结果 |
| --- | --- | --- |
| TCP 连接 | `@socket.Tcp::connect(Addr)` / `connect_to_host(host, port~)` | 可用 |
| TCP 服务端 | `@socket.TcpServer(Addr)` + `.accept()` + `.addr` | 可用 |
| 地址解析 | `@socket.Addr::parse("127.0.0.1:2121")` | 可用（`raise`） |
| 读写 | `@io.Reader` / `@io.Writer` trait，`read_until` / `read_all` / `write` | 可用，跨包边界的行能拼对 |
| TLS | `@tls.Tls::client(raw, trust=, host=)` | 构造可用（async 函数） |
| 并发 | `@async.with_task_group` + `TaskGroup::spawn_bg` + `@async.with_timeout` | 可用，服务端后台协程 + 客户端主协程模式跑通 |
| 超时 | `@async.with_timeout(ms, async fn() { ... })` | 可用 |

> 实测方式：在临时模块里 `moon add moonbitlang/async`，写 `async test` 起 `TcpServer` + 客户端回环读写，
> `moon test --target native --deny-warn` 通过。

## 2. 风险清单

### R1 `moonbitlang/async` API 破坏性变更（概率：高 / 影响：中）

**现状**：0.x 版本，从 0.21.2 到 0.21.3 已有 `#deprecated` 迁移（如 `TcpServer::new` → `TcpServer`，
`.addr()` 方法 → `.addr` 字段）。0.x 阶段这种变更会持续。

**应对**：

1. `moon.mod` 里**锁死版本** `@0.21.3`，不写范围。
2. 所有 socket / TLS / 超时调用**只出现在 `control` / `transport` / `debug` 三个包**。
   实测确认：async 的 io/socket/tls 三类调用是仅有的对外耦合点。
3. 加架构守卫测试：纯逻辑包内出现 `moonbitlang/async` 就判失败。
4. 升级时只改这三个包，测试全绿即可认为无损。

**残余风险**：async 若修改 `@io.Reader` / `@io.Writer` trait 签名，影响面会扩到 `client`。

### R2 时间库能力不足（概率：中 / 影响：高）

**现状**：`parse` 需要按定长格式解析 `yyyyMMddHHmmss`、`_2 Jan 2006 15:04`、`01-02-06  03:04PM` 等
Go 风格时间布局，并做「半年规则」运算。MoonBit 的 `moonbitlang/x/time` 若缺**严格定长解析**
（不接受多余字符、必须按位置对齐），`set_time` 就要手写解析器。

**应对**：

1. **W1.5 一开始就先探这个 API**，用最小样例验证三类格式串能否直接表达。
2. 若不行，手写定长解析（约 80~120 行）：按位置切字段 → 校验数字 → 构造日期。这是纯逻辑，测试成本低。
3. `ZonedDateTime` 的「加 6 个月」「减 1 年」语义需要确认；若缺，退化为「加 182 天」，但**必须与上游测试用例的边界值对齐**（上游用例正好在分钟级边界上，所以不能随便近似）。
4. 兜底：把 `now` 作为显式参数贯穿解析层（上游本来就是这么设计的），便于注入测试时间，不依赖系统时钟。

**这是 W1 最大的不确定性，建议第一个探通。**

### R3 TLS 数据连接在真实服务器上的兼容性（概率：中 / 影响：中）

**现状**：ProFTPD / PureFTPD 的坑无法在 mock 上完全复现。mock 能验证「不阻塞握手」，
但握手时序问题只有在真实服务器上才暴露。

**应对**：

1. 严格复刻上游策略：只包不握手 + 零字节显式握手。
2. W8 前用 Docker 起 `pure-ftpd` / `vsftpd` 做一次真实 FTPS 冒烟。
3. 若真实环境不可得，在文档中标注「TLS 数据连接未经真实服务器验证」，**不要声称已验证**。

### R4 native 后端缺 C 工具链（概率：已实际发生 / 影响：高）

**现状**：实测在本 runner 上 `moon test --target native` 初报：

```
new native backend requires a C compiler/linker driver; install clang/cc or set MOON_CC
no system C compiler found; tried cl, cc, gcc, clang
```

装 `gcc` 后继续报：

```
/usr/lib/gcc/.../stdint.h:9:16: fatal error: stdint.h: No such file or directory
```

需再装 `libc6-dev` 才通过。

**应对**：

1. `.ide/Dockerfile` 的 apt 安装行从 `gcc libssl-dev strace` 改为 `gcc libc6-dev libssl-dev strace`。
2. 该文件改动会触发 CNB 镜像重建（`.cnb.yml` 的 `versionBy` 绑定它），首次 CI 变慢属预期。
3. `.github/workflows/ci.yml` 用 `ubuntu-latest` 自带 gcc，无需改；但**必须去掉 `--target wasm-gc` 的构建步骤**。

### R5 无 pasv IP 私网/回环判定 API（概率：中 / 影响：中）

**现状**：`@socket.Addr` 实测只有 `is_multicast()`。`isBogusDataIP` 还需要判断私网与回环。

**应对**：自行实现 IP 段判断（约 30 行）：

```
私网：10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, fc00::/7
回环：127.0.0.0/8, ::1
```

纯逻辑，可直接单测。若后续 async 补了 API，替换实现即可。

### R6 无 per-connection deadline（概率：确定 / 影响：低）

**现状**：Go 版 `Response.SetDeadline(绝对时间)` 在 async IO 模型里没有等价原语。

**应对**：改为 `with_deadline(ms, fn)` 限时作用域。能力不降级（一样能限制超时），
但要在 `docs/` 里**明确记录为有意差异**，避免用户按 Go 版文档写代码。

### R7 无真实 FTP 服务器联调（概率：中 / 影响：中）

**应对**：mock 保底 + CI 可选阶段启 `pyftpdlib` / `vsftpd` 容器。
排在 W6 之后，不阻塞主线。

### R8 覆盖率不达标（概率：低 / 影响：低）

**应对**：轨道 A 的用例密集度足够把 `parse` / `scanner` 刷到 90%+。
`client` 层目标是 75%，只要 `close_conn` 的命令序列测试覆盖全方法即可达。

## 3. 工作量估算

按工作包（详见 [03-workplan.md](./03-workplan.md)）：

| 工作包 | 名称 | 乐观 | 现实 | 悲观 | 说明 |
| --- | --- | --- | --- | --- | --- |
| W0 | 工程骨架 | 0.3 | 0.5 | 1.0 | 含 Dockerfile/CI 修正 |
| W1 | 纯逻辑层 | 2.0 | 3.0 | 4.5 | **时间库调研是变数** |
| W2 | 控制协议层 | 1.5 | 2.0 | 3.0 | 多行响应边界 |
| W3 | 数据通道层 | 2.0 | 2.5 | 4.0 | TLS 时序 + SSRF 判定 |
| W4 | 客户端骨架 | 1.5 | 2.0 | 3.0 | FEAT 分支多 |
| W5 | 文件传输 | 1.5 | 2.0 | 3.5 | 错误聚合 + 零字节特例 |
| W6 | 遍历与兼容 | 1.5 | 2.0 | 3.0 | 6 个画像测试 |
| W7 | CLI 示例 | 0.8 | 1.0 | 1.5 | |
| W8 | 文档与发布 | 1.0 | 1.5 | 2.5 | 含真实服务器冒烟 |
| **合计** | | **12.1** | **16.5** | **26.0** | |

结论：

- **最可能区间 12~17 人日**（与总体方案一致）。
- 若 R2（时间库）踩坑且 R3（TLS）需反复联调，上限接近 26 人日。

### 关键路径与并行建议

```
W0 → W1 → W2 → W3 → W4 → W5 → W6 → W7 → W8
        ↑
     R2 在此引爆，越早探越好
```

并行机会：

1. **W4 完成后**，可以先起一个只支持 `ls` 的最小 CLI，边开发 W5 边用真实服务器冒烟。
2. **W1 的 6 个子包**（`types`/`status`/`error`/`scanner`/`parse`/`pathutil`）互不依赖，可并行开发后合并。
3. **W6 的画像测试**可在 W3 完成后就写一部分（数据通道相关画像），不必等 W6。

### 里程碑建议

| 里程碑 | 完成标志 | 累计人日 |
| --- | --- | --- |
| M1 可编译可测 | W0 完成，CI 双绿 | 0.5 |
| M2 协议层可信 | W1 完成，上游解析用例全绿 | 3.5 |
| M3 能连上服务器 | W4 完成，`login` + `pwd` 对 mock 通过 | 8.0 |
| M4 功能可用 | W5 完成，`ls`/`get`/`put` 对 mock 通过 | 10.0 |
| M5 兼容性可信 | W6 完成，9 条兼容清单全打勾 | 12.0 |
| M6 可交付 | W8 完成，CLI + 文档 + 发布 | 16.5 |

## 4. 决策记录（待确认项）

以下决策建议在开工前定下来，避免中途返工：

| 项 | 建议 | 需要谁确认 |
| --- | --- | --- |
| 是否保留 GitHub Actions + CNB 双 CI | 保留，职责划分写进 README | 项目负责人 |
| 是否在 CI 里跑真实 FTP 容器 | 建议仅在 GitHub Actions 里跑（runner 有 Docker） | 项目负责人 |
| 时间类型选 `moonbitlang/x/time` 还是自实现 | 先探 `x/time`，不够就自实现定长解析 | 开发 |
| 是否需要 `Mutex` 保护 | 建议加，成本低、收益明确 | 开发 |
| CLI 是否需要兼容 Go 版 `moonftp` 风格参数 | 不兼容，自定义清晰参数 | 项目负责人 |
