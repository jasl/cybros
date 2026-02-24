# Phase 1：产品概念审查（可行性 / 正交性 / 完整性）

本文档的目的不是“把想法写得更漂亮”，而是从怀疑角度把方案审查到足够 **可实施**：

- 正交：概念之间不互相打架、组合后不会产生大量特例。
- 完整：关键对象的归属、权限、审计、回滚、隔离都能闭环。
- 可落地：能尽快实现一个“完整概念”的 MVP 来评估产品形态，而不是做一堆局部原型。

状态：Draft（讨论用）。

---

## 0) 已确定的前提（本阶段不再争论）

- 部署形态：self-hosted、single-tenant。
- 单租户落点：**保留 Account，但实例只使用一个 Account，并尽量对用户隐藏**。
- 多用户：数据与资源需要隔离；同时需要最小共享能力。
- 引入 Space：作为隔离与最小共享载体；Phase 1 锁定只有 1 个默认 Space（不实现 Space 管理/切换 UI）。
- 个人对话（Conversation）是隐私：不通过“共享”机制改变其可见性（避免误操作事故）。
- 基座不可变：用户通过插件与可配置资源扩展；不支持随意改动主程序。
- Agent 自我修改：通过 permission gate 允许写入配置文件；改动立刻生效，但必须可审计、可验证、可回滚（git）。

实现落地建议见：`docs/product/phase_1_implementation_plan.md`。

---

## 1) 方案的核心矛盾（必须承认，而不是回避）

### 1.1 “按用户隔离” vs “需要共享复用”

如果所有资源都按用户隔离，协作与复用会失败；如果引入共享，ACL 与审计复杂度上升。

结论：必须承认共享存在，并把共享的形态收敛到“最小可用”。

### 1.2 “允许用户深度自定义” vs “可靠性/安全默认值”

Agent 产品的可变性（AgentProfile、PromptBuilder、编排）是价值所在，但每一项可变都会扩大故障面。

结论：把可变性限制在可验证、可回滚、可审计的边界内；并且默认安全（deny-by-default）。

### 1.3 “隐藏 Account” vs “工程现实”

保留 Account 能降低未来演进成本；在 single-tenant 下我们选择 **不使用** `/{account_id}` URL 前缀，因此 “隐藏 Account” 的产品成本与工程复杂度都更低。

结论：Phase 1 不向用户暴露 Account 概念，URL 也不带 account 前缀；未来若需要多租户，再引入 URL 前缀或其他路由策略。

---

## 2) 正交的对象模型（建议：最少概念集）

目标：用尽可能少的“一级概念”覆盖你列出的所有需求。

### 2.1 核心对象

- **Account（internal）**：实例唯一的 tenant 容器，主要用于未来演进与隔离边界的保留。
- **User**：账号内用户（角色：owner/admin/member/system）。
- **Space**：工作区/项目空间；用于隔离与最小共享（Phase 1 锁定只有 1 个默认 Space）。
- **Resource**：一切可被配置/复用的对象（Agent、MCP、KB、Host、Sandbox、Workflow…）。
- **Conversation**：用户对话（DAG attachable）。本阶段视为强隐私资源（不共享）。
- **Versioned resource store（git）**：用户可变资源的文件化存储与版本系统（commit/diff/revert + 审计）。

### 2.2 归属与隔离（建议默认规则）

- 除 `scope=account` 资源外，所有 Resource 必须属于一个 Space（`space_id`；见 `docs/product/terminology.md`）。
- Resource 默认 `scope=user`（owner-only）；如需在 Space 内共享，通过 fork/copy 生成 `scope=space` 版本（不是切换 visibility/共享开关；`visibility=public` 例外用于匿名只读分享页）。
- Conversation 必须属于一个 Space（用于隔离与组织），但始终私有（owner-only）。
- `scope=account` 资源（LLM providers/models、hard limits、built-in agents 等）由 admin 管理；bundled/system-provided 的资源默认只读、可升级，修改需 fork/copy（见 `docs/product/terminology.md`）。

