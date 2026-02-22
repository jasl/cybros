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
  "tool_calls": [
    {
      "id": "...",
      "name": "...",
      "arguments": { "...": "..." },
      "arguments_parse_error": "invalid_json|too_large (optional)",
      "arguments_raw": "raw string preview (optional; only when parse_error exists)"
    }
  ],
  "stop_reason": "end_turn|tool_use|max_tokens|...",
  "model": "actual-model",
  "provider": "provider-name"
}
```

说明：

- `content`：用于 UI 展示的纯文本（`AgentCore::Message#text`）。
- `message`：完整 message roundtrip（multimodal / tool_calls 等）。
- `tool_calls`：冗余字段，便于 query/debug（同 `message.tool_calls`）。

### 1.3 metadata（`node.metadata`）

AgentCore 会在每次 LLM 调用写入 `metadata["context_cost"]`（成功与 `ContextWindowExceededError` 失败路径都有）：

```json
{
  "context_cost": {
    "context_window_tokens": 8192,
    "reserved_output_tokens": 0,
    "limit": 8192,
    "memory_dropped": false,
    "limit_turns": 12,
    "auto_compact": true,
    "estimated_tokens": { "total": 1234, "messages": 900, "tools": 334 },
    "estimated_tokens_coarse": {
      "tools_schema": 334,
      "tool_results": 120,
      "history": 700,
      "injections": 50,
      "memory_knowledge": 30
    },
    "decisions": [
      { "type": "drop_memory_results" },
      { "type": "prune_tool_outputs", "attempt": 1, "trimmed_count": 3, "chars_saved": 12000 },
      { "type": "shrink_turns", "limit_turns": 5 },
      { "type": "auto_compact", "triggered": false }
    ]
  }
}
```

说明：

- `estimated_tokens` 是最终 prompt 的估算（messages + tools）。
- `estimated_tokens_coarse` 是粗粒度拆分（不要求与 total 严格相加一致）。
- `decisions` 记录本轮为满足预算做过的降级决策（按发生顺序）。
  - `prune_tool_outputs.attempt`：同一轮内若多次 pruning（例如 shrink-loop 中反复尝试），attempt 递增。

当 LLM 调用触发 model failover（同 provider 多模型重试）时，会写入：

```json
{
  "llm": {
    "failover": {
      "requested_model": "primary-model",
      "used_model": "fallback-model",
      "attempts": [
        { "model": "primary-model", "ok": false, "status": 400, "error_class": "AgentCore::ProviderError", "error_message": "...", "elapsed_ms": 12.3 },
        { "model": "fallback-model", "ok": true, "elapsed_ms": 45.6 }
      ]
    }
  }
}
```

当 tool loop 触发工具参数修复（ToolCallRepairLoop）时，会写入：

```json
{
  "tool_loop": {
    "repair": {
      "attempts": 1,
      "candidates": 2,
      "candidates_total": 2,
      "candidates_sent": 2,
      "repaired": 1,
      "failed": 1,
      "skipped": 0,
      "failures_sample": [ { "tool_call_id": "tc_2", "reason": "missing_repair" } ],
      "model": "model-used-for-repair",
      "max_schema_bytes": 8000,
      "schema_truncated_candidates": 0
    }
  }
}
```

说明：

- `candidates` / `candidates_total`：本轮识别到的 repair 候选数量（包括 `arguments_parse_error` 与（可选）schema invalid 候选）
- `candidates_sent`：实际发送给 repair LLM 的候选数（受 `tool_call_repair_max_candidates` 限制）
- `max_schema_bytes` / `schema_truncated_candidates`：repair prompt 的 schema 体积治理统计

当 tool loop 触发工具名修复（ToolNameRepairLoop）时，会写入：

```json
{
  "tool_loop": {
    "tool_name_repair": {
      "attempts": 1,
      "candidates_total": 3,
      "candidates_sent": 2,
      "repaired": 1,
      "failed": 2,
      "skipped": 0,
      "model": "model-used-for-repair",
      "visible_tools_total": 250,
      "visible_tools_sent": 200,
      "visible_tools_truncated": true,
      "repairs_sample": [
        { "tool_call_id": "tc_1", "requested_name": "math_add", "repaired_name": "math_add_safe", "reason": "tool_not_in_profile" }
      ],
      "failures_sample": [ { "tool_call_id": "tc_2", "reason": "name_not_in_visible_tools" } ]
    }
  }
}
```

当 tool loop 发生工具名 alias/normalize 解析时（例如模型输出 `skills.list`，但 registry 中是 `skills_list`），会写入：

```json
{
  "tool_loop": {
    "tool_name_resolution": [
      {
        "tool_call_id": "tc_2",
        "requested_name": "skills.list",
        "resolved_name": "skills_list",
        "method": "alias"
      }
    ]
  }
}
```

当 tool args 能 parse 但不满足 schema（schema invalid），且修复未生效/被禁用时，会写入：

```json
{
  "tool_loop": {
    "invalid_schema_args": {
      "count": 1,
      "sample": [
        {
          "tool_call_id": "tc_1",
          "requested_name": "echo",
          "resolved_name": "echo",
          "errors_summary": "missing_required path=text expected=present"
        }
      ]
    }
  }
}
```

---

## 2) `task`

### 2.1 input（`body.input`）

由 tool loop 扩展阶段生成：

```json
{
  "tool_call_id": "tc_...",
  "requested_name": "llm_output_name",
  "name": "resolved_tool_name",
  "name_resolution": "exact|alias|normalized|repaired|unknown|missing",
  "arguments": { "string": "keys" },
  "arguments_summary": "safe json preview",
  "source": "native|mcp|skills|policy|invalid_args"
}
```

说明：

- `requested_name`：LLM 输出（用于审计）
- `name`：真实执行名（经过 alias/normalize 或 tool name repair 解析）
- `name_resolution`：工具名解析方式（用于审计/定位模型偏差）
  - `normalized` 覆盖大小写 / 驼峰 / 分隔符漂移（并映射回 registry 中的 canonical tool name）
  - `repaired` 表示发生了 ToolNameRepairLoop（只允许修到本轮可见工具名列表）
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
