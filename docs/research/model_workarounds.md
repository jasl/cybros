# 模型 workaround 总结（tool calling / 指令跟随 / Playground“破限”）

更新时间：2026-02-21  
调研来源：`docs/research/ref_*.md`（OpenAI Agents SDK、OpenCode、OpenClaw、Claude Agent SDK、Codex、Memoh、Risuai 等）

本篇总结“模型天生不稳定”时，业界常用的工程 workaround。重点是**提升可靠性与可控性**，不是绕过系统安全策略。

> 说明：本文只讨论合规、可产品化的工程做法；不提供任何“越狱/绕过安全限制”的可操作提示词模板。

## 1) 常见失败形态（要先能分类，才能治理）

### 1.1 tool calling 相关

- **参数不符合 schema**：类型错/漏必填/多余字段/非 JSON（strict schema 能显著缓解）。
- **call_id/字段形态不一致**：不同 provider 或不同 SDK 返回 `call_id` vs `id`，甚至重复或缺失（OpenAI Agents SDK 有大量兜底）。
- **tool message 协议错误**：裁剪上下文后出现 orphan tool message（Memoh resolver 专门规避）。
- **工具过多导致选择困难**：同类工具重叠、描述相似，模型随机/误选（需要 profiles + 分层暴露）。
- **工具输出过大**：把搜索结果/日志/截图 base64 回灌到 prompt，导致下一轮 400 或模型注意力被淹没（需要外移+裁剪）。

### 1.2 指令跟随/任务闭环相关

- **过早结束**：没有真正完成就“宣布完成”（Accomplish/OpenCode 用 complete_task/blocked/partial 之类协议约束）。
- **忽略关键步骤**：不跑测试、不验证、不解释阻塞原因（需要流程协议 + 运行时检查点）。
- **长对话漂移**：中途忘记目标或偏离（需要摘要、预算、以及必要的状态回填/记忆检索）。

## 2) Prompt 级 workaround：少即是多

跨项目经验非常一致：可靠性往往来自“减少歧义”，而不是塞更多规则。

- **结构化章节 + promptMode**：主 agent 用 full，子 agent 用 minimal/none（OpenClaw）；减少无关章节能显著提升指令跟随。
- **限制工具集合**：默认只暴露 minimal toolset，需要时再升级（OpenClaw/OpenCode/Codex 的 profile/policy 思路）。
- **显式停机条件**：要求输出 `success|blocked`，并在 blocked 时必须说明缺什么（OpenCode/Accomplish 风格）。
- **把“不可见协议”与“用户可见文本”分离**：用机器可读块承载状态/元信息，UI 侧 sanitize（Accomplish）。这能避免模型为了“写给用户看”而破坏协议。

## 3) Schema/工具级 workaround：用严格化降低自由度

- **strict JSON schema**：对 function tools/MCP tools 做 `additionalProperties: false`、必填字段补齐、`oneOf→anyOf` 等规整（OpenAI Agents SDK、OpenCode）。
- **MCP schema best-effort 修复**：MCP 的 `inputSchema` 可能缺 `properties`；可自动补 `properties: {}` 并在失败时降级为非 strict（OpenAI Agents SDK）。
- **工具输出“重内容外移”**：大输出落盘/对象存储，仅回传摘要+指针；图片/截图走附件而非 base64 文本（OpenCode、Accomplish）。

## 4) Runner/运行时 workaround：自愈比“再提示一次”更可靠

当模型/Provider 不稳定时，单纯加提示词往往不够；需要 Runner 层兜底：

- **解析-校验-纠错回路**：tool args 校验失败时，生成结构化错误并要求模型“仅修正参数”重试（限制重试次数，避免死循环）。
- **call_id/事件去重与归一**：兼容 `call_id||id`，并对重复 item/call 去重合并（OpenAI Agents SDK 的 run_state 思路）。
- **工具失败可降级**：将非致命异常转换为模型可见的 tool_result（而不是直接 raise 终止），并写入 tracing（OpenAI Agents SDK 的 failure_error_function）。
- **模型/鉴权 failover**：把 tool 协议错误/invalid-request 也纳入可 failover 的错误类型（OpenClaw 的 model failover 处理思路），在 tool calling 不稳定时自动切换到更可靠的模型。

## 5) Playground“破限”：建议把它当作“实验开关”，不是越权

Playground 常见的“破限”需求，很多其实是想突破**产品默认约束**而非安全边界。可产品化的做法包括：

- **预算开关**：提高 `max_output_tokens`、关闭某些自动裁剪、开启/关闭 tool output trimming（成本/延迟提示）。
- **工具集开关**：按 profile 切换工具集合（minimal→full），并对高风险工具保持审批（安全提示）。
- **协议开关**：切换“严格输出模式”（JSON schema / tool-only）与“自由对话模式”（便于调试）。
- **可观测开关**：显示 context cost report、显示每轮注入的 tools/skills/记忆片段（帮助用户调参而不是猜）。

不建议把“破限”做成“绕过系统安全策略”的提示词注入入口；应保持系统/开发者约束优先，并对用户自定义区块做注入风险防护。

## 6) 给 Cybros 的最小落地建议（与现有底座对齐）

结合 Cybros 已有的 DAG 审计与 tool_policy，优先补齐的 workaround 能力：

1. `StrictJsonSchema`（tools/MCP）：规整 schema，提高 tool args 命中率  
2. `ToolOutputPruner`：只影响本次 prompt 的 tool outputs 裁剪（保护最近 N turns）  
3. `ToolCallRepairLoop`：工具参数校验失败→结构化错误→有限次重试  
4. `ProviderFailover`：把 tool 协议错误纳入可 failover 的错误域，并记录可观测事件  
5. `ProtocolSanitizer`：机器协议块与 UI 文本分离（必要时）
