# Agents 与编排（Draft）

本文档讨论产品层最核心的可变部分：Agent 的定义、Prompt 构造、以及多 Agent 编排方式。

---

## 0) 核心假设（可被推翻）

- 协议层（LLM API、tool calling、MCP、skills）相对稳定，用户不需要频繁改“底层”。
- 用户最需要改的是：
  - 模型/参数
  - Persona/风格
  - 可用工具（skills/tools/MCP/执行环境）
  - 工作方式（PromptBuilder/编排策略）

---

## 1) Agent 作为“可配置资源”

### 1.1 不可变默认 Agents（System-provided）

建议：

- 系统自带一组默认 Agents：只读、可升级、可复现。
- 用户不能直接改它们；若要自定义，通过“基于模板创建新的 Programmable Agent（Agent repo）”完成（避免“默认被污染”）。

### 1.2 用户自定义 Agents（User-provided）

建议能力：

- 完整编辑 AgentProfile（模型、参数、persona、工具、上下文策略等）。
- 支持导入/导出（JSON/YAML）与版本记录（建议 git-backed；见 `docs/product/versioning_and_sync.md`）。
- Agent 必须归属到某个 Space（用于组织与隔离）；Phase 1/2 不做 Space 内共享编辑，协作通过导出/分享（例如 GitHub repo URL / archive）实现。

---

## 1.3 Persona switching（工作流级别）

你提出“根据用户输入切换 persona”的想法非常值得做成工作流能力：它能把“不同任务用不同姿态/策略/工具倾向”显式化，而不是全靠一个固定 system prompt 硬扛。

产品层建议口径：

- persona 不等于权限：切换 persona 不应改变 permission gate 与执行侧 policy 的安全边界。
- persona 更适合被建模为 workflow 的一个阶段（Persona Router），其输出是结构化的 persona 选择与置信度。
- 切换应当对用户可见（UI badge/状态），并允许用户锁定或手动切换，避免“随机变脸”。

更完整的规范见：`docs/product/persona_switching.md`。

---

## 1.4 可编程 Agent（Programmable Agent）

你提出的“可编程 Agent + 受控沙箱 + git-backed 资源”本质上是在产品层把 vibe coding agent 的工作方式正规化：

- 用少量确定性原语（读/写/编辑/执行）完成复杂任务；
- 把“自定义/自改”收敛到 git-backed 资源与沙箱内执行（可审计、可回滚）；
- 通过显式的信任阶梯（Cowork 默认 → Manual 可切换 → Evolution 显式开启）把无人值守与自改变成可解释的升级，并避免能力悄悄升级。

规范草案见：`docs/product/programmable_agents.md`。

---

## 1.5 Channels / Bots（异步 ACK 与回复文案定制）

当对话入口扩展到 Telegram/Discord 等 IM 渠道时，“长任务先 ACK，再后台执行，再回传结果”通常是刚需，并且 Pro 用户会希望定制 bot 的回复口吻与模板。

这些行为建议落在 **channel/workflow 层**（而不是 persona 或 prompt building），规范草案见：`docs/product/channels.md`。

---

## 1.6 Rescue（救援艇）：快速切换 Agent + 回滚入口（建议）

边界情况：用户/Agent 修改了 AgentProfile/Workflow/PromptBuilder/prompt program，但**接口仍然合法**，导致 LLM 仍能“正常推理与工具调用”，只是行为语义已经跑偏（用户只能感知到“结果很奇怪”）。

规范性倾向：

- Conversation UI 必须能**快速切换当前使用的 AgentProfile**（并显示当前版本：git commit SHA 或 `config_version`），以便用户在不改配置文件的情况下让系统内置 Agent 接管“排障/回滚”。
- 系统必须提供一个 **system-bundled rescue handler/workflow**（不要求调用 LLM；可完全确定性执行）：
  - 稳定、不可被用户修改（避免“救援艇也被改坏”）。
  - 默认可用（即使用户 agent 崩坏/输出异常，也能触发回滚/禁用等止血动作）。
- 在 IM 渠道中提供 Rescue command（例如 `/sos`）触发救援流程，见 `docs/product/channels.md` 5。
- Rescue 不改变权限边界：回滚/禁用/切换等动作仍需遵守 permission gate；回滚能力取决于是否启用 git 版本历史（见 `docs/product/versioning_and_sync.md` 与 `docs/product/behavior_spec.md`）。

---

## 2) PromptBuilder 可编辑：能力与风险

允许用户编辑 prompt 构造方式会显著增加灵活性，但也会制造“不可控系统”：

- 轻微改动就可能导致 tool calling 崩坏、输出不可解析、token 用量暴涨。
- Prompt 注入面扩大（尤其当 PromptBuilder 支持模板拼接、引用 KB、插入工具结果）。

建议收敛策略（草案）：

- PromptBuilder 使用 **声明式 DSL**（可序列化、可验证），避免任意 Ruby/JS。
- 序列化格式优先 YAML（更适合 LLM/人类编辑与 review），但必须 `safe_load` + schema validation（见 `docs/product/versioning_and_sync.md`）。
- 对用户输入做严格 validation（不要让 `ArgumentError/TypeError` 直出；遵守仓库的 coercion 原则）。
- 提供“安全模式”与“专家模式”两档：
  - 安全模式：只允许修改 persona / few-shot / 轻量模板。
  - 专家模式：允许更深的模板结构，但需要 admin 开启或显式风险提示。
  -（可选增强）若确实需要“可执行的 prompt building 逻辑”，建议把它作为 **沙箱内 prompt program**（输出严格校验 + fallback），而不是在 Rails 主进程执行（见 `docs/product/prompt_programs.md`）。

