# 差距分析与补能力路线图（面向“可持续做实验”的底座）

更新时间：2026-02-21

本文把 `docs/research/*` 的单项目调研收敛成一份“平台能力 Backlog”。目标不是一次性复刻某个项目，而是让 Cybros 的 **DAG 引擎 + AgentCore** 能以最少增量覆盖更多实验形态。

补充三篇跨项目专题（更偏“怎么做”）：

- `docs/research/skills_mcp_tool_calling.md`
- `docs/research/model_workarounds.md`
- `docs/research/knowledge_management.md`

## 0) 先给结论：我们已经“能做”的与“最缺”的

### 已经很强的部分（短板不在这里）

- **DAG 调度与审计**：节点 claim/lease、bounded context、streaming node events、压缩 summary、fork/merge/archive（Lane-first）
- **Agent tool loop**：`agent_message → task* → next agent_message` + `awaiting_approval` gate
- **Context token budget + auto_compact**：超预算自动缩窗与总结（summary 节点）
- **MCP + Skills + Memory store（pgvector）**：作为注入点与工具来源已经具备

### 目前最缺、且横跨多个参考项目的“平台能力”

1. **更细粒度、可持久化的 Tool Policy（含 confirm/required/block、prefix rules、路径/域名约束）**
2. **Memory 的“工具化 + 写入策略”（检索/引用/写入/分层）**
3. **Context pruning（只影响本次 prompt，不改历史）**
4. **Subagent Tool（把跨图 subagent 模式产品化，成为 LLM 可用原语）**
5. **Prompt Builder 结构化（promptMode/full-minimal、稳定 prefix、bootstrap 文件预算可观测）**
6. **Strict schema + tool call repair/failover（模型 workaround 能力包）**

其余大项（容器隔离、WhatsApp/Telegram、桌面自动化）属于“产品/运行时形态”，不应强塞进 AgentCore 核心，但需要预留接口。

## 1) 能力包分层（建议）

把要补的能力分成 3 层，避免“把产品形态写死在 SDK”：

### L1：AgentCore（通用 SDK 层）

面向“任何 agent 产品形态”都复用的能力：

- Tool policy profiles（allow/deny/confirm + required/block + 规则持久化）
- Guardrails（输入/输出/工具输入/工具输出）
- Memory tools（search/get/store/forget）+ citations + scopes
- Context pruning（工具结果软/硬清理）与 prompt 预算可观测
- Prompt sections + promptMode（full/minimal/none）

### L2：App Integrations（平台产品层，Rails 域）

与具体产品有关、但可被多个实验复用的能力：

- Subagent orchestration（子图创建/推进/聚合）+ UI 展示入口
- Schedule/Automation（cron → enqueue DAG turn）+ 管理界面
- Channel adapters（Telegram/Discord/Webhook 等）→ conversation routing
- Workspace/Project bootstrap（AGENTS/TOOLS/MEMORY 文件注入策略、编辑权限）

### L3：Runtimes（隔离/桌面/浏览器）

强依赖运行环境、需要独立进程或容器的能力：

- 容器/沙箱 exec（NanoClaw/Memoh/OpenClaw/Codex）
- 浏览器控制（Playwright/CDP/MCP）
- 桌面系统 API（Accomplish/OpenClaw nodes/canvas/voice）

## 2) 具体差距与建议实现（按优先级）

### P0：Tool Policy Profile（高覆盖 + 安全必要）

参考项目触发点：

- Codex：审批策略、prefix_rule、sandbox escalation、网络策略与 exec 绑定
- OpenCode：每个 agent profile 一套权限（allow/ask/deny），外部目录与 .env 例外
- OpenClaw：tool groups + allow/deny、owner-only tool、profile（coding/messaging/full）
- Accomplish：文件写入前必须通过 permission MCP

建议补到哪里：

- **AgentCore**：新增一组内建 policy（仍保持 app 可自定义）
  - `Policy::PatternRules`：按 tool name + args（含 path/glob）判定 allow/confirm/deny
  - `Policy::PrefixRules`：对 shell/exec 类工具支持 prefix allowlist（可持久化）
  - `Policy::ToolGroups`：允许 `group:fs` 这类“工具集合名”展开（类似 OpenClaw）
- **App 层**：持久化“已批准规则”（conversation / user / account scope），并暴露为 prompt injection（让模型知道已批准哪些能力）

最低可用 spec（建议）：

- `Decision.confirm(reason:, required:, deny_effect:)` 已存在；补“规则引擎”与“规则存储”即可
- 规则维度至少包含：
  - tool name（支持别名映射）
  - path（read/write/edit/apply_patch/exec 的 cwd/path）
  - network domain（web_fetch/curl 等）
  - channel/session key（如果接入多渠道）

当前状态（2026-02-21）：

