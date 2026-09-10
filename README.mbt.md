# PaiGack/ftp

MoonBit 实现的 FTP 项目。

## 环境要求

- [MoonBit](https://www.moonbitlang.com/download) 工具链（`moon`）

安装：

```bash
curl -fsSL https://cli.moonbitlang.cn/install/unix.sh | bash
export PATH="$HOME/.moon/bin:$PATH"
```

## 开发

```bash
moon check          # 类型检查
moon build          # 构建
moon test           # 运行测试
moon run cmd/main   # 运行可执行程序
moon fmt            # 格式化
```

## 目录结构

```
.
├── .ide/Dockerfile       # 开发环境（MoonBit 工具链 + VS Code 扩展）
├── .cnb.yml              # CNB 流水线配置
├── cmd/main/             # 可执行入口
├── ftp.mbt               # 库代码
├── ftp_test.mbt          # 黑盒测试
├── ftp_wbtest.mbt        # 白盒测试
├── moon.mod              # 模块配置
└── moon.pkg              # 包配置
```

## 开发环境与 CI 共用镜像

`.ide/Dockerfile` 同时作为云原生开发环境与 CI 构建环境：

- 本地/云端 IDE：`.ide/Dockerfile`（MoonBit 工具链 + VS Code 扩展）
- CI 流水线：`.cnb.yml` 通过 `docker.build` 复用同一 Dockerfile，镜像按 `versionBy` 哈希缓存，Dockerfile 未变更时不重复构建

修改 `.ide/Dockerfile` 后，CI 与开发环境会自动使用新镜像。
