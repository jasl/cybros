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
- 顶层 interactive conversation 的默认 model / input policy / runtime surface 来自选中的 `Conversation.agent_program`
- `conversations.metadata["agent"]` 不再是顶层 interactive runtime 的主 authority；它只保留给：
  - 显式 legacy `agent_profile` 兼容行
  - subagent worker-boundary payload
- 当 `conversations.metadata["agent"]` 中显式存在 `agent_profile` / `context_turns` 时，resolver 仍会立刻生效：
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
- `runtime_surface`：`AgentCore::RuntimeSurface::Base` 兼容对象（默认安全 no-op）
- `runtime_surface_runner`：`AgentCore::RuntimeSurface::Runner`（负责 helper 注入、timeout/output limit 与 fallback）
- `token_counter`：`AgentCore::Resources::TokenCounter::*`（用于 token budget 的估算；默认 `AgentCore::Resources::TokenCounter::Estimator`，失败时回退到 `Heuristic`）
- `directives_config`：Hash or nil（nil 表示禁用；Hash 表示启用并使用 `AgentCore::Directives::Runner` 进行 envelope 输出；当前不支持 tool calling）
- `agent_call_recovery_attempts`：主 `agent_message/character_message` LLM 调用的自动恢复次数（默认 `1`；表示“首次失败后最多再试几次”）
  - 仅覆盖窄范围可重试失败：
    - `ProviderError.status` ∈ `408/409/429/5xx`
    - stream bootstrap / protocol failure 且尚未写出可见 output delta
      - 若 stream failure 包裹的是 `ProviderError`，仍按 `408/409/429/5xx` 白名单判定
  - 不覆盖：
    - `ContextWindowExceededError`
    - capability / config validation error
    - 已经写出可见 output delta 的 mid-stream failure
- `include_skill_locations`：是否在 `<available_skills>` 注入中包含技能 location（默认 `false`）
- `prompt_mode`：提示词模式（默认 `:full`；`prompt_injections` 可按 mode 过滤）
- `system_prompt_section_overrides`：system prompt sections 的 overrides（Hash；由 app 侧 profile 或 `agent_profile.system_prompt_sections` 注入；`time/channel/memory` 强制归入 tail）

上下文/预算：

- `context_turns`：上下文 turn 窗口（默认 50）
- `context_window_tokens`：AgentCore 唯一生效的 hard cap；`ContextBudgetManager` 只消费这一项做 fit / overflow 判定
- `model_context_window_tokens` / `provider_context_window_tokens`：原始观测值；仅用于 `context_cost` 可观测性，不参与第二套 hard-cap 判定
- `context_soft_limit_tokens` / `context_soft_limit_ratio`：可选 soft-limit 输入；若两者同时存在，取更严格者，并 clamp 到有效 prompt budget
- `reserved_output_tokens`：从 hard cap 中预留给输出，`effective_prompt_budget_tokens = max(context_window_tokens - reserved_output_tokens, 0)`

执行安全阈值：

- `max_tool_calls_per_turn`：单次 LLM 调用（单个 `agent_message/character_message` 节点）最多展开的 tool_calls 数（默认 20；nil 表示不限制）
- `max_steps_per_turn`：同一 `turn_id` 内允许的 agent step 数（默认 10；防止无限 tool loop）

runtime surface 约束：

- surface lifecycle：`prepare_turn` / `compact_context` / `review_tool_call` / `project_tool_result` / `finalize_output` / `handle_error`
- 所有 stage 都只收 typed input，返回 typed decision；不要在 app 侧依赖布尔 hook
- 对 programmable-agent 而言，这些是 AgentCore 通用 runtime middleware stage，不是 `agent_rpc` 的 canonical hook 名：
  - programmable planning 走 `before_agent_step`
  - live-step context pressure 走 `on_context_pressure`
  - spawn-family control 走 `before_subagent_spawn`
  - terminal task notices 走 `after_task_notice` / `after_subagent_result`
  - programmable final output 走 `before_finalize_output`
- surface 永远是 advisory middleware：
  - 静态 tool policy、schema 校验、审批、DAG invariants、sandbox ceilings 仍是最终 authority
  - runner 或 surface 出错时必须回退 runtime-owned default path
- `execution_context_attributes[:runtime_surface]` 应只放安全归一化后的 metadata（如 `type/helpers/stage_limits`），不要放 raw script/source

默认 context-budget 约定（Cybros app 侧）：

- `Cybros::ContextBudget::DefaultPolicy` 是 bundled helper：把 `budget_state` 映射到 `none|advise_compact|enqueue_compact`
- `PromptAssembly` 的默认上下文管理器会按当前 `execution_context.attributes[:dag][:lane_id]` 读取 `lane.prompt_buffer`，并在 budget 计算前把 summaries / notes / handoff material 作为 grouped system sections 渲染进 prompt
- `lane.prompt_buffer.render(max_tokens:)` 已经是 canonical kernel service，但当前 shipped 默认 prompt builder 还不直接走这个 selective render 路径；它更适合 agent-side 自定义 prompt 组装或后续 runtime 演进
- `compact_context` 始终存在于 canonical registry，但默认对模型隐藏
- `merge_lane_state` 也注册在 canonical registry 中，但仅用于 product-owned merge task，不向模型暴露
- 当 bundled policy 产出 `advise_compact` 时，resolver / tool policy 会在该 step 解除 `compact_context` 的可见性掩码
- prompt guidance 中的 `compact_context_available` 只在 tool visibility mask 已解析完成后写入
- 当 bundled policy 产出 `enqueue_compact` 时，executor 会在当前 turn 内插入一个普通 `task(compact_context)`，而不是走额外特权通道

