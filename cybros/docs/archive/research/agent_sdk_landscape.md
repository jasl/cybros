# Agent SDK / Context / Memory 设计版图（对照调研）

更新时间：2026-02-21

本文把 `references/*` 中列出的项目抽象成一组“能力维度”，并对照 Cybros 当前的 **DAG 引擎 + AgentCore（DAG-first）** 现状，给出：

- 各项目的关键设计模式（尤其：Prompts / 上下文 / 记忆 / 调度 / 安全）
- 跨项目共性能力清单（作为“平台化实验底座”的最小集合）
- 一张“能力矩阵”（用于快速判断：要复刻某个项目形态，缺什么）

另见三篇跨项目专题（更偏工程细节）：

- `docs/research/skills_mcp_tool_calling.md`
- `docs/research/model_workarounds.md`
- `docs/research/knowledge_management.md`

## 0) Cybros 当前底座（作为对照基线）

本仓库当前已经具备的、与本次调研直接相关的能力（只列“承载实验”的核心）：

- **DAG 引擎（Lane-first）**
  - 节点/边/状态/不变量：`docs/dag/behavior_spec.md`
  - App-safe 读写边界：`docs/dag/public_api.md`
  - 调度/执行：Solid Queue + `DAG::Scheduler`/`DAG::Runner`（节点 lease、SKIP LOCKED、streaming events）
  - 版本/重试/可见性：node commands（retry/rerun/adopt/edit/exclude/soft_delete/approve/deny/stop）
- **AgentCore（DAG-first）**
  - Runtime 注入点：`docs/agent_core/public_api.md`（provider/tools/skills/memory/injections/budget/observability）
  - Tool loop：`agent_message → task* → next agent_message`，并支持 `awaiting_approval` gate
  - Context 预算 + auto_compact：`docs/agent_core/context_management.md`
  - Memory store（pgvector）：`lib/agent_core/resources/memory/pgvector_store.rb`（按 conversation/global scope）
  - Prompt injections（FileSet/RepoDocs/TextStore/Provided）：`lib/agent_core/resources/prompt_injections/sources/*`
  - MCP tools + Skills tools：`docs/agent_core/public_api.md`（registry.register_mcp_client / register_skills_store）
  - 默认安全边界：deny-by-default tool policy、tool args/result 截断、URL media 禁用等：`docs/agent_core/security.md`
- **Subagent（跨图）推荐建模**
  - `docs/dag/subagent_patterns.md`：subagent = 独立 Conversation/Graph，父图保存 child 引用并用 bounded read 汇总

结论：**“工具循环 + 上下文预算 + 压缩 + 审批 + 可观测事件”** 这一类底层能力已经到位；后续补能力更多集中在“更细的权限/策略”“更强的记忆与检索”“跨渠道与隔离运行时”“产品级 prompt builder 组件化”。

## 1) 能力维度（从 references 项目归纳）

为了比较，我们把能力拆成 10 个维度（每个维度在不同项目里可能以不同形式出现）：

1. **Agent Loop / Turn Model**：一轮 LLM 调用如何与 tool calls 交织？如何停止？是否支持 handoff/subagent？
2. **Tool Registry & Policy**：工具注册、工具可见性、允许/拒绝/确认（ask/confirm）、规则持久化（prefix rule / allowlist）、资源级权限（路径/域名/网络）
3. **Human-in-the-loop**：审批 UX（awaiting approval）、“拒绝后是否阻塞下游”、如何恢复、如何记录审计
4. **Prompt Assembly**：system prompt 结构化、prompt mode（full/minimal）、bootstrap 文件注入、动态 header（时间/渠道/能力）、隐藏标签（thought/nudge）
5. **Context Windowing**：按 turn/message/时间窗口取历史、token 预算、工具结果截断、工具结果 pruning（软/硬清理）
6. **Compaction / Summarization**：超预算时如何总结历史；是否持久化；是否可“继续工作”而不是结束
7. **Memory / Knowledge Management（长期记忆 / RAG / Lorebook / Docs）**：存储介质（Markdown/DB/向量库）、写入策略（自动 flush / mem0 add-update-delete）、检索策略（vector/BM25/hybrid/时间衰减）、引用/citation、规则触发注入（lorebook/world info）、docs 检索
8. **Subagents / Teams**：代理分工、受限工具集、上下文隔离、聚合结果、并发与配额
9. **Scheduling / Automations**：cron/周期任务、幂等、并发约束、取消、通知回传
10. **Runtime Isolation & Channels**：容器/沙箱/网络策略、外部渠道（Telegram/WhatsApp/Discord）、浏览器/桌面自动化、附件与多模态

