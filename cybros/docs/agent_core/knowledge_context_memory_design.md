# 知识 / 上下文 / 记忆设计说明（Superseded）

更新时间：2026-03-11

本文档描述的早期 KM 组合方案已经被新的 context-budget shipped behavior 取代，不再代表 active implementation。

当前应以以下文档为准：

- `docs/agent_core/public_api.md`
- `docs/agent_core/behavior_spec.md`
- `docs/agent_core/context_management.md`
- `docs/agent_core/node_payloads.md`

取代关系：

- 长上下文主路径改为 DAG-first context budget
- durable compaction 通过普通 `task(compact_context)` 进入 turn 内 tool loop
- hard cap 只由 `runtime.context_window_tokens` 生效
- model/provider window 字段只保留为 observability
- KM 扩展性讨论应在未来独立文档中重写，并建立在当前 shipped budget/task semantics 之上

如果需要重启更大的 KM 设计工作，请先从 2026-03-11 的 context-budget cut 现状出发，而不是沿用本文档的旧主路径假设。
