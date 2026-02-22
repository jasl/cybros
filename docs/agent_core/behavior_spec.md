# AgentCore（DAG-first）行为规范（Behavior Spec）

本文档是 `AgentCore::DAG` 在 Cybros 内的**规范性描述**（normative spec）：描述 tool loop、工具名解析、审批、重试、LLM/工具自愈、错误传播与 turn 语义。

实现落点：

- `lib/agent_core/dag/executors/agent_message_executor.rb`
- `lib/agent_core/dag/executors/task_executor.rb`
- `lib/agent_core/dag/context_budget_manager.rb`
- `lib/agent_core/context_management/tool_output_pruner.rb`
- `lib/agent_core/prompt_builder/simple_pipeline.rb`
- `lib/agent_core/resources/tools/tool_name_resolver.rb`
- `lib/agent_core/resources/tools/strict_json_schema.rb`
- `lib/agent_core/resources/tools/policy/profiled.rb`
- `lib/agent_core/resources/tools/tool_call_repair_loop.rb`
- `lib/agent_core/resources/tools/registry.rb`
- `lib/agent_core/resources/memory/tools.rb`
- `lib/agent_core/resources/provider/provider_failover.rb`

---

## 1) 执行入口与节点类型

`AgentCore::DAG` 不定义新的 DAG node_type，而是复用现有 node bodies：

- `Messages::AgentMessage` / `Messages::CharacterMessage`：一次 LLM 调用（可扩展出 tool loop）
- `Messages::Task`：一次工具调用（native/MCP/skills）
- `Messages::Summary`：压缩后的摘要节点（由 auto_compact 产生）

执行由 DAG 引擎驱动：

- `DAG::Scheduler` claim `pending` 节点 → `running`
- `DAG::Runner` 根据 executor 的 `context_mode` 选择 `context_for_full` 或 `context_for`
- executor 返回 `DAG::ExecutionResult`，由 Runner 负责落库与失败传播

---

## 2) Tool loop（LLM → tasks → LLM）

当 `agent_message/character_message` 的 LLM 响应包含 `tool_calls`：

0) 若启用工具名自愈（`runtime.tool_name_repair_attempts > 0`），且 tool name 无法解析到本轮可见工具（visible_tools），会先触发一次工具名修复（ToolNameRepairLoop，见 2.2）
1) 若启用工具参数自愈（`runtime.tool_call_repair_attempts > 0`），会再触发一次参数修复（ToolCallRepairLoop，见 2.3）
2) 在同一 `turn_id` 下创建一个 **next agent node**（pending）
3) 对每个 tool_call 创建一个 `task` 节点，并连边：
   - `agent_message -> task`：`sequence`
   - `task -> next_agent_message`：默认 `sequence`

这样保证：

- tasks 可并行执行（同一 parent 下多个 `task`）
- 即使 tool 失败/拒绝，也能继续进入 next agent（sequence 允许 `errored/rejected/skipped/stopped` 作为“已完成”）

### 2.1 tool name 解析

对 LLM 输出 tool name 的解析使用两级策略（先严格、后宽松）：

1) exact：registry 包含原名（LLM 输出）→ 直接使用
2) alias 表：若配置了 alias（默认 alias + `runtime.tool_name_aliases`）→ 解析到 canonical name
3) normalize fallback（可选）：当 `runtime.tool_name_normalize_fallback=true` 时，尝试启发式 normalize（大小写 / 驼峰 / 分隔符漂移等），并通过“normalize key → canonical tool name”的索引映射回 registry 中的真实工具名

可观测性与审计：

- 当发生 alias/normalize 且成功解析到存在的工具时：
  - `agent_message.metadata["tool_loop"]["tool_name_resolution"]` 记录变更（最多 20 条）
  - 每个 `task.body.input` 都会写入 `name_resolution`（`exact|alias|normalized|repaired|unknown|missing`）
