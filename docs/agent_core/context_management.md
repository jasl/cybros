# AgentCore（DAG-first）上下文管理与自动压缩

本文档描述 `AgentCore::DAG::ContextBudgetManager` 的 token budget 行为，以及 auto_compact 如何把历史 turns 压缩为 DAG `summary` 节点。

实现落点：`lib/agent_core/dag/context_budget_manager.rb`。

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
2) **缩小历史窗口**：递减 `limit_turns`，重取 `graph.context_for_full(node.id, limit_turns:)`
3) 若 `auto_compact=true`：在首次“缩窗后刚好 fit”的时刻尝试压缩（见第 3 节）

若缩到 `limit_turns=1` 仍超预算：

- 抛出 `AgentCore::ContextWindowExceededError`
- executor 将 `agent_message` 标记为 `errored`
- metadata 写入 `context_budget`（含估算 breakdown）

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
