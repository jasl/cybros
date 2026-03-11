# 知识 / 上下文 / 记忆实施计划（Superseded）

更新时间：2026-03-11

本文档对应的旧实施路线不再是 active delivery plan。

当前已落地并应优先遵循的实现基线：

- `runtime.context_window_tokens` 是唯一 effective hard cap
- `ContextBudgetManager` 负责 fit、budget facts、budget state 与 observability
- `Cybros::ContextBudget::DefaultPolicy` 负责默认 `budget_state -> budget_action` 映射
- `compact_context` 在 active path 中是普通 DAG task/tool call
- loop suppression 依赖 `budget_fingerprint`

当前实现与验证入口：

- `docs/agent_core/context_management.md`
- `docs/agent_core/node_payloads.md`
- `test/scenarios/dag/agent_core_dag_integration_flow_test.rb`
- `test/scenarios/dag/context_overflow_compaction_flow_test.rb`

如果后续要继续推进更广义的 KM 工作，应新建基于当前 shipped context-budget behavior 的计划文档，而不是继续沿用本文件。