- 当发生 tool name repair 且成功解析到本轮可见工具时：
  - `agent_message.metadata["tool_loop"]["tool_name_repair"]` 记录修复过程（attempts/candidates/repaired/failed 等）
  - 受影响的 `task.body.input` 中 `requested_name` 保留原始模型输出，而 `name` 会写入修复后的可执行工具名（`name_resolution="repaired"`）

> 注：ToolCallRepairLoop 也复用同一套 tool name 解析规则，以便用“可见工具（visible_tools）”匹配 schema。

默认 alias（内置一小部分）用于缓解模型常见漂移：

- `memory.search`/`memory.store`/`memory.forget` → `memory_search`/`memory_store`/`memory_forget`
- `skills.list`/`skills.load`/`skills.read_file` → `skills_list`/`skills_load`/`skills_read_file`

normalize fallback 的安全约束（hard fail）：

- registry 的工具名必须全局唯一（native/MCP 不允许重名）
- 当启用 normalize fallback 时，所有工具名在 normalize-key 维度也必须无歧义（例如 `foo-bar` 与 `foo_bar` 同时存在会 raise `AgentCore::Resources::Tools::ToolNameConflictError`）
- alias key 不能被真实工具名遮蔽（例如 registry 已有 `echo` 工具时，配置 `tool_name_aliases["echo"]="..."` 会 raise `AgentCore::Resources::Tools::ToolNameConflictError`；自映射 `echo→echo` 会被忽略/视为无效）

完整列表与扩展方式见：`AgentCore::Resources::Tools::ToolNameResolver::DEFAULT_ALIASES` 与 `docs/agent_core/public_api.md`。

### 2.2 ToolNameRepairLoop（修 tool name：tool_not_found / tool_not_in_profile）

当 `runtime.tool_name_repair_attempts > 0` 且本轮 tool_calls 中存在“不可见工具名候选”（无法解析到本轮 `visible_tools`）时：

- executor 会对本轮 tool_calls 发起一次“仅修工具名”的 LLM 修复调用：
  - 候选原因：
    - `tool_not_found`：registry 中不存在（或无法解析到）该工具名
    - `tool_not_in_profile`：registry 存在该工具，但不在本轮 `visible_tools`（profile/visibility 过滤掉）
  - 可修复范围：只能把 tool name 映射到“本轮 prompt 可见的工具名列表”（不会扩权）
  - 批量修复一次（允许部分成功；修不了的保留原 tool_call name）
- 修复调用约束：
  - `tools: nil`、`stream: false`、`temperature: 0`（若未指定）
  - 输出必须为纯 JSON：`{"repairs":[{"tool_call_id":"...","name":"..."}]}`
  - `name` 必须是 visible 工具名列表中的 **exact match**
- Prompt 体积治理：
  - `runtime.tool_name_repair_max_visible_tool_names`：visible 工具名列表上限（超限会截断并在 metadata 标记）
  - `runtime.tool_name_repair_max_candidates`：单次最多发送的候选数
- 审计：
  - `agent_message.metadata["tool_loop"]["tool_name_repair"]` 记录 attempts/candidates/repaired/failed 等

> 说明：ToolNameRepairLoop 只影响本次 tool loop 的“执行视图”（用于创建 task），不会回写/覆盖本次 `agent_message.body.output.tool_calls`（后者保留原始模型输出，便于审计）。

### 2.3 ToolCallRepairLoop（修 `arguments_parse_error` + schema invalid）

当 `runtime.tool_call_repair_attempts > 0` 且本轮 tool_calls 中存在“可修复候选”时：

- executor 会对本轮 tool_calls 发起一次“仅修参数”的 LLM 修复调用：
  - 覆盖两类候选：
    - `arguments_parse_error`：`invalid_json/too_large`
    - `schema_invalid`：当 `runtime.tool_call_repair_validate_schema=true` 且 tool args 不满足 schema（漏 required / 类型明显不对 / `additionalProperties:false` 下出现未知 key）
  - 可见工具范围：仅对“本轮 prompt 可见的 tool”（`budget.built_prompt.tools`）尝试修复
  - 批量修复一次（允许部分成功；修不了的保留原 tool_call（含原 arguments / parse_error））
