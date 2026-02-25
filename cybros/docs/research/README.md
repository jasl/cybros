# 调研报告索引（docs/research）

更新时间：2026-02-25

本目录包含一组“对照调研”文档：基于 `references/*` 下的本地 clone 项目，梳理它们对 **Agent SDK**、**任务调度/运行时**、**Prompts/上下文管理/记忆系统** 的设计取舍，并映射到 Cybros 当前的 **DAG 引擎 + AgentCore（DAG-first）** 基础设施，回答两类问题：

1. 在我们现有基础上，是否能实现类似产品形态（做到什么程度）？
2. 若要做到，需要补哪些能力（优先级如何）？

> 注：以下调研以本仓库当前工作区里的代码为准（不是“互联网上最新状态”）。

## 总览与差距清单

- `docs/research/agent_sdk_landscape.md`：能力维度、跨项目共性模式、能力矩阵（含“Cybros 现状覆盖”）
- `docs/research/gap_analysis.md`：面向“可持续做实验”的补能力路线图（按优先级分层）

## 跨项目专题（新增补充）

- `docs/research/skills_mcp_tool_calling.md`：Skills/MCP/tool calling 膨胀治理、工具选择困难的工程解法
- `docs/research/model_workarounds.md`：模型在 tool calling/指令跟随不稳定时的合规 workaround（Runner/Schema/Prompt 视角）
- `docs/research/knowledge_management.md`：知识管理能力包（memory/lorebook/docs/citations）与落地顺序

## 单项目报告（references/*）

- `docs/research/ref_codex.md`：OpenAI Codex CLI（coding agent harness / sandbox / approvals / protocol）
- `docs/research/ref_claude_desktop_app.md`：Claude Desktop App（Cowork 形态、VM/沙箱、权限梯度、marketplace）
- `docs/research/ref_cli_tooling.md`：CLI 工具包（JSON-first CLI、approval/workflow shell、MCP runtime CLI、command allowlist）
- `docs/research/ref_opencode.md`：OpenCode（多 agent profiles、plan 模式、compaction、权限规则）
- `docs/research/ref_pi_mono.md`：Pi-Mono（四工具可编程 harness、JSONL tree sessions、扩展/技能包）
- `docs/research/ref_nanoclaw.md`：NanoClaw（Claude Agent SDK + 容器隔离 + 群组隔离记忆 + schedule）
- `docs/research/ref_openclaw.md`：OpenClaw（always-on 多渠道、系统 prompt 组装、memory/compaction/pruning）
- `docs/research/ref_bub.md`：Bub（严格命令边界、append-only tape、渐进式工具视图）
- `docs/research/ref_memoh.md`：Memoh（多 bot 管理、containerd 隔离、Mem0 风格“结构化长记忆”）
- `docs/research/ref_accomplish.md`：Accomplish（桌面 agent、文件权限 MCP、complete_task 约束、UI 隐藏标签）
- `docs/research/ref_desktopcommander_mcp.md`：Desktop Commander MCP（桌面能力 MCP、长进程/审计、Docker 隔离）
- `docs/research/ref_risuai.md`：Risuai（角色扮演聊天、lorebook、prompt order、Hypa/Supa 长期记忆）
- `docs/research/ref_tavern_kit_playground.md`：TavernKit Playground（SillyTavern-like，Rails prompt builder / lore / swipes / branching / runs）
- `docs/research/ref_openalice.md`：OpenAlice（file-driven、event log、cron、evolution mode、channels）
- `docs/research/ref_openmanus.md`：OpenManus（通用 agent PoC、MCP/run_flow）
- `docs/research/ref_a2ui.md`：A2UI（agent-driven UI 的声明式协议与 renderer 思路）
- `docs/research/ref_a2a.md`：A2A（Agent2Agent 协议：agent discovery / streaming / async）

## SDK/框架对照（可直接借鉴的 API 设计）

- `docs/research/ref_openai_agents_python.md`：OpenAI Agents SDK（Agent/Handoff/Guardrail/Session/Tracing）
- `docs/research/ref_claude_agent_sdk_python.md`：Claude Agent SDK（CLI harness 的 SDK 化、permission_mode、stream-json）

## 外部文章/观点（非 references 代码）

- `docs/research/ref_psm.md`：PSM（Persona Selection Model）与“工作流级 persona 切换”
- `docs/research/ref_claude_permissions.md`：Claude Code Permissions（permission modes + allow/ask/deny rules + wildcard patterns）