- ✅ 已落地：`AgentCore::Resources::Tools::Policy::Profiled`（工具可见性分层；exact / prefix* / regexp / `*`）
- ⏳ 未落地：`Policy::PatternRules` / `Policy::PrefixRules` / `Policy::ToolGroups`、以及 app 层“已批准规则”的持久化与注入

### P0：Memory 工具化 + 分层写入策略（长期助手必需）

参考项目触发点：

- OpenClaw：`memory_search`/`memory_get` + Markdown memory + vector index + citations + pre-compaction memory flush
- Memoh：mem0 风格“事实提取 → 候选召回 → 决策（add/update/delete）→ compact/time decay”
- Risuai：Hypa/Supa（总结 + embedding 相似召回）用于长期上下文保持

我们已有的基础：

- `AgentCore::Resources::Memory::Base` + `PgvectorStore`（search/store/forget）
- prompt 里已有 `<relevant_context>` 注入（但不是“工具化交互”）

建议补齐的最小能力：

1. **Memory tools**（作为 tool registry 的内建工具）
   - `memory_search(query, limit, filter?)` → 返回 entries（含 score + metadata + citation）
   - `memory_store(content, metadata?)` → 返回 id
   - `memory_forget(id)`（可选）
   - `memory_get(id)`（可选；若 entry 里 content 已足够，可不做）
2. **Citations 约定**
   - 允许 memory entry metadata 带 `source`（file, URL, message_id, turn_id）
   - prompt 注入时可选择“带/不带 citations”（OpenClaw：direct chat 默认带，group 默认不带）
3. **Pre-compaction memory flush（可选，但价值高）**
   - 在 auto_compact 前插入一个“silent agent turn”提醒写 memory
   - 若写入失败/无内容，则不影响主任务继续

不要一开始就做的（可后置）：

- Mem0 的 ADD/UPDATE/DELETE 决策链（可在 P1/P2 做）
- BM25/hybrid 检索（pgvector 先跑起来，之后再补）

当前状态（2026-02-21）：

- ✅ 已落地：`memory_search` / `memory_store` / `memory_forget`（native tools + size cap）与 `Registry#register_memory_store`
- ⏳ 未落地：`memory_get`、citations 契约、pre-compaction memory flush（auto_compact 前的 silent flush step）、分层写入策略（conversation/user/account scope 的 guardrails）

### P0：Context pruning（减少长会话工具结果膨胀）

参考项目触发点：

- OpenClaw：session pruning（cache TTL 过期后清 old toolResult，降低 cacheWrite）
- OpenCode：prune 老 tool parts output（只保留最近一段）
- Codex：tool result truncation + compaction

建议实现位置：

- **AgentCore::DAG::ContextBudgetManager / PromptAssembly**：在“最终组装 messages 前”对 tool_result 消息做裁剪

最小实现策略：

- 只对 `task` 节点映射出的 tool_result 做处理（不动 user/assistant）
- 策略参数：
  - `keep_last_assistant_turns`（保护最近 N 轮）
  - `min_prunable_bytes`（小于阈值不动）
  - `soft_trim`（head+tail+marker）
  - `hard_clear`（替换为 placeholder）
  - allow/deny tool name glob（跳过图像类等）
- 强约束：裁剪不写回历史，只影响本次调用 context

当前状态（2026-02-21）：

- ✅ 已落地：`ToolOutputPruner`（仅超预算时启用；只裁剪旧 `tool_result` 与 system-tool 兜底消息；不写回 DAG；决策写入 `metadata["context_cost"]`）
- ⏳ 未落地：按 tool name 的 allow/deny glob、head+tail（soft_trim）策略、hard_clear 策略、以及更细粒度的“保护边界”（keep_last_assistant_turns 等）

### P0：Strict schema + tool call repair（提升 tool calling 稳定性）

参考项目触发点：

- OpenAI Agents SDK / OpenCode：strict schema 规整（additionalProperties=false 等）显著降低 tool args 失败
- OpenAI Agents SDK：对 `call_id||id`、重复 items、MCP schemas 不完整等做兜底
- OpenClaw：把工具协议错误/invalid-request 纳入 failover 错误域（模型/鉴权轮换）

建议实现位置：

- **AgentCore**：
  - `StrictJsonSchema`：在 prompt build 阶段对 tools schema 做规整（尤其 MCP schemas）
  - `ToolCallRepairLoop`：工具参数解析失败（invalid_json/too_large）→ 发起一次“仅修参数”的修复调用（限定次数，避免死循环；后续可扩展到 schema 校验失败）
- **Provider adapter**：
  - `ProviderFailover`：可配置 fallback model 列表；把工具协议错误也计入可切换条件（并记录可观测事件）

当前状态（2026-02-21）：

