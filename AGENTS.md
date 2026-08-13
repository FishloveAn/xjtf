# 项目协作规范

## 基本要求

- 始终使用简体中文交流，文档与代码注释统一使用 UTF-8 编码。
- 修改前先理解现有实现，优先复用已有模块、场景、资源和数据定义。
- 不为“以后可能需要”增加无实际调用方的抽象、兼容分支或兜底逻辑。
- 保留用户已有的未提交修改，不擅自覆盖、回退、提交或推送。
- 修复问题遵循复现、定位、假设、验证、修复、回归测试的顺序。
- 实现功能或逻辑修复时，先理解现有测试，再补充必要测试，然后实现。

## Agent skills

### Issue tracker

项目任务、PRD 与缺陷统一存放在 GitHub Issues。详见 `docs/agents/issue-tracker.md`。

### Triage labels

使用 `needs-triage`、`needs-info`、`ready-for-agent`、`ready-for-human`、`wontfix`。详见 `docs/agents/triage-labels.md`。

### Domain docs

采用单领域布局：唯一文档文件夹 `docs/` —— 领域上下文 `docs/CONTEXT.md`、架构决策 `docs/adr/`（索引见 `docs/adr/README.md`）、完整资料 `docs/项目文档/`（入口 `docs/项目文档/README-总目录.md`）。详见 `docs/agents/domain.md`。