- 修复调用约束：
  - `tools: nil`、`stream: false`、`temperature: 0`（若未指定）
  - 输出必须为纯 JSON：`{"repairs":[{"tool_call_id":"...","arguments":{}}]}`
- Prompt 体积治理（避免 repair 自己超预算/注意力稀释）：
  - 对每个候选的 schema 做 excerpt/truncate（仅保留必要字段与有限深度）
  - `runtime.tool_call_repair_max_schema_bytes`：单个候选 schema 的最大 JSON bytes
  - `runtime.tool_call_repair_max_candidates`：单次 repair 最多发送的候选数
- 审计：
  - `agent_message.metadata["tool_loop"]["repair"]` 记录 attempts/candidates/repaired/failed 等

> 说明：RepairLoop 只影响本次 tool loop 的“执行视图”（用于创建 task），不会回写/覆盖本次 `agent_message.body.output.tool_calls`（后者保留原始模型输出，便于审计）。

### 2.4 policy 决策映射

对每个 tool_call，按以下顺序处理：

1) 参数解析错误（arguments_parse_error）→ 直接创建 `task(state=finished)`，output 为 `ToolResult.error`
2) 工具不存在 → 创建 `task(state=finished)`，output 为 `ToolResult.error`
3) 调用 `tool_policy.authorize(...)`：
   - `allow` →（若启用 schema 校验且仍不满足 schema，则创建 `task(state=finished, source=invalid_args)`；否则）`task(state=pending)`，等待执行
   - `deny` → `task(state=finished)`，output 为 `ToolResult.error`
   - `confirm` →（若启用 schema 校验且仍不满足 schema，则创建 `task(state=finished, source=invalid_args)`；否则）`task(state=awaiting_approval)`，等待人工审批（见第 3 节）

---

## 3) 审批（awaiting_approval）与 required gate

当 policy 返回 `confirm`：

- `task.state = awaiting_approval`
- `task.metadata["approval"]` 包含：
  - `required`（Boolean）
  - `deny_effect`（String，通常为 `"block"`）
  - `reason`（String，展示给 UI）

连边规则：

- 默认（optional approval）：`task -> next_agent_message` 使用 `sequence`
  - deny 后 task 进入 `rejected`，child 可继续执行（等价旧 Runner “拒绝也继续”）
- required approval gate（`required=true && deny_effect="block"`）：`task -> next_agent_message` 使用 `dependency`
  - child 只有在 task `finished` 后才可执行
  - deny（`rejected`）会阻塞 child，但不会被 FailurePropagation 自动跳过（支持 retry 重新发起审批）

用户动作：

- approve：`task.approve!`（`awaiting_approval -> pending`），随后可被 Scheduler claim
- deny：`task.deny_approval!`（`awaiting_approval -> rejected`）

---

## 4) 重试（retry）与审批拒绝的再进入

当 `awaiting_approval` 被 deny 后，task 进入 `rejected(reason="approval_denied")`。

`DAG::Node#retry!` 的规范行为（引擎提供）：

- 对 `rejected(reason="approval_denied")` 的节点，retry 产生的新节点初始状态为 `awaiting_approval`
- 这样 UI 可以“再次审批”，并在 approve 后继续执行

required approval gate 的 child 节点会保持 `pending` 并被 dependency 阻塞，直到新 task `finished`。

---

## 5) 错误与继续执行

- `task` 执行异常：`TaskExecutor` 返回 `ExecutionResult.errored`，节点进入 `errored`
  - 若 `task -> next_agent_message` 为 `sequence`：child 仍可执行
  - prompt 中对应为 tool_result error（见 `ContextAdapter`）
- LLM provider 异常：`AgentMessageExecutor` 返回 `ExecutionResult.errored`，节点进入 `errored`（可 retry）
  - 若配置了 `runtime.fallback_models`，部分 provider/tooling 协议错误会触发 failover（见 5.1）

### 5.1 ProviderFailover（同 provider 多模型重试）

