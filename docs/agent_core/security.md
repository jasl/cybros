# AgentCore（DAG-first）安全与隐私约束

本文档描述 `AgentCore` 在工具调用、MCP、Skills、记忆系统与可观测性方面的安全边界与默认策略。

---

## 1) 默认 deny-by-default（工具可见性与执行）

`AgentCore::DAG::Runtime` 默认：

- `tool_policy = AgentCore::Resources::Tools::Policy::DenyAll`

这意味着：

- LLM prompt 不会暴露任何 tool definitions
- tool loop 即便解析到 tool_calls，也会被 policy 拒绝并写入 tool_result error（而不是执行）

产品层应显式注入 allow/confirm/deny policy。

---

## 2) Tool arguments / results（敏感数据）

风险：

- tool arguments 可能包含凭据、文件内容、用户隐私
- tool results 可能非常大，且可能包含 secrets

当前实现的默认约束：

- `Messages::Task` 节点的 `arguments_summary` 是 **截断后的 JSON 预览**（避免落库/日志中出现超大参数）
- `TaskExecutor` 对 tool result 做 bytesize 限制（默认约 200KB），超限会截断并在 result.metadata 标记 `truncated=true`
- `ContextBudgetManager` 在超预算路径下可对“旧 tool outputs”做 prompt-view 裁剪（`ToolOutputPruner`），不写回 DAG 历史
- `tool_error_mode`：
  - `:safe`（默认）：不包含堆栈；非校验类异常默认不包含 message（仅类型）。`AgentCore::ValidationError` 会包含 message（约定为可安全暴露，便于 LLM 自愈）。
  - `:debug`：错误文本包含异常类型与 message（仅建议在受控环境开启）

---

## 3) Skills 文件访问安全

`FileSystemStore` 提供：

- realpath 校验（防止 symlink 逃逸）
- rel_path 白名单（仅允许 `scripts/`、`references/`、`assets/` 且单层文件）
- size cap（读取字节上限）

Skills tools（`skills_read_file`）在任何异常时返回 `ToolResult.error`，不会抛出未捕获异常导致 worker 崩溃。

---

## 4) MCP 安全边界

- MCP tool names 默认通过 `server_id` + `remote_tool_name` 映射为本地安全名（`mcp_{server}__{tool}`），避免冲突与非法字符。
- MCP tool 执行异常会被 registry 捕获并转换为 `ToolResult.error`（不会把异常直接抛给 DAG Runner）。

---

## 5) 媒体 URL sources 默认禁用

`AgentCore::ImageContent/DocumentContent/AudioContent` 支持 `source_type: :url`，但默认：

- `AgentCore.config.allow_url_media_sources = false`

如需开启，应在 app 层显式配置并提供额外的 URL 校验策略（scheme allowlist、host allowlist、大小限制等），避免 SSRF / 任意下载风险。

---

## 6) Observability / Tracing

`AgentCore::Observability` 默认不记录 raw tool args/results。

建议：

- 只在 debug/受控环境记录更详细 payload
- 对可观测事件做 redaction（尤其是 tokens、API keys、文件内容）
