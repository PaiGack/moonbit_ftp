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
├── .cnb.yml                # CNB 流水线（开发用）
├── .github/workflows/ci.yml # GitHub Actions 流水线（申报仓库公开 CI）
├── cmd/main/               # 可执行入口
├── ftp.mbt                 # 库代码
├── ftp_test.mbt            # 黑盒测试
├── ftp_wbtest.mbt          # 白盒测试
├── moon.mod                # 模块配置
└── moon.pkg                # 包配置
```

## 仓库地址

本项目以 GitHub 作为公开申报仓库：<https://github.com/PaiGack/moonbit_ftp>

CNB（`cnb.cool`）上的仓库为镜像开发环境，仅用于日常协作，不属于申报地址。

## CI

- **GitHub Actions**（`.github/workflows/ci.yml`）：申报仓库的公开 CI，覆盖 `moon fmt --check`、
  `moon check --deny-warn`、`moon info` 一致性检查、`moon test --enable-coverage`、多后端构建与示例运行。
- **CNB 流水线**（`.cnb.yml`）：开发侧流水线，通过 `docker.build` 复用 `.ide/Dockerfile` 构建的镜像，
  镜像按 `versionBy` 哈希缓存，Dockerfile 未变更时不重复构建。

两者目标不同：GitHub Actions 面向验收与外部可见性，CNB 面向开发效率。代码以 GitHub 仓库为准。

## 文档

- [移植方案（docs/porting-jlaffaye-ftp.md）](docs/porting-jlaffaye-ftp.md) —— `jlaffaye/ftp` 源码分析、包结构设计、API 映射与分阶段计划
- [项目申报书（docs/proposal.md）](docs/proposal.md) —— MoonBit 开源赛事申报材料

## 致谢与来源

本项目为 [jlaffaye/ftp](https://github.com/jlaffaye/ftp)（ISC License）的 MoonBit 移植，
参考其协议实现与测试用例。原项目版权归 Julien Laffaye 所有。
