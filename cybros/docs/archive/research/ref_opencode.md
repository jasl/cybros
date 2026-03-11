# 参考项目调研：OpenCode（references/opencode）

更新时间：2026-02-24  
调研对象：`references/opencode`  
参考版本：`2a87860c0`（2026-02-24）

注（2026-02-22）：本仓库已在 AgentCore 落地 `Policy::PatternRules` / `Policy::PrefixRules` / `Policy::ToolGroups`；app 层规则持久化与注入仍未实现（见 `docs/research/gap_analysis.md`）。

## 1) 项目定位与核心形态

OpenCode 是一个开源 coding agent（CLI/桌面/网页等多端），核心目标是“可配置的编码代理”。它的关键特色不是某个单一模型能力，而是：

- 多 **agent profiles**（build/plan/general/explore/compaction/title/summary…）
- 可配置、可合并的 **权限规则**（allow/ask/deny），并对外部目录、`.env` 等敏感文件做特殊处理
- 明确的 **Plan Mode（只读阶段）→ Build Mode（可执行阶段）** 分工
- **Compaction + tool-output pruning** 的上下文治理（对长会话非常实用）

## 2) Agent profiles（多代理配置）与权限系统

OpenCode 在 `packages/opencode/src/agent/agent.ts` 内把 agent 定义成一个可配置对象（name/description/prompt/model/steps/permission rules）。内建 profile 包括：

- `build`：默认 agent，执行工具（permission 合并 defaults+user config）
- `plan`：计划模式，禁止 edit（只允许写指定 plans 路径）
- `general`：通用 subagent
- `explore`：代码库探索专用（grep/glob/list/read/webfetch/websearch 等）
- `compaction`/`title`/`summary`：隐藏 agent，用于压缩与标题生成

权限实现为一套规则 DSL（`PermissionNext`），支持：

- 按动作/工具名 allow/deny/ask
- 按外部目录/文件 glob 细分（例如 `.env` 需要 ask）
- profile 之间 merge（defaults + user overrides）

对 Cybros 的映射与差距：

- Cybros 已有 `tool_policy.authorize` 产出 `allow/deny/confirm(required, deny_effect)`，足以表达 ask/deny/allow；
- 已补一套 **规则化 policy**（`Policy::PatternRules` / `Policy::PrefixRules` / `Policy::ToolGroups`）；仍缺 app 层规则持久化与注入（见 `docs/research/gap_analysis.md` 的 P0）
- OpenCode 的“按路径/外部目录/敏感文件”规则非常值得直接借鉴为 policy 的默认实现

## 3) Prompts 与上下文/指令管理

OpenCode 的 prompt 是按模型/场景拆分的文本文件（`packages/opencode/src/session/prompt/*.txt`），并有以下值得注意的点：

1. **Plan Mode 系统提醒**
   - `prompt/plan.txt` 明确声明只读，不得修改任何文件（强约束）
2. **工具使用策略**
   - 鼓励用 “Task tool / explore subagent” 来探索代码库，减少主上下文污染
3. **指令文件加载**
   - `session/instruction.ts` 会从 repo 向上查找 `AGENTS.md`/`CLAUDE.md`（以及全局 AGENTS/Claude config），并支持 config 指定额外 instruction（含 URL）
   - 同时维护“已加载 instruction 集”，避免重复注入

对 Cybros 的启发：

- 我们已有 `RepoDocs` prompt injection（默认注入 AGENTS.md）。可以扩展为：
  - 支持多文件类型（CLAUDE.md、TOOLS.md、MEMORY.md…）
  - 支持“按需向上查找”与“避免重复注入”的 loaded/claimed 机制（参考 OpenCode 的实现）

## 4) Context 管理：Compaction + Prune（很实用）

OpenCode 的 `session/compaction.ts` 提供两类治理：

1. **Auto-compaction**
   - token 溢出时创建一个“compaction 模式”的 assistant message（summary=true）
   - 用一个专用 compaction agent 生成“可继续工作”的摘要模板（Goal/Instructions/Discoveries/Accomplished/Relevant files）
   - 可选自动注入 synthetic user message 触发继续（避免 summary 后停机）
2. **Prune old tool outputs**
   - 逆向扫描，超过保护窗口后，把旧 tool output 标记 compacted（丢弃/不再注入）
   - 保留特定工具（如 `skill`）不 prune

对 Cybros 的映射：

- auto_compact：我们已实现 summary 节点压缩（持久化在 DAG，且对下游 context 生效）
- “prune old tool outputs”：我们缺少一个“只影响 context 组装、不改历史”的 pruning 层（建议 P0 补）
- “summary 后自动继续”：我们当前的 auto_compact 是在预算收缩的时刻压缩历史，不自动注入下一条 user_message；如要复刻 OpenCode 的体验，可在 app 层加入“继续执行”的策略（例如：压缩完成后把原请求再跑一轮）

## 5) Memory（显式文件约定）

