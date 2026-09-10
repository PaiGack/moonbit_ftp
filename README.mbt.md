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
├── .ide/Dockerfile         # 开发环境（MoonBit 工具链 + VS Code 扩展）
├── .cnb.yml                # CNB 流水线
├── .github/workflows/ci.yml # GitHub Actions 流水线
├── cmd/main/               # 可执行入口
├── ftp.mbt                 # 库代码
├── ftp_test.mbt            # 黑盒测试
├── ftp_wbtest.mbt          # 白盒测试
├── moon.mod                # 模块配置
└── moon.pkg                # 包配置
```

## CI

- **GitHub Actions**（`.github/workflows/ci.yml`）：`moon fmt --check`、`moon check --deny-warn`、
  `moon info` 一致性检查、`moon test --enable-coverage`、多后端构建与示例运行。
- **CNB 流水线**（`.cnb.yml`）：复用 `.ide/Dockerfile` 构建的镜像，按 `versionBy` 哈希缓存。

## 致谢与来源

本项目为 [jlaffaye/ftp](https://github.com/jlaffaye/ftp)（ISC License）的 MoonBit 移植，
参考其协议实现与测试用例。原项目版权归 Julien Laffaye 所有。
