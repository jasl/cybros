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

补充（Cybros app 侧约定）：

- 默认 resolver 委托到 `Cybros::AgentRuntimeResolver.runtime_for(node:)`
- resolver 会读取 `node.graph.attachable`（通常是 `Conversation`）的 `conversations.metadata["agent"]` 并立刻生效：
  - `agent_profile`：通过 `Policy::Profiled` 包裹 base policy，影响 tools 可见性与 `authorize`（拒绝原因 `tool_not_in_profile` 可审计）
  - `context_turns`：覆盖 runtime 的 context turns 窗口（范围 1..1000）
- profiles 映射见：`lib/cybros/agent_profiles.rb`（`coding|review|subagent|repair`）
- `agent_profile` 支持两种形状：
  - String：预置 profile 名
  - Object：`{ base: "...", ...overrides }`（安全白名单字段，见 `lib/cybros/agent_profile_config.rb`）
    - `system_prompt_sections`：内建 system prompt sections 的 section-level overrides（enabled/order/prompt_modes/stability）
    - `directives_enabled`：是否启用 directives envelope 模式（当前要求 tools 为空；可配合 `tools_allowed: []` 禁用 tools）

多渠道（routing）约定：

- 默认把渠道写在 `conversation.metadata["routing"]["channel"]`（例如 `"web"|"slack"|"telegram"`）
- 单个 turn 需要覆盖时，可写在 `node.metadata["routing"]["channel"]`（node 覆盖优先）
- resolver（或其委托）负责把 `effective_channel` 写入 `runtime.execution_context_attributes[:channel]`，executor 会将其透传到 `execution_context.attributes[:channel]`，用于 `<channel>` system tail section（仅当存在时注入，不影响 prefix 稳定性）

---

## 2) `AgentCore::DAG::Runtime` 字段（核心）

必填：

- `provider`：`AgentCore::Resources::Provider::Base`（当前内置 `SimpleInferenceProvider`，OpenAI-compatible）
- `model`：String
- `tools_registry`：`AgentCore::Resources::Tools::Registry`

可选（强烈建议 app 显式注入）：

- `fallback_models`：Provider failover 模型列表（同 provider；默认 `[]`，空数组表示不启用 failover）
- `tool_policy`：`AgentCore::Resources::Tools::Policy::*`（默认 `DenyAll`）
  - 内建 policy（可组合）：
    - `Policy::DenyAll` / `Policy::AllowAll`
    - `Policy::ConfirmAll`：工具可见，但所有执行默认进入审批（`awaiting_approval`）
    - `Policy::DenyAllVisible`：工具可见，但所有执行默认拒绝（可用于 “dontAsk” 风格默认）
    - `Policy::Profiled`：控制 tool schema 可见性（支持 `group:...`，见 `Policy::ToolGroups`）
    - `Policy::PatternRules`：按 tool name + arguments（path/url 等）判定 allow/confirm/deny
    - `Policy::Ruleset`：三段式规则（deny>confirm>allow，first-match-wins）
    - `Policy::PrefixRules`：对 exec/shell 类工具按命令前缀判定 allow/confirm/deny
    - `Policy::ToolGroups`：`group:fs` 这类“工具集合名”展开
  - 组合建议：
    - `Profiled` 放最外层（决定可见 tools）
    - `PatternRules/PrefixRules` 仅做 `authorize`，`filter` 默认直接委托给下游
- `tool_name_aliases`：工具名 alias 表（Hash；用于把模型输出名解析到 registry 中的 canonical name）
- `tool_name_normalize_fallback`：是否启用启发式工具名 normalize fallback（默认 `false`；覆盖大小写 / 驼峰 / 分隔符漂移，并映射回 registry 中的 canonical tool name；启用后会对工具名做碰撞预检，存在歧义会 raise `AgentCore::Resources::Tools::ToolNameConflictError`）
- `skills_store`：`AgentCore::Resources::Skills::Store`（用于 `<available_skills>` 注入）
- `memory_store`：`AgentCore::Resources::Memory::Base`（用于 `<relevant_context>` 注入）
- `memory_search_limit`：memory 注入条数上限（默认 5；设为 0 可禁用注入但保留 store）
- `tool_output_pruner`：`AgentCore::ContextManagement::ToolOutputPruner`（仅在超预算时启用；可设为 nil 禁用）
- `prompt_injection_sources`：`AgentCore::Resources::PromptInjections::Source::*`
- `instrumenter`：`AgentCore::Observability::Instrumenter`（默认 `NullInstrumenter`）
- `execution_context_attributes`：执行上下文属性（Hash，Symbol keys；executor 会基于它构建 `ExecutionContext.attributes`，并自动注入 `dag.graph_id/node_id/lane_id/turn_id`；可用于注入 `cwd/workspace_dir/channel/agent/...` 等 app 侧信息）
- `token_counter`：`AgentCore::Resources::TokenCounter::*`（用于 token budget 的估算；默认 `AgentCore::Resources::TokenCounter::Estimator`，失败时回退到 `Heuristic`）
- `directives_config`：Hash or nil（nil 表示禁用；Hash 表示启用并使用 `AgentCore::Directives::Runner` 进行 envelope 输出；当前不支持 tool calling）
- `include_skill_locations`：是否在 `<available_skills>` 注入中包含技能 location（默认 `false`）
- `prompt_mode`：提示词模式（默认 `:full`；`prompt_injections` 可按 mode 过滤）
- `system_prompt_section_overrides`：system prompt sections 的 overrides（Hash；由 app 侧 profile 或 `agent_profile.system_prompt_sections` 注入；`time/channel/memory` 强制归入 tail）

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

Tool policy 组合示例：