与版本化/permission gate 的关系（规范性倾向）：

- Agent 可以生成 PromptBuilder 的变更补丁；写入与执行遵守沙箱策略与 permission gate。若 Agent repo 启用 git，则变更可 diff/revert；未启用 git 时系统仍需可用（见 `docs/product/versioning_and_sync.md` 与 `docs/product/behavior_spec.md`）。

---

## 3) 多 Agent 编排：Conclave（议会）模式草案

你提出的 Purifiers/Conclave 设定，本质上是一个非常常见但有效的分工模式：

- **Presenter（路由/表达）**：理解用户意图、规范化输入、选择合适的 Specialist。
- **Planner/Thinker（规划/推理）**：任务拆解、风险识别、预算分配、选择策略。
- **Preserver（档案员）**：总结、归档、知识库写入、长期记忆/索引维护。
- **Specialist（执行专家）**：面向具体工具/领域的高成功率执行。

### 3.1 主要收益

- 降低“一个 Agent 什么都做”的提示复杂度与认知负担。
- 更容易针对某个 Specialist 做评测与迭代（尤其是 tool calling workaround）。
- 与 DAG 的并行能力天然契合（可并发跑多个 Specialist）。

### 3.2 主要风险（怀疑点）

- **token 用量/延迟**：多一层 Presenter/Planner 会显著增加 token 与交互轮次。
- **错误路由**：Presenter 误判会导致“越帮越忙”，用户体验比单 Agent 更差。
- **上下文膨胀**：议会式讨论如果不强约束，会吞噬上下文窗口。

### 3.3 建议的工程化落点

- Presenter 先做“轻路由”：
  - 只输出结构化意图（task type + constraints + suggested agent），不要长篇推理。
  - 路由失败要有 fallback：直接让主 Specialist 接管。
- Planner 是可选阶段：
  - 只有当任务复杂度超过阈值才启用（例如多步骤/高风险/高 token 用量）。
- Preserver 与“知识写入”必须是明确动作，并且默认需要审批，并提供止损路径（可回滚/可撤销，例如删除/重建；避免污染 KB）。

---

## 4) 与 DAG 的映射（产品语义）

建议把“编排策略”落成一种可版本化资源（Workflow/Orchestrator），其执行应当：

- 只通过 DAG Public API 进行 lane/turn 的创建与推进；
- 使用 lane/turn 的 keyset paging 与 safety limits；
- 避免在用户同步请求路径调用 graph-wide closure/export（危险 API）。

与版本化/permission gate 的关系（探索方向）：

- Workflow/Orchestrator 的修改同样应走 “permission gate + schema validation +（若启用 git：commit/diff/revert）”，否则“编排可变”会把可靠性问题放大到系统级（见 `docs/product/versioning_and_sync.md`）。

---

## 5) 模型选择：prefer_models（fuzzy match）+ per-role 配置

结论：

- 路由/规划/执行的模型不假设一致；**每个角色/Agent 都应可单独设置模型策略**。
- AgentProfile/Workflow 中建议支持一个 `prefer_models` 序列，用于在不同 provider 下做“模糊匹配”的模型选择：
  - `prefer_models: ["gpt-4.1", "gpt-4.1-mini", "o3-mini"]`（示例）
  - 解析策略应当是稳定且可解释的：按顺序挑选“第一个可用匹配”；无法匹配则落到 system default / fallback。
  - 统计需要区分 `requested_model` 与 `used_model`（见 `docs/product/observability.md`）。

备注：

- “模糊匹配”应是 **数据安全的匹配**（例如规范化后做 substring/token match），不要直接让用户输入正则或可执行表达式。

---

## 6) 可配置的“Presenter-first 路由”实验（不固化成产品逻辑）

你提出的实验（Presenter 永远接第一条消息，必要时切换 persona/agent 并重跑）应当作为 **Workflow/Orchestrator 的一种可配置策略**存在，而不是硬编码的产品逻辑：

- Presenter：负责意图识别/规范化输入/选择合适 persona（Specialist）。
- 切换条件：Presenter “自己不能处理”或用户显式要求（例如选择某 persona、或要求工具能力）。
- 能力约束：可以配置 Presenter 禁用 tool use，从而在需要工具时强制 handoff 给可用工具的 Specialist。
- 执行语义：handoff 后“重跑”同一条用户输入（或用 Presenter 生成的规范化输入，作为 workflow 的一个显式字段）。

目标是：用户可以在 Cybros 上实现/迭代这套策略（通过 Agent repo 内的 Workflow/Agent 配置文件），而不是我们把它当成默认行为写死。

---

## 7) Agent 自改的作用域（结论）

- “Agent 自改”不只限于自身 AgentProfile，也允许修改 **编排策略（Workflow/Orchestrator）**。
- 统一规则仍然是：permission gate + schema validation + 立刻生效；若启用 git 则可 diff/revert（见 `docs/product/versioning_and_sync.md` 与 `docs/product/behavior_spec.md`）。

---

## 8) 评测与回归：质量指标（结论）

除了 tokens/请求数/延迟/错误率，我们需要把“质量信号”纳入可观测性（按 agent/workflow + model 维度切片），至少包含：

- tool calling 成功率（结构化输出可解析、schema 校验通过、call 与执行一致）
- 工具执行成功率与耗时（tool/MCP/skill）
- repair/retry 频率（失败后自动修复/重试的次数与成功率）
- 用户反馈（例如 thumbs up/down；可选备注）

这些指标的落点与展示见 `docs/product/observability.md`（本文件只定义“我们要什么”，不定义 UI 形态）。
