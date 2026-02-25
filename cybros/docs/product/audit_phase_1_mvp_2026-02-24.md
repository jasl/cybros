# Phase 1 MVP 审查（2026-02-24）：Persona / 可编程 Agent / 沙箱 / UI

本文档记录本轮对产品方向的“怀疑式审查”，目的不是扩展愿景，而是把概念收敛到 **正交、可实现、可止损** 的最小集合，并明确哪些能力应该延后。

本轮输入（来自你提供的方向与参考项目）主要包含：

- 基于用户输入的 Persona 切换（PSM-like，但在工作流层实现）
- 可编程 Agent：服务端提供能力/资源有限的沙箱；将用户 Agents 定义（git repo）映射进沙箱
- 不可变基座 + 插件 + 可编程 Agent，避免“OpenClaw 风格永久分叉”
- A2UI（agent-driven UI 渲染）与 A2A（扩展能力边界）
- 以 Claude Cowork / Codex / OpenCode / Pi-Mono / OpenAlice 等为对照

---

## 0) 结论先行（本轮建议）

如果只追求“对 Pro 用户可用的 MVP”，建议把目标收敛为三件事：

1) **工作流级 Persona Router**（可观测、可锁定、可回滚到“默认 persona”）  
2) **可编程 Agent 的最小原语 + 强隔离沙箱**（Read/Write/Edit/Bash + 权限与预算）  
3) **Cowork 式“无人值守执行”作为显式模式**（一次性放权 + 不允许能力悄悄升级）

其它（A2UI/A2A、IM bot、多渠道/调度、桌面自动化）都应当被设计为“可插拔/可扩展”，但不作为 Phase 1 成败标准。

---

## 1) 你这套叙事里最危险的点（需要直接指出）

### 1.1 “什么都能变形”会把 MVP 拖死

“解放 LLM/Agent 变形出任何形态的软件产品”是愿景，但工程上 Phase 1 必须有一个强约束的落点，否则：

- 没有可评测的成功标准（最后只能用主观体验评判）
- 安全/权限/审计/回滚做不闭环（尤其是执行与自改）
- UI 与扩展点会先膨胀，再被迫重写

建议把“变形能力”拆成可验证的原语：

- workflow 可变（git-backed、可回滚）
- tools 可扩（但工具面需要 profile 化）
- execution 可升级（显式信任阶梯）

这三件事闭环后，“变形”才不是一句口号。

### 1.2 “自我演进”容易被误当成目标

OpenClaw/OpenAlice 里常见的“Evolution mode”很容易诱导我们把成功定义成：

- Agent 能不能改自己代码、改 prompt、改系统

但对 Pro 用户更重要的其实是：

- **可控地完成任务**（成功率、可验证）
- **可解释地放权**（为什么需要、更大风险是什么）
- **可恢复地止损**（坏了能回滚/禁用/重建）

因此建议在产品层明确写死：自我演进是“可编程 + 可观测 + 可回滚”之后的副产品，不是第一阶段目标。

---

## 2) 逐项审查你的关键想法（怀疑视角）

### 2.1 基于用户输入切换 Persona（✅ 值得做，但要强约束）

优点：

- 把“同一助手的多种姿态/策略”显式化，减少用户反复解释“你现在像谁”。
- 允许把不同任务映射到不同的工具倾向与模型倾向（但不授予权限）。

主要风险：

- persona 抖动导致“随机变脸”，破坏用户信任
- prompt 注入诱导切到更“听话/更敢执行”的 persona
- 用户把 persona 当作安全边界（反模式）

建议落点：

- 用 Persona Router 作为 workflow 的一个阶段（见 `docs/product/persona_switching.md`）
- 输出结构化（persona_id/confidence/reason/stickiness），写入审计与可观测
- UI 必须显示当前 persona，允许锁定/手动切换/撤销

### 2.2 服务端有限沙箱 + 映射 agent 定义 repo（✅ 可行，但必须先定义边界）

你说“只保证 shell + 基础编程环境”的动机是对的：它会逼迫我们把依赖变成**显式配置**（image/profile/skills），而不是靠“机器上刚好有”。

但最容易出事故的点在于：你把两类 repo 混在一起说了：

- **Project workspace**：要被 agent 操作的项目仓库（coding/automation 目标）
- **Agent repo（git-backed resources）**：承载该 Programmable Agent 的 Agents/Workflows/PromptBuilder 等“用户可变资源”的 repo

如果默认把两者同时映射进同一个沙箱执行，就会导致：

- 项目里的不可信代码在执行时可以顺手修改系统配置 repo（扩大误伤面）
- “配置变更”与“项目变更”的回滚语义混在一起（定位与恢复变难）

建议：

- 单次 run 默认只挂载一个 workspace；跨 workspace 属于能力升级，需审批
- Agent repo 默认只读挂载，只有明确写入/commit 时才升级为可写（仍需 schema validation + git + 审计）

详见 `docs/product/programmable_agents.md`。

### 2.3 Claude Cowork 的“自动完成 + 自验收”（✅ 值得抄；可作为默认，但边界必须显式）

你喜欢 Cowork 的核心其实不是“默认自动跑”，而是：

- 形成 plan 后能连续执行多个步骤（不被反复审批打断）
- 能自我验收（测试/构建/对照预期）
- 失败时能自我修复或明确 blocked

对 Cybros 的建议是把它抽象成“信任阶梯”的一个档位：

- Cowork（默认）：标准沙箱动作的 Execute/Write 默认自动；但能力升级仍必须 ask
- Manual（可切换）：每次 Execute/Write ask（更保守、更可控）
- Evolution（自改）：允许改 workflow/skills/agent 定义，但必须可回滚/可禁用/可重建