## 2) 跨项目共性模式（值得平台化）

### 2.1 Prompt 不是“一段字符串”，而是“可组合的结构”

出现频率最高的做法：

- 固定章节（Tooling / Safety / Memory / Workspace / Time / Messaging / Docs）+ 运行时条件开关（promptMode、tool availability）
- “Bootstrap 文件”注入：AGENTS/TOOLS/IDENTITY/USER/MEMORY 等（OpenClaw、OpenCode、Bub、Memoh、TavernKit）
- 把“动态内容”放在 prompt 末尾，尽量保持 prefix 稳定（Memoh 明确把静态/动态分段）
- prompt 稳定性作为可测试对象（OpenClaw 有 system prompt stability tests）

### 2.2 Context 成本主要来自两类：工具 schema + 工具结果

常见治理手段：

- **工具 schema 渐进展开**（Bub）：先给 compact tool view，需要时再 describe
- **工具结果截断 + pruning**（OpenClaw session pruning、OpenCode prune old tool parts）
- **成本可观测**：把 system prompt / injected files / tool schemas / tool results 的体积拆解成报告（OpenClaw `/context detail`）
- **strict schema 规整**：把 tools/MCP schemas 规整为 strict（additionalProperties=false 等），降低 tool args 失败（OpenAI Agents SDK、OpenCode）
- 把“系统指令/规则”从对话历史里剥离（system prompt + injected context files）

### 2.3 Memory 体系通常分层

常见的 2~3 层：

- **Always-injected**：短小的长期偏好/身份（OpenClaw 的 `MEMORY.md`；Memoh 的 IDENTITY/SOUL/TOOLS）
- **Retrieval-on-demand**：`memory_search`/`memory_get`（OpenClaw），或 query 时注入少量相关片段（Memoh）
- **Pre-compaction flush**：在压缩前提醒把“耐久信息”写入 memory（OpenClaw）
- 更进阶：mem0 风格“结构化记忆管理”（Memoh：ADD/UPDATE/DELETE + compact + time decay）
- roleplay 域的变体：lorebook/world info 作为“规则驱动知识注入引擎”（Risuai/TavernKit）

### 2.4 Subagent 不是“多模型调用”，而是“受限上下文 + 受限工具 + 可回放”

- OpenCode / Memoh：subagent 有自己的上下文存储与可控工具集
- NanoClaw：通过 Claude Agent Teams（swarms）在容器内编排
- DAG-first 的优势：可以把 subagent 作为独立图（天然审计/重试/压缩）

## 3) 能力矩阵（参考项目 → 关键诉求 → Cybros 覆盖）

符号约定：

- ✅：现有底座基本覆盖（主要是 app wiring/产品层工作）
- 🟡：需要补一个“平台能力”（AgentCore/DAG 的 API 或内建组件）
- 🔴：需要新增“运行时/产品形态”（容器/桌面/渠道），不是纯 SDK 能解决