这套规则的好处：Space 解决“隔离”和“共享”的主要矛盾；Conversation 单独强隐私，避免 ACL 误用。

---

## 3) 共享模型：先做 share-to-space（刻意收敛）

为了“尽快做出完整概念评估”，共享建议分两阶段：

### Phase 1（MVP）

- 共享只有一种形态：通过 fork/copy 生成 `scope=space` 资源（供 space members 使用）。
- UI 上只需要呈现两档：`scope=user`（Personal）/ `scope=space`（Shared in Space）。

### Phase 2+

- 引入更细粒度 ACL：共享给部分用户、角色、组；引入审计与“可见性解释”。

怀疑点：如果一开始就做复杂 ACL，会拖慢验证速度，并显著增加错误配置风险。

---

## 4) 变更如何发生：GitOps + permission gate（替代 CR 审批流）

本阶段我们不采用 CR 审批流，而采用 “文件 + git + permission gate + revert” 的 GitOps 风格变更（见 `docs/product/versioning_and_sync.md`）。

定义（简化但必须闭环）：

- 可变资源以文件形式存在（YAML/JSON），写入前做 schema validation。
- 每次写入生成 git commit，并记录 Event（who/when/space/resource/commit）。
- 改动立刻生效；如果效果不好，用户可 revert 到历史版本（立即生效）。

规范性结论（避免失控）：

- **Agent 触发的写入必须经过 permission request**（用户同意本次写入）。
- 共享资源的修改必须受 Space role 约束（member 默认只能 copy/fork）。

---

## 5) Conclave 编排：把它当成“可选策略”，不是默认对话形态

你的 Conclave（Presenter/Planner/Preserver/Specialist）是很合理的工程分工，但默认启用会：

- 增加延迟与成本；
- 引入路由错误导致的糟糕体验；
- 快速膨胀上下文与状态机复杂度。

建议落点：

- 作为一种 **Workflow/Orchestrator 资源**（可配置、可版本化、可评测）。
- Presenter 做轻路由（结构化 intent），Planner/Preserver 按阈值启用。
- 所有“写入类动作”（改配置、写 KB、生成文件）都需要 permission gate + 审计；git-backed 写入必须可回滚，其它写入至少要可撤销/可重建；其中“可执行代码”只能在沙箱中运行。

---

## 6) “完整概念 MVP”应该包含什么（可实施闭环）

为了评估这种产品形态，MVP 不是“能聊天”就够，而是要具备闭环：

- Space：固定一个默认 Space（不实现 Space 管理/切换 UI；成员管理仅保留模型能力）。
- Resource：至少 AgentProfile + MCP（配置）+ Workflow（可选，哪怕是简化版）。
- Conversation：属于 Space、强隐私、可检索与归档。
- Git 版本化：配置文件可被 Agent/人类修改（有 permission gate），立刻生效，且可 diff/revert。
- Observability：按 user + model 统计 tokens/latency/error；补充 tool calling 成功率与失败原因分布（稳定 error codes）与用户反馈（thumbs up/down）作为质量信号；按 space 聚合（见 `docs/product/observability.md`）。
- 审计：系统设置变更、共享切换、危险执行审批、配置写入/回滚都落 Event。

如果缺少（版本化+审计+回滚）或用量统计，就无法验证“可靠基座 + 可控可变性”的核心主张。

---

## 7) 本阶段最大的风险（提前写出来）

- Space + Resource scope + git 版本化 三者如果没有统一语义，会出现“用户以为的隔离/共享”和“系统实际行为”不一致。
- prompt cache 如果处理不当，会成为隐私/安全的隐藏炸弹（即便不对用户暴露）。
- 想同时做“可编排 + 可自改 + 可插件化 + 强隔离”，容易失控；必须用 MVP 收敛策略控范围。

---

## 8) Open questions（下一轮讨论建议聚焦）

- Conversation 的“绝对不共享”是否允许未来有“群聊对话”（作为新资源而不是共享私聊）？
- PromptBuilder/Workflow 的 schema 形态：以声明式 DSL（YAML）为主；可执行代码只能作为“沙箱工具/任务”存在，边界与权限如何定义？
