# 对照调研：Claude Agent SDK（references/claude-agent-sdk-python）

更新时间：2026-02-21  
调研对象：`references/claude-agent-sdk-python`  
参考版本：`0e9397e052ec`（2026-02-18）

## 1) 这套 SDK 的本质：把“Claude Code CLI harness”SDK 化

Claude Agent SDK（Python）并不试图自己实现完整的 agent loop；它的核心是：

- 通过 subprocess 启动 **Claude Code CLI**
- 使用 `--output-format stream-json` 读取流式事件，并用 `--input-format stream-json` 通过 stdin 发送控制协议（initialize/hooks/agents 等）
- 把 CLI 的 message/tool-use/tool-result 解析成 SDK 的 `Message` 流
- 暴露一套 options（cwd、system_prompt、allowed_tools、permission_mode、模型选择、mcp servers…）

换句话说：这是一种“把成熟的本地 agent harness（Claude Code）当作一个可嵌入 runtime”的方法论。

对 Cybros：这对我们很重要，因为我们也可以把 Codex CLI / Claude Code / OpenHands 等外部 harness 作为 **一种 executor/runtime** 接入 DAG，而不是在 Rails 进程里直接执行所有工具。

## 2) 核心接口与参数（permission_mode 很关键）

从 `src/claude_agent_sdk/query.py` 与 `SubprocessCLITransport` 可见：

- `query(prompt, options)`：一次性/单向流式交互（stateless）
- `ClaudeAgentOptions` 常用项：
  - `cwd`：工作目录
  - `system_prompt`：可为空、可 preset append
  - `allowed_tools` / `disallowed_tools`：工具白/黑名单
  - `permission_mode`：
    - `default`：危险工具提示用户
    - `acceptEdits`：自动接受文件编辑（高风险）
    - `bypassPermissions`：允许所有工具（极高风险）
  - `mcp_servers`：把 MCP servers 交给 CLI 管理（SDK 仅负责透传）
  - `settings`/`sandbox`：可合并成 JSON settings 传给 CLI（transport 里有 merge 逻辑）

这套参数面体现了“安全与 UX”优先：

- 工具允许范围应该可控（allowed_tools）
- 写文件/执行命令应该能切换审批策略（permission_mode）

## 3) stream-json 的价值：可观测与可回放

`SubprocessCLITransport` 的实现要点：

- CLI 启动参数固定加 `--output-format stream-json --verbose --input-format stream-json`
- **总是先发 initialize request**：SDK 会把 agents/hook 配置通过 stdin 的 initialize 控制请求发送（而不是塞进 CLI 参数），这是避免“配置过大/命令行长度限制/复杂转义”的关键 workaround（transport 里也明确注释 *agents are always sent via initialize request*）。
- 读取 stdout 的 JSONL 流并解析；stderr 独立消费
- buffer size 可配（避免输出太大卡死）

这意味着：

- 外部 harness 的每一步都可以被结构化记录（message/tool-call/tool-result）
- SDK/宿主应用可以把这些事件“落库/展示/审计”

对 Cybros 的映射：

- DAG 的 node events 很适合承载这种“结构化流事件”
- 我们可以实现一个 executor：运行外部 CLI，把 stream-json 事件映射为：
  - `task` 节点的 output_delta（可见）
  - 或 `node_event` 的 tool_call_start/tool_call_end（机器可读）

## 4) 对 Cybros 的两条集成策略

### 策略 A：把 Claude Code 当作“外部 Provider/Runner”

做法：

- 新增一个 node_type（或 task 工具）：`external_agent_run`
- executor 启动 claude CLI（或通过容器启动），消费 stream-json
- 将最终输出写回 DAG，并把过程事件写入 node events（便于 UI 回放）

收益：

- 快速获得 Claude Code 的成熟工具生态（读写/exec/权限/沙箱）
- 主 Rails worker 不需要承担执行安全边界

代价：

- 与 Claude harness 强耦合（工具协议、权限模式、更新节奏）
- 与我们自己的 AgentCore tool registry 可能重复（需要清晰分层：哪些任务走外部 harness）

### 策略 B：仅借鉴其“transport + permission model”

做法：

- 我们继续用 AgentCore 运行 tool loop，但补齐：
  - `permission_mode` 等价能力（tool policy profiles + 审批）
  - stream 事件模型（turn/step/tool-call）
- 只有在需要强沙箱/桌面能力时，才引入外部 harness

## 5) 借鉴要点总结

- 把成熟 harness SDK 化，是“以小搏大”的工程策略：能快速拿到安全沙箱、工具集、权限模型
- stream-json 事件流是连接“运行时”与“DAG 审计/UI 回放”的最佳接口形态
- permission_mode 的三档开关（default/acceptEdits/bypassPermissions）值得在我们的 policy/profile 里抽象出来（默认安全）

## 6) 补充：Hooks/MCP 作为“workaround 注入点”

- `ClaudeAgentOptions` 支持 hooks（PreToolUse/PostToolUse/PermissionRequest/PreCompact/Stop…），让宿主在工具调用前后做改写/拦截/打标（见 `src/claude_agent_sdk/types.py`）。这是一类非常实用的工程入口：当模型在 tool calling、输出格式、或权限请求上不稳定时，可以在 hook 层做“修正与降级”。
- `mcp_servers` 支持 SDK in-process server（`type: "sdk"`）与外部 server，并在传给 CLI 前剥离 instance 字段（见 `SubprocessCLITransport` 的 mcp_config 处理）。对 Cybros 来说，这意味着我们可以把“自研 MCP server（在进程内）”与“外部 MCP server”统一为同一种工具来源，再用 policy/profile 控制可见性与审批。
