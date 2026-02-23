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

AgentCore 内建的 policy 组合（可选）：

- `Policy::ConfirmAll`：工具可见，但所有执行默认进入审批（`awaiting_approval`）
- `Policy::DenyAllVisible`：工具可见，但所有执行默认拒绝
- `Policy::Profiled`：控制 tool schema 可见性（profile）
- `Policy::PatternRules`：按 tool name + arguments（path/url 等）规则化 allow/confirm/deny
- `Policy::Ruleset`：三段式规则（deny>confirm>allow，first-match-wins）
- `Policy::PrefixRules`：对 exec/shell 类工具按命令前缀 allowlist（用于持久化“已批准前缀”）
  - 注意：PrefixRules 仅基于 arguments 的字符串/数组做匹配；并不等价于 `execve` 拦截的强语义（若要达到 Codex 等级的保证，需要受控 runtime/MCP shell）。
- `Policy::ToolGroups`：`group:...` 展开（方便 profile/rules 引用工具集合）

可见性 vs 执行默认（常见组合）：

- `DenyAll`：隐藏工具定义 + 拒绝执行（safe-by-default）
- `ConfirmAll`：工具定义可见 + 默认需要审批（未命中 allow/deny 时进入 `awaiting_approval`）
- `DenyAllVisible`：工具定义可见 + 默认拒绝执行（未命中 allow 时直接拒绝）

### 1.1 Subagent tools（Cybros app 扩展）

Cybros 注册了 `subagent_spawn` / `subagent_poll` 两个 native tools（用于跨图子会话模式），但仍遵循 **deny-by-default**：

- runtime 默认 base policy 仍可保持 `Policy::DenyAll`，因此即便 `agent_profile` 为 `coding`（允许 `*`），tools 也不会自动暴露给模型。
- 当 app 注入的 base policy 允许时，`agent_profile` 会通过 `Policy::Profiled` 作为额外收敛层生效：
  - 未命中 profile 的工具会被拒绝（reason=`tool_not_in_profile`），并产出可审计的 tool_result。
  - 这不会扩大原有授权边界（只会更严格）。

当前默认限制：

- 禁止 nested spawn：subagent 会话内调用 `subagent_spawn` 会直接返回校验错误。
- `subagent_poll` 做 bounded 输出：`limit_turns` 最大 50，且 transcript 单行会做 bytes 截断（预览用途）。
- `subagent_poll` 当前按 conversation id 直接读取，不做 parent ownership 校验；如需更强隔离，应在工具层增加校验或通过 policy/ACL 限制工具可用性。

建议后续加强（未落地）：

- `subagent_poll` 增加 parent ownership 强校验：读取 child `conversations.metadata["subagent"]["parent_conversation_id"]` 并与当前会话一致，否则拒绝（避免越权读取）。
- 对 `child_conversation_id` 做 UUID 格式校验（fail-fast，减少数据库层异常噪声）。
- 对 `subagent_spawn` 增加配额/速率限制（conversation/user/account scope 均可；以审计可回放为前提记录拒绝原因）。
- 可选提供更高层编排原语（`subagent_run`/`subagent_cancel`/`subagent_kill`），但需要先定清语义（阻塞/超时/幂等/审计字段）。

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
- `ToolResult.metadata[:validation_error]`：
  - 当 tool handler 抛出 `AgentCore::ValidationError` 时，Tool 会返回 `ToolResult.error`，并在 metadata 中附带 `{class, code, details}`（均应为 safe，可用于用户可见日志/结构化展示）。

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