- ✅ 已落地：`StrictJsonSchema`（在 prompt build 阶段对 tools schema 做保守 strict 化）
- ✅ 已落地：`ToolCallRepairLoop`（仅修 `arguments_parse_error`：`invalid_json/too_large`；批量一次修复；允许部分修复；仅写 metadata、不写回 DAG 历史）
- ✅ 已落地：`ProviderFailover`（同 provider 多模型重试；触发：404 + 400/422 工具/协议关键词；streaming 仅覆盖 `provider.chat(...)` 直接 raise 的场景）

### P1：Subagent Tool（把跨图模式“变成原语”）

参考项目触发点：

- OpenCode：explore agent + plan/build profiles
- Memoh：subagent CRUD + query + 独立 context
- OpenClaw：subagents(action=list|steer|kill)
- NanoClaw：Claude agent teams（更强，但可先做简化版）

我们已有的基础：

- `docs/dag/subagent_patterns.md` 已给出“跨图”建模

建议产品化：

- 提供一个 native tool：`subagent.run(name, prompt, policy_profile?, context_limit_turns?, merge_mode?)`
  - 实现：创建 child Conversation/Graph → 运行到 leaf 稳定 → 返回 child transcript 摘要
- 或分成两段：`subagent.spawn` + `subagent.poll`（适合长任务/并发）

关键：subagent 必须能配置不同 tool policy/profile（只读探索、web-only、写文件 agent 等）。

### P1：Prompt Builder 结构化（full/minimal + 稳定 prefix）

参考项目触发点：

- OpenClaw：system prompt 章节化、promptMode、bootstrap 文件注入与预算
- Memoh：静态/动态 header 分段（为 prompt caching）
- Bub：runtime_contract + tool view + skills compact
- TavernKit/Risuai：prompt order、lorebook、author note 等复杂拼装

我们已有的基础：

- Prompt injections sources（FileSet/RepoDocs）
- runtime.prompt_mode（已存在）

建议补齐：

- 内建 “System Prompt Sections” builder：
  - Tooling（工具列表 + 简短说明）
  - Safety（最小约束）
  - Memory（如果 tools/store 可用）
  - Workspace（cwd/workspace_dir）
  - Time/Channel（可选）
  - Skills（available_skills fragment）
- 对每个 section 做可配置 order + prompt_modes
- 对 injected files 做 max_bytes/total_max_bytes 与可观测（写到 metadata/usage）

## 3) 三类实验形态的“最小落地集合”

### 3.1 Coding agent（Codex/OpenCode/Bub/Accomplish）

最小集合：

- Tool policy profile（含 confirm/required/block）
- apply_patch / read / write / edit / exec 等基础工具（可通过 MCP 或 native）
- 上下文预算 + auto_compact（已有）
- tool result pruning（P0）
- subagent（explore / review）+ plan 模式（P1）

可选增强：

- “强沙箱 execve 拦截”集成（Codex shell-tool MCP）作为独立 runtime

### 3.2 Always-on personal assistant（NanoClaw/OpenClaw/Memoh）

最小集合：

- Channel routing（session key / conversation mapping）
- Schedule/cron（周期 turn 触发）
- Memory tools + flush（P0）
- owner-only / allowlist（安全）
- 容器隔离（L3，若要“可执行命令/编辑文件”而不冒风险）

### 3.3 Roleplay chat（Risuai/TavernKit）

最小集合：

- 角色/参与者模型（character_message、speaker 选择、multi-character turn）
- PromptBuilder（preset + lorebook/world info + author note + order）
- “swipe/版本”建模（可映射到 DAG node versioning：retry/adopt_version）
- branching/fork（DAG 原生支持 + UI）
- 长期记忆（可先用 summary+vector，逐步引入 Hypa/Supa 复杂策略）

## 4) 从两个 SDK 中“直接借鉴”的 API 设计要点

### OpenAI Agents SDK（openai-agents-python）

值得抄的形状：

- `Agent` 是纯配置对象（instructions/tools/handoffs/guardrails/output_type）
- `Runner` 管 loop（max_turns、handoff、tool calls、final output 判定）
- `Session` 统一历史（SQLite/Redis/自定义）
- Guardrails 覆盖 input/output/tool input/tool output（可 allow/reject/raise）
- Tracing 是一等公民（span、processor 可扩展）

映射到 Cybros：

- DAG + AgentCore 本质上已经是“Runner”；缺的是 guardrails 与 handoff 的一等 API
- Session 可直接由 DAG lane/turn 提供；也可补一层“Session protocol”适配外部存储

### Claude Agent SDK（claude-agent-sdk-python）

值得抄的形状：

- 把“成熟 harness（Claude Code CLI）”SDK 化：统一 stream-json 事件、permission_mode、cwd、allowed_tools
- transport 可替换（subprocess / 自定义），便于把 agent 运行放到容器/远端

映射到 Cybros：

- 把 Codex CLI / Claude Code / OpenHands 等外部 agent 当作一种“Runner/Provider”接入 DAG（节点执行器桥接）
- DAG 负责审计与调度，外部 harness 负责具体工具细节（尤其安全沙箱）
