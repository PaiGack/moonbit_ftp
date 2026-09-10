# 08 验收标准

## 1. 工作包级 DoD

每个工作包都要满足的基础 DoD：

```bash
export PATH="$HOME/.moon/bin:$PATH"

moon fmt --check                        # 格式干净
moon check --target native --deny-warn  # 0 warning 0 error
moon test  --target native              # 全绿
moon info && git diff --exit-code       # 接口文件无未提交变更
```

额外要求：

- [ ] 每个工作包一个独立 PR，PR 描述里写清「做了哪个工作包、验收怎么跑」
- [ ] 新增公开 API 必须有黑盒测试（`_test.mbt`）
- [ ] 内部不变量必须有白盒测试（`_wbtest.mbt`）
- [ ] `.mbti` 接口变更在 PR 里显式说明

## 2. 阶段级验收

### W1 完成

- [ ] 上游 `parse_test.go` 30+ 条用例**逐条通过**（含 8 条失败用例的错误类型）
- [ ] 上游 `scanner_test.go` 用例逐条通过（含中间态断言）
- [ ] 上游 `constants_test.go` 用例通过
- [ ] `parse` / `scanner` / `types` / `status` 包内**无** `moonbitlang/async` 引用
- [ ] 半年规则 4 条边界用例通过（`22:59` 不减年 / `23:00` 减年）

### W2 完成

- [ ] 单行响应解析正确
- [ ] 多行响应（`211-...211 End`）解析出正确正文与状态码
- [ ] 状态码不匹配 → `ServerError` 且携带原始 message
- [ ] 参数含 `\r`/`\n` → `InvalidCommand`，且**未发出任何字节**

### W3 完成

- [ ] EPSV 正常路径通过
- [ ] EPSV 失败 → 降级 PASV，且 `EPSV` 只发一次
- [ ] PASV 可疑 IP 默认不信任；`trust_pasv_ip=true` 时跟随
- [ ] `REST` 偏移生效
- [ ] TLS 模式建连不阻塞

### W4 完成

- [ ] 命令序列断言通过：

```
["USER", "PASS", "FEAT", "TYPE", "OPTS", "QUIT"]
```

- [ ] FEAT 不支持（返回 `500`）时 `login` 仍成功，且不发 `OPTS`
- [ ] `pwd` 能从 `257 "/incoming"` 提取路径
- [ ] `AUTH TLS` 模式能升级控制连接

### W5 完成

- [ ] `list` 对 MLSD 画像走 `MLSD`，对 `disable_mlsd` 走 `LIST`
- [ ] `list` 遇到无法解析的行**跳过不报错**
- [ ] `retr` / `retr_from` / `stor` / `stor_from` / `append` 均通过 mock 端到端
- [ ] `response.close()` 调两次不报错
- [ ] 零字节 TLS 上传不报 `425`
- [ ] `set_time` 对三种画像分别走 `MFMT` / `MDTM 写` / 报不支持

### W6 完成

- [ ] [06-compat-checklist.md](./06-compat-checklist.md) 的 9 条验收勾选表**全部打勾**
- [ ] `walker` 语义对齐上游 `walker_test.go`（`skip_dir`、空栈、`cur` 初始化）
- [ ] 6 个服务器画像各至少 1 条测试

### W7 完成

- [ ] CLI 六个子命令（`ls` / `get` / `put` / `walk` / `mkdir` / `rm`）在本地 `pyftpdlib` 上跑通
      （服务器由 `.github/ftp-fixture/serve.py` 起，与 CI 同一份）
- [ ] README 里每条命令都能照着复现
- [ ] 错误输出到 stderr，退出码非 0

### W8 完成

- [ ] `moon add PaiGack/ftp` 在干净项目里可用
- [ ] mooncakes.io 上能访问项目页
- [ ] `LICENSE-THIRD-PARTY` 含上游 ISC 原文 + 署名 + 来源链接
- [ ] 「与 Go 版行为对照表」写入文档，覆盖全部有意差异
- [ ] 打 tag 并发布 Release

## 3. 交付物清单

```
代码（单一根包，源码全部平铺在仓库根目录，无子目录、无 src/ 中间层）
├── entry.mbt / consts.mbt        Entry / EntryType / TransferType / 常量
├── status.mbt                    ~50 状态码 + status_text
├── error.mbt                     FtpError / FtpErrors
├── scanner.mbt                   空白字段扫描器
├── parse*.mbt                    四种 LIST 解析器 + 半年规则
├── pathutil.mbt                  远端路径 join
├── control.mbt / command.mbt / response.mbt
│                                 命令编码 + 多行响应 + 状态校验
├── state.mbt                     client 与 transport 共享连接状态
├── transport_*.mbt               EPSV / PASV / PRET / REST / 数据连接 / TLS
├── client*.mbt / options.mbt / dial.mbt / login.mbt
├── list.mbt / transfer.mbt / fsops.mbt / lifecycle.mbt
│                                 FTPClient 公开 API
├── walker.mbt                    目录树遍历
├── debug.mbt                     流量日志
├── architecture.mbt              纯逻辑 / IO 文件清单
└── cmd/ftp/                      CLI 示例

测试
├── 轨道 A：解析/scanner/常量用例（搬运上游，30+ 条）
├── 轨道 B1：mock FTP 服务器端到端（6 种画像，命令序列断言）
└── 轨道 B2：真实 FTP 服务器端到端（`ftp_server_test.mbt`，CI 起 pyftpdlib）

文档
├── README.mbt.md                     目标 / 安装 / 用法 / 示例
├── docs/porting.md                    总体方案
├── docs/porting/*.md                  本实施文档集（8 篇）
├── docs/go-compat.md                  Go 版行为对照表
└── LICENSE-THIRD-PARTY                上游 ISC 原文与署名

发布
├── mooncakes.io 上的 PaiGack/ftp
└── Release tag
```

### 真实服务器测试就绪（W7 前置）

- [x] `ftp_server_test.mbt` 13 条用例在 `pyftpdlib` 上全绿
- [x] 未设 `FTP_TEST_HOST` 时用例不失败（本机 `moon test` 保持全绿）
- [x] GitHub Actions 起真服务器并跑真机用例
- [x] CNB `main.push` / `pull_request` 通过 DinD 起真服务器
- [x] CNB 云原生开发环境（`$: vscode:`）进入前起好同一个服务器
- [x] fixture 内容由 git 固定（`.github/ftp-fixture/fixture/`）
- [ ] TLS（`AUTH TLS`）真机用例——未做，见 05-testing.md 6.6

## 4. 未达成时的处理原则

- **不声称未验证的能力**：TLS 数据连接、真实服务器兼容性若未实测，文档里标注「未验证」，不用「已支持」措辞。
- **不跳过兼容清单**：9 条里任何一条没打勾，就不算 W6 完成。
- **不用空提交充数**：提交粒度按 [03-workplan.md](./03-workplan.md)「提交节奏建议」执行，每个提交对应真实产出。
- **不隐藏行为差异**：与 Go 版不同的地方（超时 API 形状、`Mutex`、`Response` 边界）全部写进对照表。
