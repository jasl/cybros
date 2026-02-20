# AgentCore（DAG-first）Node Payloads（Schema）

本文档规范 `agent_message/character_message` 与 `task` 节点的 `body.input/body.output/metadata` 结构，便于查询、调试与跨组件协作。

约定：

- DAG 持久化边界（`dag_node_bodies.input/output/output_preview/metadata`）统一使用 **String keys**。
- executor 内部可用 symbol，但写入前需要 stringify（NodeBody/Runner 已统一处理）。

---

## 1) `agent_message` / `character_message`

### 1.1 input

当前不依赖固定 input schema（由 app/产品层扩展）。

### 1.2 output（`body.output`）

由 `AgentCore::DAG::Executors::AgentMessageExecutor` 写入：

```json
{
  "content": "final display text",
  "message": { "role": "assistant", "content": "...", "tool_calls": [ ... ] },
  "tool_calls": [ { "id": "...", "name": "...", "arguments": { ... } } ],
  "stop_reason": "end_turn|tool_use|max_tokens|...",
  "model": "actual-model",
  "provider": "provider-name"
}
```

说明：

- `content`：用于 UI 展示的纯文本（`AgentCore::Message#text`）。
- `message`：完整 message roundtrip（multimodal / tool_calls 等）。
- `tool_calls`：冗余字段，便于 query/debug（同 `message.tool_calls`）。

---

## 2) `task`

### 2.1 input（`body.input`）

由 tool loop 扩展阶段生成：

```json
{
  "tool_call_id": "tc_...",
  "requested_name": "llm_output_name",
  "name": "resolved_tool_name",
  "arguments": { "string": "keys" },
  "arguments_summary": "safe json preview",
  "source": "native|mcp|skills|policy|invalid_args"
}
```

说明：

- `requested_name`：LLM 输出（用于审计）
- `name`：真实执行名（包含 `.`→`_` fallback 解析）
- `source`：来源分类（用于可观测/安全策略）

### 2.2 output（`body.output`）

`Messages::Task` 的 output 约定为：

```json
{
  "result": {
    "content": [ { "type": "text", "text": "..." } ],
    "error": false,
    "metadata": { }
  }
}
```

其中 `result` 等价于 `AgentCore::Resources::Tools::ToolResult#to_h`。

### 2.3 审批元数据（`task.metadata["approval"]`）

当 policy decision 为 `confirm`：

```json
{
  "approval": {
    "required": false,
    "deny_effect": "block",
    "reason": "needs_approval"
  }
}
```

说明：

- `required=false`：optional approval（deny 后仍可继续下游 agent）
- `required=true && deny_effect="block"`：required approval gate（dependency edge）

---

## 3) Streaming（output_delta）

当 LLM 使用 streaming：

- `AgentMessageExecutor` 通过 `DAG::NodeEventStream#output_delta` 写入增量
- `DAG::Runner` 在 `finished(streamed_output: true)` 情况下：
  - 从 node events 聚合得到最终 content
  - 同时写入 payload（output hash）
  - `Messages::AgentMessage` 的 `output_preview` 会随 delta 更新（用于 UI 预览）
