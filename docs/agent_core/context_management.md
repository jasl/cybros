# AgentCore（DAG-first）上下文管理与自动压缩

本文档描述 `AgentCore::DAG::ContextBudgetManager` 的 token budget 行为、tool outputs pruning，以及 auto_compact 如何把历史 turns 压缩为 DAG `summary` 节点。

实现落点：`lib/agent_core/dag/context_budget_manager.rb`。

更完整的 KM（Knowledge/Memory）方案与路线图，另见：

- `docs/agent_core/knowledge_context_memory_design.md`
- `docs/agent_core/knowledge_context_memory_implementation_plan.md`

---

## 1) Context 组装（DAG → Prompt）

### 1.1 Context source

`AgentMessageExecutor` 声明 `context_mode = :full`，由 `DAG::Runner` 提供 `graph.context_for_full(node.id)` 的 context nodes。

### 1.2 适配与注入

- `ContextAdapter`：
  - 将 `user_message/agent_message/task/summary` 映射为 `AgentCore::Message`
  - 将 `system_message/developer_message` 合并为 base system prompt
  - 将 `task` 映射为 `tool_result`（或 error tool_result）
- `PromptAssembly` / `PromptBuilder::SimplePipeline`：
  - 注入 memory：`<relevant_context> ... </relevant_context>`（条数由 `runtime.memory_search_limit` 控制）
  - 注入 prompt_injections（sources.items）
  - 注入 skills fragment：`<available_skills ... />`
  - 过滤 tools：`tool_policy.filter`

---

## 2) Token budget（context_window_tokens）

当 `runtime.context_window_tokens` 为非 nil 时启用预算：

- `limit = context_window_tokens - reserved_output_tokens`（小于 0 时按 0 处理）
- 估算使用 `BuiltPrompt#estimate_tokens(token_counter:)`（token_counter 来自 `runtime.token_counter`）

当超预算时，依次执行：

1) **丢弃 memory_results**（保留 prompt injections 与 history）
2) **裁剪旧 tool outputs**（只影响本次 prompt view，不写回 DAG）：
   - 保护最近 `N` 个 user turns（默认 2）
   - 仅裁剪 `tool_result` 消息与 `"[tool:"` 前缀的 system-tool 兜底消息
   - 若在 shrink-loop 中多次尝试 pruning，`context_cost.decisions` 会出现多个 `prune_tool_outputs`，并用 `attempt` 标注次序
3) **缩小历史窗口**：递减 `limit_turns`，重取 `graph.context_for_full(node.id, limit_turns:)`（每次 shrink 后若仍超预算，会再次尝试 pruning）
4) 若 `auto_compact=true`：在首次“缩窗后刚好 fit”的时刻尝试压缩（见第 3 节；压缩后会重新 estimate，必要时再 pruning）

若缩到 `limit_turns=1` 仍超预算：

- 抛出 `AgentCore::ContextWindowExceededError`
- executor 将 `agent_message` 标记为 `errored`
- metadata 写入 `context_cost`（至少包含 limit 与最后一次估算 tokens）

每次调用（含成功与 `ContextWindowExceededError` 失败路径）都会写入：

- `agent_message.metadata["context_cost"]`：预算、估算 tokens（final prompt），以及发生过的降级决策（drop memory / prune tool outputs / shrink turns / auto_compact）。

---

## 3) auto_compact（DAG summary 节点）

当 `auto_compact=true` 且预算迫使 `limit_turns` 下降时：

1) 计算“被缩窗丢弃的 nodes”（同 lane、finished、非 system/developer/summary）
2) 将这些 nodes 渲染为简短 transcript（User/Assistant/Tool 行）
3) 调用 summarizer（LLM，同步）生成 summary text
4) 调用 `graph.compress!(node_ids: dropped, summary_content: ...)`
   - 被压缩 nodes/incident edges 标记 `compressed_at`
   - 生成一个 `summary` 节点替代该子图

后续 context 组装时：

- `summary` 节点会被 `ContextAdapter` 渲染为系统消息：
  - `Message(role: :system, content: "<summary>...</summary>")`

约束（由 DAG 压缩机制保证）：

- 只能压缩 finished 节点
- 不能压缩跨 lane 的节点集合
- summary node 不能成为 leaf（必须保留向外的 blocking edges）

---

## 4) 与 DAG Safety Limits 的关系

`graph.context_for_full` 自身有硬性安全上限（nodes/edges window）。

若超过 DAG safety limits，将抛出 `DAG::SafetyLimits::Exceeded`（由调用方处理/降级）。
