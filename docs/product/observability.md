# 可观测性与用量统计（Draft）

本文档描述产品层需要暴露的统计、看板与审计数据，并把“统计到具体模型”作为硬要求之一。

---

## 0) 目标

- 用户可见：自己的用量（tokens/请求数）/延迟/错误率/主要 Agent 与工具使用情况。
- 系统可见：聚合视图 + 可配置限额（Phase 1 仅 volume/concurrency；rate 作为后续选项）。
- 统计粒度：至少到 **LLM Provider + Model**，并可按 agent/workflow/conversation/tool 维度切片。
- 可审计：关键操作与放权（权限、执行、网络）必须有 event 记录。

---

## 1) 用量统计的最小数据模型（建议）

每次 LLM 调用至少记录：

- `user_id`（谁触发）
- `space_id`（在哪个工作区发生）
- `agent_id` / `workflow_id`（谁执行）
- `agent_version`（例如 git commit SHA；用于可回放/可归因）
- `provider`
- `requested_model` / `used_model`（failover/修复回路可能导致使用模型与请求模型不同；统计应以 used_model 为准）
- `input_tokens` / `output_tokens`（或等价的计量）
- `cache_hit`（是否命中 prompt cache；可由 `cache_read_tokens > 0` 推导；若 provider 不提供则为 null，UI 展示为 unknown）
- `cache_read_tokens` / `cache_creation_tokens`（可选；来自 provider usage 细分，用于统计命中率与节省量）
- tool calling 质量信号（建议）：
  - `tool_calls_emitted_count`（模型尝试发起的 tool calls 数）
  - `tool_calls_parsed_count`（成功解析/通过 schema 校验的 tool calls 数）
  - `tool_calling_error_code`（若失败：parse/schema/mismatch 等稳定错误码；不记录原始输出）
- `latency_ms`
- `success` / `error_code`
- 关联 `conversation_id` / `dag_turn_id`（可追溯）

备注（隐私边界）：

- 用量统计仅记录 **计量数据**（tokens/耗时/错误等），不记录 prompt/response 的内容。

每次 tool/MCP/skill 执行至少记录：

- `user_id`
- `space_id`
- `tool_name` / `mcp_server`
- `latency_ms` / `success` / `error_code`
- 权限摘要（例如网络策略、文件读写范围、sandbox profile）

---

## 2) 用户看板（MVP 建议）

按用户提供以下最小视图：

- 今日/本周/本月：tokens、请求数、失败率、平均延迟
- Top models（按 tokens/请求数）
- Top agents / workflows（按 tokens/请求数/失败率）
- Tool calling：成功率（可解析 + schema 校验通过）、失败原因分布（稳定 error codes）
- 工具调用概览（tool/MCP 成功率、耗时）
- 执行环境概览（sandbox profile 使用占比、失败原因分布）
- 用户反馈（可选）：thumbs up/down（按 agent/workflow/model 切片）
- Prompt cache：命中率（hit rate）、cache read tokens（若可得）

补充（Space 视角）：

- 在 Space 内聚合展示：该 Space 的 tokens/请求数/失败率、Top agents/workflows、Top models。

---

## 3) 系统级统计与限额（Admin）

系统级需要：

- 聚合用量（全体用户、按用户排名）
- 限额策略配置：
  - per-user：每日 tokens / 并发执行数（Phase 1 不做 RPM 限额）
  - system-global：全局并发、危险能力开关（默认 sandbox、网络策略上限等）
- 审计浏览：
  - 谁修改了系统配置
  - 谁批准了高风险执行

---

## 4) 已确定的决策（Resolved）

- 成本：self-hosted 单租户下 **不维护 provider price table**，不做货币成本估算；仅统计 tokens/请求数/延迟/错误等。
- Retention：用量统计数据先保留 **1 年**；看板按日/周/月聚合展示（后续再讨论是否允许用户可配置 retention）。
- Prompt cache：尽可能做到 **可计量**（命中率与 cache tokens）；不计费（本阶段不做 cost/billing）。
- Prompt cache 计量缺失：当 provider 不提供 cached token 细分时，`cache_hit/cache_*_tokens` 记为 null（UI 展示为 unknown；不做猜测）。
- 限额（tokens）：按 “总 tokens（input+output）” 计量，但 **排除 `cache_read_tokens`**（若可得）；token quota 以 `input_tokens + output_tokens - cache_read_tokens` 为准（下限为 0；若 `cache_read_tokens` 不可得则按 `input_tokens + output_tokens` 计量）。
- RPM：Phase 1 **不做系统侧 RPM 限额**；当 provider 触发 rate limit（例如 429）时视为调用失败，由用户重试或程序按策略等待后重试；统计中记录请求数与错误码即可。（后续若引入 RPM，也不区分 cache hit vs non-cache）

## 5) Open questions

（暂无）