```ruby
groups =
  AgentCore::Resources::Tools::Policy::ToolGroups.new(
    groups: {
      "fs" => ["read", "write", "apply_patch"],
      "memory" => ["memory_*"],
    },
  )

tool_policy =
  AgentCore::Resources::Tools::Policy::Profiled.new(
    allowed: ["group:fs", "group:memory"],
    tool_groups: groups,
    delegate:
      AgentCore::Resources::Tools::Policy::PatternRules.new(
        tool_groups: groups,
        rules: [
          # Deny reads under config/
          { tools: ["read"], arguments: [{ key: "path", glob: "config/**", normalize: "path" }], decision: { outcome: "deny", reason: "no_config_reads" } },
        ],
        delegate:
	          AgentCore::Resources::Tools::Policy::PrefixRules.new(
	            tool_groups: groups,
	            rules: [
	              # Allow safe, repeatable exec prefixes
	              { tools: ["exec"], argument_key: "command", prefixes: ["git status"], decision: { outcome: "allow", reason: "approved_prefix" } },
	            ],
	            delegate: AgentCore::Resources::Tools::Policy::ConfirmAll.new,
	          ),
      ),
  )
```

Tool calling 稳定性（Runner 级自愈）：

- `tool_call_repair_attempts`：工具参数 parse_error 修复次数（默认 `1`；设为 `0` 可禁用 repair）
- `tool_call_repair_fallback_models`：repair 失败时可升级的模型列表（同 provider；默认 `[]`）
- `tool_call_repair_max_output_tokens`：repair 调用输出上限（默认 `300`；prompt-only JSON）
- `tool_call_repair_validate_schema`：是否启用 schema 语义校验（默认 `true`；当 args 能 parse 但不满足 schema 时也会触发 repair；若仍失败则不执行工具、直接产出 `invalid_args` task）
- `tool_call_repair_schema_max_depth`：schema 校验/repair prompt schema excerpt 的最大深度（默认 `2`）
- `tool_call_repair_max_schema_bytes`：repair prompt 中单个候选 schema 的最大 JSON bytes（默认 `8000`；超限会降级/截断）
- `tool_call_repair_max_candidates`：单次 repair 最多发送的候选数（默认 `10`；超过部分会记录失败原因并保留原 tool_call）
- `tool_name_repair_attempts`：工具名修复次数（默认 `0`；设为 `1` 可在 tool_not_found / tool_not_in_profile 时触发一次“仅修工具名”的修复调用；只允许修到本轮可见工具名列表）
- `tool_name_repair_fallback_models`：tool name repair 失败时可升级的模型列表（同 provider；默认 `[]`）
- `tool_name_repair_max_output_tokens`：tool name repair 调用输出上限（默认 `200`；prompt-only JSON）
- `tool_name_repair_max_candidates`：单次 tool name repair 最多发送的候选数（默认 `10`）
- `tool_name_repair_max_visible_tool_names`：tool name repair prompt 中 visible 工具名列表上限（默认 `200`；超限会截断并在 metadata 标记）

工具错误模式：

- `tool_error_mode`：`:safe`（默认）或 `:debug`（是否在 tool error text 中暴露异常细节）

工具名解析（alias / normalize）：

- AgentCore 内置少量默认 alias（例如 `memory.search`→`memory_search`、`skills.list`→`skills_list`），用于缓解部分模型的工具名漂移。
- 另：`subagent.spawn`/`subagent.poll`（以及 `subagent-spawn`/`subagent-poll`）会映射到 `subagent_spawn`/`subagent_poll`。
- `tool_name_aliases` 可用于追加/覆盖 alias（例如把 `math.add` 映射到 `math_add`）。
- `tool_name_normalize_fallback` 默认关闭；开启后会在 alias 解析失败时尝试 normalize fallback：
  - 大小写漂移：`Skills_List`/`SKILLS_LIST` → `skills_list`
  - camelCase/PascalCase：`memorySearch`/`MemorySearch` → `memory_search`
  - 分隔符漂移：`.`/`-`/空格等 → `_`
  - 注意：启用后会做碰撞预检（例如 `foo-bar` 与 `foo_bar` 同时存在会 raise `AgentCore::Resources::Tools::ToolNameConflictError`），避免“误路由工具”风险。

---

## 3) Tools / MCP / Skills 注册（App 注入）

### 3.1 Native tools

```ruby
registry = AgentCore::Resources::Tools::Registry.new
registry.register(AgentCore::Resources::Tools::Tool.new(name: "echo", description: "...") { |args, **| ... })
```

### 3.1.1 Subagent tools（Cybros）

默认 runtime resolver 会注册：

- `subagent_spawn`
- `subagent_poll`

并以 `conversations.metadata["agent"]` 控制 child conversation 的 `agent_profile/context_turns`（见 `docs/dag/subagent_patterns.md`）。

安全/限制（当前默认）：

- 禁止 nested spawn（subagent 内再 spawn 直接报错）
- `subagent_poll.limit_turns` 最大 50，且 transcript_lines 为预览用途（单行会做 bytes 截断）
- `subagent_poll` 会校验 parent ownership：只能 poll “本会话 spawn 的 child”（基于 parent dag context + child metadata 的 `subagent.parent_*` 校验）；不满足会返回 validation error
- `subagent_poll.child_conversation_id` 会做 UUID 格式校验（fail-fast，减少数据库层异常噪声）

已知限制 / 建议后续（未落地）：

- 建议为 `subagent_spawn` 加入配额/速率限制（避免滥用造成大量 child 会话）。
- 可选新增更高层编排原语：`subagent_run`（spawn+wait/超时）、`subagent_cancel`/`subagent_kill`（终止/取消子会话）。

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
