# AgentCore（DAG-first）上下文预算与 prompt-working-set 主路径

本文档描述 `AgentCore::DAG::ContextBudgetManager` 的 active budget 行为，以及 Cybros 如何把 `lane.prompt_buffer` 与 `compact_context` 接到普通 DAG task/tool loop 中。

实现落点：

- `lib/agent_core/dag/context_budget_manager.rb`
- `lib/agent_core/dag/executors/agent_message_executor.rb`
- `lib/cybros/context_budget/default_policy.rb`
- `lib/cybros/context_budget/tools.rb`

相关文档：

- `docs/agent_core/public_api.md`
- `docs/agent_core/behavior_spec.md`
- `docs/agent_core/node_payloads.md`

---

## 1) Effective limits

在 shipped 实现中，prompt working set 分为三层：

- DAG history window
- `lane.prompt_buffer`
- token budget

`PromptAssembly` 会先把 lane-scoped prompt buffer material 渲染进 system sections，再由 `ContextBudgetManager` 对完整 prompt 做 fit 与 budget state 计算。

---

## 2) Effective limits

- `runtime.context_window_tokens` 是唯一生效的 hard cap
- `effective_prompt_budget_tokens = max(context_window_tokens - reserved_output_tokens, 0)`
- `model_context_window_tokens` / `provider_context_window_tokens` 只是观测字段，会写入 `context_cost`
- soft limit 来自：
  - `context_soft_limit_tokens`
  - `context_soft_limit_ratio * effective_prompt_budget_tokens`
- 若两者同时存在，取更严格者；最终结果 clamp 到 `effective_prompt_budget_tokens`

---

## 3) Prompt fit 顺序

`ContextBudgetManager` 在真正调用 provider 前按如下顺序做 fit：

1. 组装 full prompt（history + `lane.prompt_buffer` + visible tools + injections + memory）
2. 若超 hard cap，先移除 memory results
3. 若仍超 hard cap，对旧 tool outputs 做 prompt-only pruning
4. 若仍超 hard cap，递减 `limit_turns` 并重建 context
5. 若缩到 `limit_turns=1` 仍无法 fit，则抛出 `ContextWindowExceededError`

这些 fit tactics 只负责让 prompt 满足 hard cap，不会自动产出 durable compaction。

---

## 4) Budget states

在 prompt fit 之后，manager 会继续计算：

- `normal`
- `soft_limit_reached`
- `near_hard_cap`
- `forced_fit`

判定原则：

- 只要为了 fit 应用了 drop-memory / prune-tool-outputs / shrink-turns，就记为 `forced_fit`
- 否则当 estimate 穿过 soft limit 时记为 `soft_limit_reached`
- 否则当 estimate 穿过内部 near-hard-cap 阈值时记为 `near_hard_cap`

写入位置：

- `agent_message.metadata["context_budget"]`
  - `budget_state`
  - `budget_action`
  - `budget_fingerprint`
- `agent_message.metadata["context_cost"]`
  - effective / raw hard-limit facts
  - effective / raw soft-limit facts
  - estimated token breakdown
  - fit decisions

---

## 5) Bundled default policy

kernel 只负责计算 budget facts；默认动作映射由独立 helper `Cybros::ContextBudget::DefaultPolicy` 提供：

- `normal -> none`
- `soft_limit_reached -> advise_compact`
- `near_hard_cap -> enqueue_compact`
- `forced_fit -> enqueue_compact`

`AgentMessageExecutor` 只消费 helper 输出，不内嵌这张决策表。

---

## 6) `compact_context` 的 active path

`compact_context` 是 canonical native tool，不是额外特权通道：

- 默认注册在完整工具集合里
- 默认对模型隐藏
- 当 `budget_action=advise_compact` 时，tool visibility mask 才会把它暴露给当前 step
- prompt guidance 中的 `compact_context_available` 也是在 mask 解析完成后才写入

两种进入方式：

1. `advise_compact`
   - prompt 收到最小 budget guidance
   - 模型可自行调用 `compact_context`
   - 生成普通 `task(compact_context)`，source=`model_choice`
2. `enqueue_compact`
   - executor 在当前 turn 内先插入普通 `task(compact_context)`
   - source=`context_budget_policy`
   - 完成后再继续 next agent step

无论哪种方式，`compact_context` 都按普通 task/tool-call 语义参与：

- 审批/可见性/统计
- turn execution projection
- provider prompt history
- lane prompt buffer summary materialization

执行成功后：

- 较老 turn 的可见性变化仍落在 DAG 上
- prompt-side summary / handoff material 落在 `lane.prompt_buffer`
- prompt history 中只回灌 compact task 的短投影，而不是完整摘要正文

---

## 7) Loop suppression

重复 compaction 必须可抑制。

为此，manager 会为每个 turn step 计算一个 `budget_fingerprint`，它只反映：

- 当前 turn / lane
- effective prompt budget
- effective soft limit
- 标准化后的底层上下文节点集合
- `lane.prompt_buffer` 快照

它不会把 compaction 自己产生的 bookkeeping 视为“新的业务上下文变化”。

当同一 fingerprint 下已经存在成功或 noop 的 `compact_context` task 时：

- `advise_compact` 会被抑制
- `enqueue_compact` 也会被抑制

这能避免同一 turn 因为 compaction 自身的 assistant/tool bookkeeping 而反复提示或反复插入 compaction。

---

## 8) `runtime_surface.compact_context`

`compact_context` 工具内部仍复用 app 侧 compaction plan：

- `Conversation::ContextCompactionPlan`
- `runtime_surface.compact_context(input:)`

surface 负责建议保留项、summary text 与预算内安全改写；executor / app 负责：

- 生成普通 DAG task
- 落 durable metadata
- 应用 context visibility mutation
- 写入或更新 `lane.prompt_buffer`

当前 shipped 主路径不再依赖额外的 conversation-entry compaction 或单独的 durable summary 预处理步骤。
