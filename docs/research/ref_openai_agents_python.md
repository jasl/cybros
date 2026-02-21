# 对照调研：OpenAI Agents SDK（references/openai-agents-python）

更新时间：2026-02-21  
调研对象：`references/openai-agents-python`  
参考版本：`f2f0b8c21ad9`（2026-02-19）

## 1) 这套 SDK 解决的是什么问题？

OpenAI Agents SDK（Python）试图把“agent loop + tools + handoffs + guardrails + sessions + tracing”整理成一套轻量框架：

- `Agent`：配置对象（instructions/tools/guardrails/handoffs/output_type…）
- `Runner`：负责执行 loop（工具调用、handoff、停止条件、max_turns）
- `Session`：管理跨多次 `Runner.run()` 的对话历史（SQLite/Redis/自定义）
- `Guardrails`：输入/输出校验（以及 tool input/tool output guardrails）
- `Tracing`：内建可观测（可接外部 tracing processors）

这套 SDK 的核心价值是“API 形状”和“可组合性”，不是某个具体 prompt。

## 2) Agent 作为“纯配置对象”的 API 形状（值得抄）

从 `src/agents/agent.py` 可以看到几个关键设计：

- instructions 可为字符串或动态函数（基于 context 生成）
- tools 同时支持：
  - Function tools（装饰器 `@function_tool`）
  - MCP servers（run 时动态拉取 MCP tools，并可做 strict schema 转换）
- handoffs 是一等能力：agent 可在运行中把控制权交给另一个 agent
- output_type：用结构化输出作为“final output”判定（相比“无 tool calls 即结束”更稳定）

对 Cybros 的映射：

- Cybros 目前的“Runner”其实是 DAG+AgentMessageExecutor：每个 agent_message 执行一次 LLM 调用并展开 tool loop
- 我们缺的主要不是 loop，而是：
  - “Agent 配置对象”的明确抽象（以及 handoff 作为一等能力）
  - “结构化 final output”机制（Ruby 侧可通过 JSON schema/验证器实现）

## 3) Guardrails：输入/输出/工具输入/工具输出（覆盖面很全）

OpenAI Agents SDK 的 guardrails 分层比较完整：

- Input/Output guardrails（见 `src/agents/guardrail.py`）
- Tool input/tool output guardrails（见 `src/agents/tool_guardrails.py`）
  - guardrail 的输出可以是：allow / reject_content（返回给模型一段消息替代 tool result）/ raise_exception（终止）

对 Cybros 的启发：

- 我们当前的安全主要依赖 tool_policy（allow/deny/confirm）与工具执行的截断；
- guardrails 可以作为“更可编排”的安全层：
  - 在 tool 执行前：检查 args 是否含敏感路径/危险参数
  - 在 tool 执行后：检查输出是否包含 secrets/超大内容/不安全指令
  - 在 LLM 输出后：检查是否泄露隐私/是否包含未批准行为

建议落地方式（渐进）：

1. 先补 tool input guardrail（覆盖最大、与现有 policy 协同）
2. 再补 tool output guardrail（做 redaction/截断/敏感信息策略）
3. 最后补 agent output guardrail（内容安全/协议约束）

## 4) Session：把“历史管理”从业务里抽出来

SDK 提供 SQLiteSession/RedisSession，并允许自定义 Session protocol（get_items/add_items）。

对 Cybros：

- DAG lane/turn 已经天然是 session 存储；
- 但可以借鉴其“protocol 化”设计：
  - 让 AgentCore 的 context 组装依赖一个抽象接口（默认实现是 DAG lane），未来也可接外部存储或“跨会话检索”

## 5) Tracing：一等公民（值得对齐）

OpenAI Agents SDK 把 tracing 作为核心能力，并提供外部 processor 生态。

对 Cybros：

- 我们已有 `AgentCore::Observability::Instrumenter` 注入点；
- 建议参考其 span 颗粒度：
  - run/turn span（一次 user exchange）
  - llm.call span
  - tool.call span（含 policy decision）
  - memory.search span

并把“默认不记录 raw args/results（安全）”作为默认策略（我们已有类似约束）。

## 6) 对 Cybros 的“直接可用”建议

如果把 OpenAI Agents SDK 当作“API 设计参考”，建议优先吸收：

1. **Agent 配置对象**：把“instructions/tools/guardrails/handoffs/model settings”从 app 逻辑里抽出
2. **Handoff 一等能力**：提供一个明确的“handoff tool/command”，在 DAG 中表现为：
   - 切换 runtime（同一 lane 的后续节点使用另一个 agent 配置）
   - 或 fork 子 lane/子图执行并把输出 merge 回主线
3. **Guardrails 分层**：至少补 tool input/output guardrails
4. **Structured output 终止条件**：提高“任务完成判定”的稳定性（尤其非 coding 任务）

## 7) Skills / MCP / tool calling：避免膨胀与提升稳定性的工程手段

这套 SDK 对“工具规模变大、工具结果变长、模型 tool calling 不稳定”的处理非常工程化，值得直接借鉴其做法（不必照抄 API）：

- **严格 JSON Schema**：提供 `ensure_strict_json_schema`（`src/agents/strict_schema.py`）把 schema 归一成 strict 形态（`additionalProperties: false`、展开 `$ref`、`oneOf→anyOf` 等），减少模型在 tool args 上的自由度，从而提高工具命中与可解析性。
- **MCP schema best-effort strict**：MCP spec 的 `inputSchema` 不一定有 `properties`，SDK 会补 `properties: {}`，并在配置打开时尝试 strict 转换（`src/agents/mcp/util.py`）。转换失败不会中断（降级为非 strict）。
- **工具输出裁剪（防 prompt 爆炸）**：`ToolOutputTrimmer` 是一个可插拔的 `call_model_input_filter`，会在“最近 N 轮”之外把过长的 tool outputs 替换为 preview（`src/agents/extensions/tool_output_trimmer.py`）。这是“只影响本次调用，不改历史”的典型实现。

## 8) 模型 workaround：承认 provider/模型返回不一致

- **call_id 形态不一致**：SDK 在多个地方用 `call_id || id` 做兜底（例如审批记录、run item 解析），并对“重复 call_id/type 或重复 item id/type”做去重合并（`src/agents/run_context.py`、`src/agents/run_state.py`）。这是应对不同 provider 在工具协议字段上的差异与 bug 的通用做法。
- **工具错误可降级为模型可见消息**：MCP tool 的 invoke 包装允许把异常转换成 tool_result（而不是直接 raise 终止整个 run），并把错误写入 tracing span（`src/agents/mcp/util.py`）。这对长任务的“局部失败可继续”很重要。