这能在不牺牲安全默认值的前提下，把 Cowork 体验产品化。

### 2.4 不可变基座 + 插件 + 可编程 Agent（✅ 正交且必要）

这是你整套思路里最健康的“约束”，因为它强迫我们：

- 不把实验都做成 fork（避免永久分叉）
- 把变更收敛到：插件（分发单元）与 git-backed 资源（用户可变单元）
- 把任意代码执行限制在沙箱（Tier 1 sandbox plugin / skills），而不是 Rails 主进程（Tier 2 core plugin 高风险）

现有规范已经覆盖了大部分语义边界：

- `docs/product/extensions.md`
- `docs/product/versioning_and_sync.md`

### 2.5 A2UI（🟡 有价值，但应当作为“UI 协议/渲染层”延后）

A2UI 解决的问题很真实：让 agent 生成可交互 UI，且“安全像数据、表达像代码”。

但它在 Phase 1 的风险是：

- 它会迅速把产品重心从“任务闭环”拉向“UI 组件系统”
- 它需要一整套“组件目录 + 渲染器 + 事件绑定 + 安全策略”的工程投入

建议策略：

- Phase 1：只实现少数结构化 UI（审批卡、run 日志、diff、artifact 下载）
- Phase 2+：引入 A2UI 作为可插拔 UI 协议（由 WebUI renderer 解释），并把它严格限制在“组件白名单”

### 2.6 A2A（🟡 值得保留接口，但不应绑死核心）

A2A 的价值在于“让别的 agent 系统以 agent 的粒度与我们协作”，它更像：

- 外部 Specialist / Remote agent 的接入协议
- 与 MCP（tool 级）互补：MCP 扩展工具，A2A 扩展“可委派的 agent”

但对 Phase 1：

- 只需要保留“未来可接”的边界（例如作为一种 resource + tool group），无需做完整生态集成。

---

## 3) 我们应该从参考项目里抽取哪些“正交原语”

用“原语”而不是“功能列表”，避免产品走向拼盘：

- **Workspace**：执行的文件系统边界（project vs agent repo），可持久化，可重建
- **Sandbox profile / Policy**：能力与资源预算（net/fs/secrets/host IO + limits）
- **Permission gate**：人类在关键副作用点做显式决策（一次性放权也要可见、可撤销）
- **Workflow/Orchestrator**：编排与路由（Persona Router、handoff、teams）
- **Skill/Tool**：可复用执行单元（按需加载，避免 prompt 膨胀）
- **Context governance**：compaction + pruning + context cost report（可诊断）
- **Observability/Audit**：可回放、可归因、可恢复（diff/revert/kill/rebuild）

这些原语基本都能映射到现有文档集（本轮新增可编程 Agent 规范见 `docs/product/programmable_agents.md`）。

---

## 4) Phase 切片建议（面向 Pro 用户的“最小好用”）

### Phase 1（成败标准）

- Persona Router（可观测、可锁定、可撤销）
- 强隔离执行（至少容器/VM profile + 资源限制 + 可取消）
- Cowork（会话级无人值守模式：一次性放权 + 预算 + 不允许能力悄悄升级）
- 版本化（可选 git）：可变资源可 diff/revert（若启用 git），且每次运行记录 `agent_version`（优先 git commit SHA；否则 `config_version`）

### Phase 2（能力扩展，但不改变基座）

- Skills/插件分发（Tier 0/1）
- schedule/automation（周期触发 + 幂等 + 回传）
- 频道接入（先 WebUI，再 Telegram/Discord）

### Phase 3+（更大形态变化）

- A2UI renderer + 组件目录（agent-driven UI）
- A2A connector（remote agents）
- Tier 2 core plugins（谨慎：安全模式 + 一键禁用）

---

## 5) 本轮新增 Open questions（需要你拍板的）

- ✅ 已决定：默认 Cowork（强隔离 + 无人值守连续执行；但不自动批准能力升级），并默认强制 “Plan gate”（先 plan、再开跑）。
- “可编程 Agent”的分发单元怎么分层？
  - git-backed Agent repo（配置/工作流/模板）
  - ✅ 已决定：提供 first-party prompt-program 基线程序（脚本形态、Ruby 参考实现、模板外置开闭原则；Phase 2+ 引入，见 `docs/product/prompt_programs.md`）
  - sandbox programs（用户自定义可执行扩展；更高风险，需更严格的 trust boundary）
  - plugin/skills 包（可复用能力与分发）
  - Phase 2 的 GitHub 导出/分享需要支持哪几类对象、以及最小口径是什么？
  - ✅（2026-02-25）已决定：prompt-program 的受控内部查询 API 以 Internal MCP server 形态提供（只读、强 scope/审计/限流、默认关闭；见 `docs/product/prompt_programs.md` 与 `docs/product/mcp_servers.md`）
  - ✅（2026-02-25）已决定：集成 DesktopCommanderMCP 作为 foundation 执行面的候选实现，但默认不把完整工具面直接暴露给模型（见 `docs/product/mcp_servers.md` 与 `docs/research/ref_desktopcommander_mcp.md`）
- Agent-driven UI / App mode 的第一类目标是什么？
  - 你现在的初衷更像是：审批/问卷/表单/仪表板/可视化 + “由 Agent 引导完成一个过去得写 APP 的流程/小应用”
  - 仍需拍板：Phase 1/2 里最小组件目录是什么、哪些 UI 必须由 core 渲染（尤其权限审批，避免 UI spoofing）、以及“mini-app（沙箱 web）”是否要作为替代路径
