# AgentCore（DAG-first）迁移对照（vibe_tavern → cybros）

本文档用于回答“旧实验 AgentCore 的能力是否都移植过来、哪里做了结构替换”。

旧代码位置：

- `references/vibe_tavern/vendor/agent_core/lib/agent_core/**`
- `references/vibe_tavern/lib/agent_core/contrib/**`

新实现位置：

- `lib/agent_core/**`
- `docs/agent_core/**`

---

## 1) 结构替换（有意不再保留旧运行架构）

### 1.1 `Agent` / `Agent::Builder`

旧：`AgentCore::Agent` 负责 Resources → PromptBuilder → PromptRunner 的总编排，并支持序列化 config。  
新：改为 **DAG-first**：

- LLM 调用由 `AgentCore::DAG::Executors::AgentMessageExecutor` 驱动
- 工具调用由 `AgentCore::DAG::Executors::TaskExecutor` 驱动
- 运行时依赖通过 `AgentCore::DAG.runtime_resolver` 注入（见 `docs/agent_core/public_api.md`）

### 1.2 `PromptRunner/*`（Continuation / ToolExecutor / Codecs）

旧：`PromptRunner::Runner` 在进程内完成 tool loop，Continuation 用于暂停/恢复。  
新：用 DAG 的节点/状态/边表达同一能力：

- tool_calls → 展开为 `task` 节点 + 下游 `agent_message` 节点
- confirm/deny → `task.state = awaiting_approval/rejected`
- optional/required gate → `sequence` vs `dependency` 边（见 `docs/agent_core/behavior_spec.md`）

### 1.3 `ContextManagement::BudgetManager` + `Resources::ConversationState`

旧：BudgetManager 持有 ConversationState（summary+cursor），实现滑窗 + 自动压缩。  
新：`AgentCore::DAG::ContextBudgetManager` 负责 token budget；压缩落到 DAG：

- 触发 summarizer → `graph.compress!(...)` 生成 `summary` 节点
- 被压缩内容由 DAG 的 `compressed_at` 审计与替代（见 `docs/agent_core/context_management.md`）

---

## 2) 1:1 迁移（保持旧能力）

以下模块保持旧能力（路径/命名可能调整以适配 Zeitwerk）：

- Messages / Content blocks / ToolCall / ToolResult / StreamEvent
- Providers（`SimpleInferenceProvider`，OpenAI-compatible）
- Tools registry + policy（allow/deny/confirm(required + deny_effect)）
- MCP client（stdio + streamable_http + SSE parser）
- Skills store + skills tools（路径安全 + size cap）
- PromptBuilder + PromptInjections（含 TextStore）
- Observability（ActiveSupport / OpenTelemetry instrumenter + trace recorder）
- Contrib（directives / language_policy / openai_history / provider_with_defaults / token_estimation 等）

---

## 3) 测试对照

旧单测（`references/vibe_tavern/vendor/agent_core/test/**`）中：

- 除 `Agent*` / `PromptRunner*` / `BudgetManager*` / `ConversationState*` 外，其余单测均已迁移到 `test/lib/agent_core/**`
- 旧 Runner/Loop 行为由 DAG 集成场景测试覆盖：`test/scenarios/dag/agent_core_dag_integration_flow_test.rb`

---

## 4) 清理项

- gem 形态已放弃：删除 `lib/agent_core/version.rb`，不再提供 `AgentCore::VERSION`
- 依赖 Zeitwerk：移除对本地文件的 `require`（保留必要的 stdlib/可选依赖按需 require）