| 项目 | 主要形态 | 工具+审批 | Context/压缩 | 长期记忆 | Subagent/Teams | Cron/Schedule | Channels/UI | 隔离/沙箱 | Cybros 覆盖结论 |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| Codex CLI | coding agent harness | ✅（审批/工具循环） | ✅（token budget/compact） | 🟡（更像“会话总结/书签”） | 🟡（多线程/多 session） | 🔴 | 🔴（CLI/TUI） | 🟡/🔴（强沙箱+execve 拦截） | 核心 loop 可复刻；强沙箱/规则与 CLI UX 需额外工程 |
| OpenCode | coding agent（多 profiles） | 🟡（规则化权限/plan 模式） | ✅（compaction+prune） | 🟡（memory 文件约定） | ✅/🟡（explore 子 agent） | 🟡 | 🔴（CLI/desktop/web） | 🟡 | 需要更细 tool policy + profile；其余可映射 DAG/AgentCore |
| NanoClaw | 个人助手（Claude + 容器） | 🔴（依赖 Claude Code harness） | 🟡（会话/组隔离） | 🟡（CLAUDE.md + auto memory） | 🔴（Claude Teams） | 🟡 | 🔴（WhatsApp） | 🔴（容器隔离是核心） | 需要“容器化运行时 + 渠道适配”，SDK 仅覆盖一部分 |
| OpenClaw | always-on 多渠道助手 | 🟡（tool groups + owner-only） | ✅（compaction + pruning） | ✅/🟡（Markdown + vector + flush） | 🟡（subagents 工具） | ✅/🟡 | 🔴（Gateway + WebSocket + apps） | 🟡/🔴 | Prompt/Memory/Context 模式高度可借鉴；渠道与 runtime 是大头 |
| Bub | coding agent（tape-first） | ✅（显式命令边界） | 🟡（handoff 缩短历史） | 🟡（tape/search） | 🟡（skills/提示扩展） | 🟡 | 🔴（CLI） | 🟡 | DAG 本身就是“可回放 tape”；可借鉴渐进工具视图与 anchor/handoff |
| Memoh | 多 bot SaaS（容器 + 长记忆） | 🔴（容器/GUI/多渠道） | 🟡（24h window + tokens） | 🔴（mem0 + hybrid retrieval） | 🟡（subagent API） | ✅ | 🔴 | 🔴（containerd） | Memory 系统最值得抄；要做产品需容器与渠道，SDK 需补记忆能力 |
| Accomplish | 桌面自动化 agent | 🟡（file permission MCP） | 🟡（隐藏标签/协议） | 🟡（task summary） | 🟡 | 🟡 | 🔴（桌面 app） | 🔴（OS 权限） | SDK 能承载其工具循环与审批；桌面/浏览器自动化需产品侧投入 |
| Risuai | 角色扮演聊天/插件 | 🟡（提示构建器复杂） | ✅（Hypa/Supa） | ✅（Hypa/Supa + embeddings） | 🟡（群聊多角色） | 🔴 | 🔴（前端 app） | 🟡 | PromptBuilder + Lorebook + 长记忆可借鉴；需要“角色扮演专用能力包” |
| TavernKit Playground | SillyTavern-like Rails | ✅（runs/job/并发） | ✅（窗口+注入预算） | 🟡（RAG 入口保留） | ✅（多角色/auto） | ✅ | 🔴（独立产品 UI） | 🟡 | 与 Cybros 栈相近；可作为“角色扮演实验”快速对齐的实现参考 |

> 读表要点：对于“平台化实验底座”，🟡 项最值得优先补（一次补齐覆盖多个形态）；🔴 项往往是“新产品/新运行时”工作，而不是 SDK 级缺口。

## 4) 我们最值得优先补的“平台能力”（横跨多个项目）

按“覆盖面 / 复用性 / 对安全的必要性”排序：

1. **可配置的 Tool Policy Profile（allow/deny/confirm + 规则持久化）**
   - 覆盖：Codex/OpenCode/OpenClaw/Accomplish/Memoh/Bub
   - 需求：按 tool 名、参数、路径、域名、channel 做 allow/confirm/deny；支持“required approval + deny_effect=block”；支持“prefix rule”记忆
2. **Memory 工具化 + 写入策略**
   - 覆盖：OpenClaw/Memoh/Risuai（以及未来所有“长期助手/多轮任务”）
   - 需求：`memory_search`/`memory_get`/`memory_store`（可选 `memory_forget`）；支持 citations；支持 scope（conversation/global/user/group）
3. **Context pruning（工具结果软/硬清理）**
   - 覆盖：OpenClaw/OpenCode/Codex（长会话成本/缓存优化）
   - 需求：在 prompt 组装阶段对旧 tool results 做规则化裁剪，不改历史，只改“本次调用上下文”
4. **Subagent Tool（DAG 子图编排的 LLM 可调用入口）**
   - 覆盖：OpenCode/Memoh/OpenClaw/NanoClaw（不同强度）
   - 需求：把 `docs/dag/subagent_patterns.md` 产品化：提供一个 LLM tool 来“创建/推进/读取 subagent”，并可合并摘要回主线
5. **Prompt Builder 的“结构化章节 + promptMode”能力**
   - 覆盖：OpenClaw/Memoh/OpenCode/Bub/TavernKit/Risuai
   - 需求：支持 full/minimal/none；稳定 prefix；时间/渠道/能力等 metadata 注入；bootstrap files 注入上限与可观测
6. **Strict schema + tool call repair/failover（模型 workaround 能力包）**
   - 覆盖：OpenAI Agents SDK/OpenCode/OpenClaw/Risuai/Memoh（不同层面）
   - 需求：tools/MCP schemas strict 化；call_id/字段归一；工具参数校验失败的修复回路；必要时模型 fallback，并把异常与切换写入可观测

以上 6 项能显著提高“后续实验的可组合性”，并减少每个实验重复造轮子。