OpenCode 的 `beast.txt` prompt 里约定了一个“记忆文件”：

- `.github/instructions/memory.instruction.md`

这属于“把记忆写入 repo”的模式（对团队协作/可审计很友好）。实现上它并不依赖专门的 memory store，而是依赖文件工具去读写该文件。

对 Cybros：

- 我们已有 pgvector memory store（更偏 RAG），但也可以通过 `FileSet` prompt injection 把类似的“团队记忆文件”作为 always-injected bootstrap（并设 max_bytes）
- 若要复刻 OpenCode 的“把记忆写进 repo”，关键是：
  - 文件写入权限（policy）
  - 记忆写入触发策略（用户显式要求/或 pre-compaction flush）

## 6) 在 Cybros 上实现的可行性评估

### 能做到（现有底座基本覆盖）

- 多 agent profiles：用不同 runtime（prompt_mode、tool_policy、model、budget）即可表达
- explore subagent：用 `docs/dag/subagent_patterns.md` 的跨图建模即可
- compaction summary：我们已有（且比 OpenCode 更“图内原生”）

### 需要补的能力（建议优先级）

P0：

- ✅ **规则化 Tool Policy**（AgentCore 已落地 allow/confirm/deny + path/file patterns；app 层持久化/注入未做）
- **Context pruning**（按策略裁剪旧 tool results）
- **Instruction files injection 扩展**（RepoDocs 支持更多文件类型/按需加载）

P1：

- **Profile 体系**：把“agent profile”上升为一等配置（UI/配置文件/数据库），并可以 per turn 切换

## 7) 最小落地建议（覆盖面最大）

如果目标是“让 Cybros 能承载 OpenCode 风格的实验”，优先做：

1. 已补 `Policy::PatternRules` / `Policy::PrefixRules` / `Policy::ToolGroups`（路径、工具、敏感文件、外部目录的规则引擎）；下一步是 app 层持久化与注入
2. Context pruning（旧 tool results 软/硬清理）
3. subagent tool（explore-only profile）
4. instruction injection 扩展（AGENTS/CLAUDE/TOOLS/MEMORY 的可控注入）

## 8) Skills、MCP、tool calling：膨胀治理实践（很值得抄）

OpenCode 在“工具与技能容易膨胀”这件事上，采取了多层治理（代码层面的措施比 prompt 更可靠）：

- **Skills 按需加载**：内建 `skill` tool 只注入 `<available_skills>`（name/description/location），真正的 SKILL.md 内容只有在调用 `skill(name=...)` 时才加载进上下文（见 `packages/opencode/src/tool/skill.ts`）。这避免了“所有技能全文常驻 prompt”。
- **MCP tool schema 规整化**：把 MCP tool 的 `inputSchema` 强制变成 `type: "object"` + `additionalProperties: false`，再经 `ProviderTransform.schema(...)` 做 provider 兼容转换（见 `packages/opencode/src/mcp/index.ts` 与 `packages/opencode/src/session/prompt.ts`）。这能显著降低“模型生成不合规参数”与“provider 400/422”概率。
- **tool output 截断 + 落盘**：`Truncate.output` 对工具输出做 lines/bytes 双阈值截断，并把完整输出保存到 `Global.Path.data/tool-output/`，同时提示用 Grep/Read(offset/limit) 或委派 `Task` 工具处理（见 `packages/opencode/src/tool/truncation.ts`）。这是典型的“把大结果外移到文件系统，再做二次检索”的模式。
- **prune old tool outputs**：在 compaction 之外，额外把旧 tool parts 标记 compacted；并对某些工具（如 `skill`）做保护避免被清掉（`PRUNE_PROTECTED_TOOLS = ["skill"]`，见 `packages/opencode/src/session/compaction.ts`）。
- **权限与可见性**：skills/MCP tools 都走统一 permission 体系（ask/deny/allow），并且 MCP server 可在 UI 中 enable/disable；这从源头降低“过多工具同时可用导致模型选择困难”。

对 Cybros：OpenCode 的实践可以直接映射成两条“平台能力”：

1. **Skills meta-tool + 按需 read**（只注入元数据；正文按需加载）。
2. **tool output 外移（file/attachment）+ 二次检索**（prune 只影响本次 context，不改历史）。

## 9) 模型 workaround 线索（偏工程）

- **Schema transform/sanitize 是刚需**：不同 provider 对 JSON Schema 支持不一致（尤其 MCP tool schema 来自外部服务器），OpenCode 选择在进入模型前统一“规整 + provider transform”，比在 prompt 里强调“严格按 schema”更有效。
- **把“长输出处理”变成程序**：截断、落盘、保留提示语与后续检索路径，属于典型的 harness workaround（减少模型在长输出里迷路、也减少 token 成本）。
- **MCP OAuth 状态机外显**：`needs_auth / needs_client_registration / failed` 等状态通过 UI 反馈给用户，避免模型在 MCP 不可用时反复尝试同一个工具进入死循环。
