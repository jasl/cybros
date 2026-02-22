# AgentCore Errors（错误体系）

本文档约定 `AgentCore` 域内错误类型的分层与“可分类捕获/可结构化日志”的字段设计。

---

## 1) 错误层级（Hierarchy）

- `AgentCore::Error < StandardError`：AgentCore 域内错误的统一捕获入口
- `AgentCore::ValidationError < AgentCore::Error`：**业务数据/入参校验失败**
  - 典型场景：tool 注册冲突、schema 不匹配、配置字段非法、技能文件路径非法等
  - 细分子类（用于可分支捕获；仍提供稳定 `code/details`）：
    - `AgentCore::Resources::Tools::ToolNameConflictError`：tool 名称冲突
    - `AgentCore::Resources::Skills::InvalidPathError`：skills 文件路径非法/越界
- `AgentCore::ConfigurationError < AgentCore::ValidationError`：运行时配置不合法/不完整（属于校验失败的一种）
  - 细分子类：
    - `AgentCore::MCP::ServerConfigError`：MCP ServerConfig 配置校验失败

> 约定：AgentCore 内显式抛出的“参数/业务数据不合法”统一使用 `AgentCore::ValidationError`（或子类），**不再使用 `ArgumentError`**。

---

## 2) `ValidationError#code`（稳定的分类码）

`AgentCore::ValidationError` 提供：

- `#code`：稳定分类码（String）
- `#details`：结构化补充信息（Hash）

约定：

- AgentCore 生产代码内显式 raise 的 `ValidationError` **必须提供 `code`**
- `code` 被视为 Public API：**一旦落地就应保持稳定**（后续可改 message，但不要改 code）
- 命名规范：小写点分层，带域前缀
  - 例如：`agent_core.mcp.server_config.timeout_s_must_be_positive`
  - 例如：`agent_core.skills.file_system_store.invalid_skill_file_path`

---

## 3) `ValidationError#details`（可用户可见的结构化信息）

`details` 的设计目标：未来可直接映射到用户可见日志/UI（或 LLM 自愈提示），因此必须遵守：

- **仅放可安全暴露的信息**（不要放 secrets、完整 payload、原始 tool args、HTTP body 等）
- 体积受控：只放必要字段；对可变长字符串需截断（建议 ≤ 200 bytes）
- 值类型以 JSON 友好为主：String/Number/Boolean/nil/Array/Hash（避免塞对象实例）

---

## 4) Tools：`ValidationError → ToolResult.error`

当 tool handler 抛出 `AgentCore::ValidationError` 时：

- `AgentCore::Resources::Tools::Tool#call` 会捕获并返回 `ToolResult.error`
- `ToolResult.metadata[:validation_error]` 会包含：
  - `class`：异常类名
  - `code`：分类码
  - `details`：结构化信息（应为 safe）

`tool_error_mode`：

- `:safe`：会包含 `ValidationError#message`（约定为可安全暴露，便于 LLM 修复）
- `:debug`：会额外包含异常类型等调试信息（仅建议在受控环境开启）
