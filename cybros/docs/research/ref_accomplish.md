# 参考项目调研：Accomplish（references/accomplish）

更新时间：2026-02-24  
调研对象：`references/accomplish`  
参考版本：`b693e9df`（2026-02-24）

## 1) 项目定位与核心形态

Accomplish 是一个桌面端 AI agent：在本机执行文件管理、文档生成、浏览器自动化等任务。产品主张：

- 本地运行、用户自带 API key 或本地模型
- 用户对每个动作可审批、可停止、可查看日志
- 通过“工具连接”（本地 API、云服务、本地浏览器）来做自动化

对 Cybros：Accomplish 的核心价值是“桌面/浏览器自动化 + 审批 UX”。其中“桌面/浏览器”属于 L3 runtime，“审批与协议化工具调用”属于 P0/P1 能力。

## 2) Prompts/协议：complete_task 约束与隐藏标签

Accomplish 在 `packages/agent-core/src/opencode/*` 中大量借鉴（或直接集成）OpenCode 风格协议：

- `completion/prompts.ts`：强调“不要过早 complete_task；要么 success，要么 blocked；partial 只能被迫”
- `config-generator.ts`：生成一个包含 MCP 工具说明、行为约束的系统 prompt 模板
  - 包含 `request_file_permission` MCP tool：文件操作前必须先请求权限
  - 强制“用户看不到你的文本输出”时，必须用 `AskUserQuestion` MCP tool 询问（典型桌面 app UX 需求）
- `message-processor.ts`：对 UI 展示做 sanitize
  - 移除 `<instruction>/<nudge>/<thought>/<scratchpad>/<thinking>/<reflection>` 等内部标签
  - 移除 `context_management_protocol` 等内部行
  - 工具输出里提取 base64 screenshot，作为附件展示

对 Cybros 的启发：

- “内部标签/协议行”是很多桌面 agent 里常见的做法：模型输出包含机器可读段落，UI 只展示 sanitize 后文本
- Cybros 的 DAG node content/payload 可以天然承载“可见文本 vs 机器协议段”：
  - 可见文本：`agent_message.content`
  - 机器协议/调试信息：`node.payload`/`node.metadata`
- 如果未来要做“桌面 agent”实验，建议：
  - 明确一套“机器可读块”的语法（XML tags 或 JSON blocks）
  - 在 agent executor 层解析为结构化 payload，UI 层只渲染 sanitize 结果

## 3) 工具与审批：file permission MCP 是关键

Accomplish 的核心安全策略之一：**写文件前必须通过 `request_file_permission`**（MCP server 提供）。

这与 Cybros 现有能力的关系：

- Cybros 已有 `tool_policy.confirm(required:, deny_effect:)` → `awaiting_approval`；
- file permission MCP 更像“把审批细化到资源级（路径/操作类型）”，并且审批逻辑在 UI/应用层实现；
- 推荐的实现方式是把“文件系统工具”本身做成受控工具，并在 `authorize` 里：
  - 允许读类操作
  - 写/删/覆盖 → confirm(required: true, deny_effect: :block)

> 也可以像 Accomplish 一样用 MCP 提供一个 permission tool，但在 Cybros 内部直接用 tool_policy 更简洁，审计也更统一。

## 4) 浏览器自动化：MCP + Playwright

Accomplish 的 agent-core 下存在 `mcp-tools/dev-browser`（Playwright）与 UI 截图解析逻辑，说明它把浏览器视为一个可控工具面（而不是让模型直接“想象网页”）。

对 Cybros：

- 我们已经支持 MCP client 工具注册；
- 因此“浏览器工具”优先建议走 MCP（Playwright server / chrome bridge），并把截图作为 tool_result 附件写入 DAG 事件/节点输出。

## 5) Context 管理：内部标签与 prunable-tools

`message-processor.ts` 里对 `context_management_protocol`、`<prunable-tools>` 做过滤，暗示其 prompt 中存在“可裁剪工具集合/协议”。

对 Cybros：

- 我们需要一个通用的 context pruning 层（P0），并把 pruning 发生与否记录在 metadata（便于调试与 UI 提示）。

## 6) 在 Cybros 上实现的可行性评估

### 能做到（底座覆盖）

- tool loop + 审批 gate（awaiting_approval）
- MCP 浏览器工具（通过 AgentCore tools_registry）
- 机器协议块解析与 UI sanitize（通过 payload/metadata 实现更干净）

### 需要额外投入（产品/运行时）

- 桌面端（macOS/Windows）与系统权限（文件系统沙箱、可访问目录选择）
- 浏览器绑定（用户本机 Chrome profile / 自动化权限）

## 7) 借鉴要点总结

- “complete_task/blocked/partial”这类协议对桌面 agent 很重要：因为 UI/后台需要知道任务是否真正结束
- 工具输出的“截图→附件”是桌面 agent 的关键体验点：建议把附件作为一等内容类型落到 DAG 节点输出/事件里
- 文件权限最好做成 policy 引擎（按操作与路径），而不是零散的“每次问”

## 8) Skills / MCP / tool calling & 模型 workaround：补充观察

- **工具输出不要把“重内容”塞回 prompt**：Accomplish 把 screenshot 从 tool output 中提取为附件，并把 UI 可见文本 sanitize/截断（见 `packages/agent-core/src/opencode/message-processor.ts`）。这类“重内容外移”是避免上下文被工具结果挤爆的通用解法。
- **用“机器协议块”做模型 workaround**：通过 `<instruction>/<nudge>/<thought>...` 等隐藏标签承载机器可读信息，并在 UI 层剥离展示，可以在不牺牲可用性的前提下，提高 tool loop 的稳定性（但要避免把这类标签暴露给用户造成误解）。
