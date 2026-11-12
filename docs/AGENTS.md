# docs/ — 文档

- `porting.md`：从 `jlaffaye/ftp` 移植的完整方案，包括上游分析、包布局
  （2.3 节的分组文件树是分层约束的权威列表）、依赖选型、测试策略与差异裁剪。
  新增或移动根包文件时同步更新 2.3 节的文件树。
- `proposal.md`：立项申报书，保留历史原文；与现状冲突处以 `docs/porting.md`
  和根 `AGENTS.md` 为准。

代码块约定：

- `porting.md` 里的 ```moonbit 围栏是「Go → MoonBit 对照」，只做高亮，
  **有意不进** `moon check`。
- 会被检查的示例代码放在 `README.mbt.md`，写 ```moonbit check。因为它属于根包，
  不能声明 `main`，要用 `test { }` 包起来。`moon fmt` 也会格式化这些代码块。
