# 任务跟踪：GitHub Issues

本项目的任务、产品需求和缺陷统一存放在 GitHub Issues，仓库由当前 Git 远程地址确定。

## 使用约定

- 创建任务：使用 `gh issue create`，正文应包含背景、范围、验收标准和验证方式。
- 查询任务：使用 `gh issue view <编号> --comments`。
- 列出任务：使用 `gh issue list`，按状态和标签筛选。
- 更新任务：使用 `gh issue edit` 或 `gh issue comment`。
- 关闭任务：完成验收后使用 `gh issue close`，并在评论中说明验证结果。
- 批量拆分需求时，每个 Issue 应尽量形成可独立验证的纵向切片，避免只按文件或技术层拆分。

当技能要求“发布到任务跟踪器”时，即创建 GitHub Issue；当技能要求“读取相关任务”时，应同时读取正文、标签和评论。