LLM options：

- `llm_options`：透传给 provider（示例：`{ stream: false, temperature: 0.2 }`）

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
- `tool_call_repair_max_output_tokens`：repair 调用输出上限（默认 `300`；prompt-only JSON）
- `tool_call_repair_validate_schema`：是否启用 schema 语义校验（默认 `true`；当 args 能 parse 但不满足 schema 时也会触发 repair；若仍失败则不执行工具、直接产出 `invalid_args` task）
- `tool_call_repair_schema_max_depth`：schema 校验/repair prompt schema excerpt 的最大深度（默认 `2`）
- `tool_call_repair_max_schema_bytes`：repair prompt 中单个候选 schema 的最大 JSON bytes（默认 `8000`；超限会降级/截断）
- `tool_call_repair_max_candidates`：单次 repair 最多发送的候选数（默认 `10`；超过部分会记录失败原因并保留原 tool_call）
- `tool_name_repair_attempts`：工具名修复次数（默认 `0`；设为 `1` 可在 tool_not_found / tool_not_in_profile 时触发一次“仅修工具名”的修复调用；只允许修到本轮可见工具名列表）
- `tool_name_repair_max_output_tokens`：tool name repair 调用输出上限（默认 `200`；prompt-only JSON）
- `tool_name_repair_max_candidates`：单次 tool name repair 最多发送的候选数（默认 `10`）
- `tool_name_repair_max_visible_tool_names`：tool name repair prompt 中 visible 工具名列表上限（默认 `200`；超限会截断并在 metadata 标记）

Tool result / output surface：

- `TaskExecutor` 会 durable 保存 `raw_result`、`result`（projected）、`activity_preview`、`artifact_refs`
- provider prompt history 与 `ContextAdapter` 只消费 projected `result`
- `TurnExecutionProjector` / refresh / replay 可继续依赖 durable `activity_preview` 或 raw preview，因此 UI 预览不要求与模型可见 projection 完全相同
- 非 streaming 最终输出在 AgentCore generic runtime stage 上会经过 `finalize_output`
- 用户可见错误在 AgentCore generic runtime stage 上会经过 `handle_error`
- 若 provider 是 programmable-agent，Cybros 会把 agent-facing runtime events映射到 typed programmable hooks：
  - 终态 assistant output 走 `before_finalize_output`
  - live-step context budget pressure 走 `on_context_pressure`
  - spawn-family task preflight 走 `before_subagent_spawn`
  - 当前已接上的 provider-side / hard-cap agent-step failure notices 走 `after_task_notice`
  - `subagent_wait` 完成后的 delegated-worker 结果走 `after_subagent_result`
- provider/kernel fail-fast 错误若没有安全的 agent callback 通道，仍保持 runtime-owned failed result，不再通过一个泛化的 programmable runtime-error hook 兜底

Programmable-agent 现状：

- 当前仅支持让 `AgentProgram` 通过安全配置快照 opt into runtime-surface config
- 不在这一版里定义 script engine、编辑器 UX、版本化或调试模型

主 LLM 调用稳定性（executor 级自愈）：

- `agent_call_recovery_attempts`：主 LLM 调用的自动恢复次数（默认 `1`）
- 恢复是 **同节点 / 同 turn 的执行视图重试**，不会创建新的 DAG version/retry node
- 成功恢复后，本轮 tool loop / 最终回答流程保持不变
- 恢复耗尽或命中非可重试错误时，节点仍进入 `errored`；App/UI 可继续走 `Conversation#retry_agent_node!` / `DAG::Node#retry!`

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
- `subagent_run`
- `subagent_wait`

并以 worker-boundary metadata 控制 subagent thread 的 `agent_profile/context_turns`（见 `docs/dag/subagent_patterns.md`）。

安全/限制（当前默认）：

- 禁止 nested spawn（subagent 内再 spawn 直接报错）
- `subagent_poll.limit_turns` 最大 50，且 transcript_lines 为预览用途（单行会做 bytes 截断）
- `subagent_run` = `spawn + kick + 初始 snapshot`；返回字段稳定包含 `subagent_id`、`status`、`counts`、`leaf`、`transcript_lines`、`diagnostic_level`
- `subagent_wait` 返回 bounded subagent snapshot，并支持 `timeout_ms`；超时时仍返回成功结果，但会带 `wait_status = "timeout"` / `timed_out = true`
- `subagent_run.diagnostic_level` 可显式传 `standard|debug`，只会写入 subagent 初始 turn 的 execution diagnostics；不会放宽 `subagent` worker 的默认窄权限边界
- `subagent_poll` 会校验 parent ownership：只能 poll “本会话 spawn 的 subagent”（当前实现基于 parent dag context + subagent worker provenance metadata 校验）；不满足会返回 validation error
- `subagent_poll.subagent_id` 会做 UUID 格式校验（fail-fast，减少数据库层异常噪声）
- `subagent_wait` 继承相同的 ownership / UUID 校验约束

已知限制 / 建议后续（未落地）：

- 建议为 `subagent_spawn` / `subagent_run` 加入配额/速率限制（避免滥用造成大量 subagent threads）。
- 可选新增 `subagent_cancel` / `subagent_kill`（终止/取消子会话）。

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