当 `runtime.fallback_models` 非空时，LLM 调用会启用“同 provider 多模型重试”：

- requested model：`runtime.model`
- fallback models：`runtime.fallback_models`（按顺序尝试）
- 触发条件（P0）：
  - `ProviderError.status == 404`（model not found/unsupported）
  - `ProviderError.status in [400, 422]` 且错误信息包含工具/协议相关关键词（`tools/function/schema/...`）
- Streaming 限制（P0）：
  - 仅覆盖 `provider.chat(stream: true)` 在拿到 enumerator 前就 raise 的场景
  - 不处理 mid-stream 错误（不做“中途切换”）

审计：

- `agent_message.body.output["model"]` 记录实际使用的 `used_model`
- 发生 failover 时，`agent_message.metadata["llm"]["failover"]` 记录 requested/used/attempts

---

## 6) max_steps_per_turn（防止无限 tool loop）

当 LLM 持续返回 tool_calls 时：

- `max_steps_per_turn` 限制同一 `turn_id`、同一 lane 内的 `agent_message/character_message` 节点数量
- 超限时，executor 产出一个终止回答并结束扩展：
  - content: `Stopped: exceeded max_steps_per_turn.`
  - metadata: `reason="max_steps_exceeded"`

---

## 7) max_tool_calls_per_turn（防止单次输出膨胀为大量 task）

当单次 LLM 输出包含**超大量** tool_calls 时，会导致：

- DAG 生成大量 `task` 节点（写放大 + 调度压力）
- prompt history 中 tool_calls / tool_results 失衡（协议不一致）

因此 executor 在同一个 `agent_message/character_message` 节点内，对 tool_calls 做上限裁剪：

- 限制项：`runtime.max_tool_calls_per_turn`
  - 默认：`20`
  - 设为 `nil`：禁用限制
- 行为：
  - 仅保留前 `N` 个 tool_calls（顺序不变）
  - 被裁剪的 tool_calls **不会**创建 `task` 节点
  - 同时会把 assistant message 中的 `tool_calls` 也裁剪为相同数量（保证后续 prompt history 一致）
- 可观测性：
  - 当前节点 `metadata["tool_loop"]` 写入：
    - `tool_calls_total` / `tool_calls_executed` / `tool_calls_omitted`
    - `tool_calls_limit`
    - `tool_calls_omitted_names_sample`（最多 10 个，截断为 UTF-8 200 bytes）

---

## 8) 上下文与提示词（概要）

- executor 需要 **full context**（包含 tool/task/summary 等），通过 `context_mode = :full` 向 DAG Runner 声明
- `ContextAdapter` 将 DAG context nodes 映射为 `AgentCore::Message` 列表
- `PromptAssembly` 负责注入 memory、prompt_injections、skills fragment 等

与 tool calling/预算相关的关键行为：

- Tool profiles / visibility：`tool_policy.filter` 决定“哪些 tool schema 对模型可见”（见 `AgentCore::Resources::Tools::Policy::Profiled`）
- Strict schema：发送给模型前，对 tool schema 做保守 strict 化（缺失时补 `additionalProperties:false` 等），降低参数漂移（见 `StrictJsonSchema`）
- Token budget：当启用 `context_window_tokens` 时，超预算会按顺序 drop memory / prune tool outputs / shrink turns / auto_compact，并写入 `context_cost` 便于回放审计（详见 `docs/agent_core/context_management.md`）
- Memory：
  - 注入：`runtime.memory_store` + `runtime.memory_search_limit` 控制 `<relevant_context>` 注入
  - 工具化：注册 memory tools 后，模型可显式调用 `memory_search/memory_store/memory_forget`

详细见：

- `docs/agent_core/node_payloads.md`
- `docs/agent_core/context_management.md`

---

## 9) 后续扩展建议（非规范性）

以下能力**不属于当前实现的行为规范**，但对“tool calling 稳态成功率”提升很有效，建议按需进入 P1：

- failover 错误域扩展（谨慎）：按需覆盖 timeout/5xx/429；mid-stream failover 复杂度高，建议后置
