# AgentCore（DAG-first）Public API（App 注入点）

本文档描述 app 业务层如何注入 `AgentCore` 的运行时依赖，以及如何启动/推进一个 agent 回合。

---

## 1) 必须配置：`AgentCore::DAG.runtime_resolver`

`AgentCore::DAG` 通过全局 resolver 获取运行时配置：

- `AgentCore::DAG.runtime_resolver = ->(node:) { AgentCore::DAG::Runtime.new(...) }`
- executor 在执行时调用 `AgentCore::DAG.runtime_for(node:)` 获取 runtime

约束：

- resolver 必须返回 `AgentCore::DAG::Runtime`
- runtime 内部尽量用 symbol keys；写入 DAG payload/metadata 时统一 stringify（DAG 边界）

默认实现见：`config/initializers/agent_core.rb`。

---

## 2) `AgentCore::DAG::Runtime` 字段（核心）

必填：

- `provider`：`AgentCore::Resources::Provider::Base`（当前内置 `SimpleInferenceProvider`，OpenAI-compatible）
- `model`：String
- `tools_registry`：`AgentCore::Resources::Tools::Registry`

可选（强烈建议 app 显式注入）：

- `fallback_models`：Provider failover 模型列表（同 provider；默认 `[]`，空数组表示不启用 failover）
- `tool_policy`：`AgentCore::Resources::Tools::Policy::*`（默认 `DenyAll`）
- `tool_name_aliases`：工具名 alias 表（Hash；用于把模型输出名解析到 registry 中的 canonical name）
- `tool_name_normalize_fallback`：是否启用启发式工具名 normalize fallback（默认 `false`；当前仅 `.`→`_`）
- `skills_store`：`AgentCore::Resources::Skills::Store`（用于 `<available_skills>` 注入）
- `memory_store`：`AgentCore::Resources::Memory::Base`（用于 `<relevant_context>` 注入）
- `memory_search_limit`：memory 注入条数上限（默认 5；设为 0 可禁用注入但保留 store）
- `tool_output_pruner`：`AgentCore::ContextManagement::ToolOutputPruner`（仅在超预算时启用；可设为 nil 禁用）
- `prompt_injection_sources`：`AgentCore::Resources::PromptInjections::Source::*`
- `instrumenter`：`AgentCore::Observability::Instrumenter`（默认 `NullInstrumenter`）
- `token_counter`：`AgentCore::Resources::TokenCounter::*`（用于 token budget 的估算；默认 `Heuristic`）
- `include_skill_locations`：是否在 `<available_skills>` 注入中包含技能 location（默认 `false`）
- `prompt_mode`：提示词模式（默认 `:full`；`prompt_injections` 可按 mode 过滤）

上下文/预算：

- `context_turns`：上下文 turn 窗口（默认 50）
- `context_window_tokens` + `reserved_output_tokens`：启用 token budget（nil 表示不启用）
- `auto_compact`：超预算时触发 DAG 压缩（summary 节点）
- `summary_model` / `summary_max_tokens`：自动压缩 summarizer 配置

执行安全阈值：

- `max_tool_calls_per_turn`：单次 LLM 调用（单个 `agent_message/character_message` 节点）最多展开的 tool_calls 数（默认 20；nil 表示不限制）
- `max_steps_per_turn`：同一 `turn_id` 内允许的 agent step 数（默认 10；防止无限 tool loop）

LLM options：

- `llm_options`：透传给 provider（示例：`{ stream: false, temperature: 0.2 }`）

Failover 配置示例（逗号分隔）：

```ruby
fallback_models =
  ENV.fetch("AGENT_CORE_FALLBACK_MODELS", "")
    .split(",")
    .map(&:strip)
    .reject(&:empty?)
```

Tool calling 稳定性（Runner 级自愈）：

- `tool_call_repair_attempts`：工具参数 parse_error 修复次数（默认 `1`；设为 `0` 可禁用 repair）
- `tool_call_repair_fallback_models`：repair 失败时可升级的模型列表（同 provider；默认 `[]`）
- `tool_call_repair_max_output_tokens`：repair 调用输出上限（默认 `300`；prompt-only JSON）

工具错误模式：

- `tool_error_mode`：`:safe`（默认）或 `:debug`（是否在 tool error text 中暴露异常细节）

工具名解析（alias / normalize）：

- AgentCore 内置少量默认 alias（例如 `memory.search`→`memory_search`、`skills.list`→`skills_list`），用于缓解部分模型的工具名漂移。
- `tool_name_aliases` 可用于追加/覆盖 alias（例如把 `math.add` 映射到 `math_add`）。
- `tool_name_normalize_fallback` 默认关闭；开启后会在 alias 解析失败时尝试 `.`→`_` 的 fallback。

---

## 3) Tools / MCP / Skills 注册（App 注入）

### 3.1 Native tools

```ruby
registry = AgentCore::Resources::Tools::Registry.new
registry.register(AgentCore::Resources::Tools::Tool.new(name: "echo", description: "...") { |args, **| ... })
```

### 3.2 Skills tools

- 用于让 LLM 通过 tool calling 做 `skills_list/skills_load/skills_read_file`

```ruby
store = AgentCore::Resources::Skills::FileSystemStore.new(dirs: ["..."])
registry.register_skills_store(store)
runtime = AgentCore::DAG::Runtime.new(..., skills_store: store, tools_registry: registry)
```

### 3.3 MCP tools

```ruby
registry.register_mcp_client(mcp_client, server_id: "my_server")
```

`server_id:` 会把远端工具名映射为安全的本地工具名（避免冲突、避免非法字符）。

### 3.4 Memory tools

- 让 LLM 通过 tool calling 显式管理记忆（按需检索、写入、删除）
- 工具名默认：`memory_search` / `memory_store` / `memory_forget`

```ruby
memory = AgentCore::Resources::Memory::InMemory.new
registry.register_memory_store(memory)

runtime = AgentCore::DAG::Runtime.new(
  ...,
  tools_registry: registry,
  memory_store: memory,
  # memory_search_limit: 0 # 可禁用自动 <relevant_context> 注入，仅保留工具化 memory
)
```

> 注：PromptBuilder 会对 tools schema 做保守 strict 化（缺失时补 `additionalProperties: false` 等），降低 tool args 漂移。

---

## 4) 启动一个回合（创建 user + agent 节点）

最小流程（示意）：

```ruby
conversation = Conversation.create!
graph = conversation.dag_graph
turn_id = SecureRandom.uuid

graph.mutate!(turn_id: turn_id) do |m|
  user = m.create_node(node_type: Messages::UserMessage.node_type_key, state: DAG::Node::FINISHED, content: "Hi", metadata: {})
  agent = m.create_node(node_type: Messages::AgentMessage.node_type_key, state: DAG::Node::PENDING, metadata: {})
  m.create_edge(from_node: user, to_node: agent, edge_type: DAG::Edge::SEQUENCE)
end

graph.kick! # enqueue DAG::TickGraphJob via Solid Queue
```

后续推进由 DAG scheduler/runner 自动完成（含 tool loop）。

---

## 5) 审批/拒绝（awaiting_approval task）

当出现 `task.state = awaiting_approval`：

- approve：`task.approve!`（变为 pending，可被执行）
- deny：`task.deny_approval!(reason: "approval_denied")`（变为 rejected）

required approval gate（dependency）下，deny 会阻塞下游 agent；用户可对 task 执行 `retry!` 来重新发起审批。
