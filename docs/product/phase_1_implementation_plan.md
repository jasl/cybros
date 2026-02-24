# Phase 1：实现计划（MVP，用于概念评估）

本文档把 `docs/product/phase_1_review.md` 的“完整概念 MVP”拆成可执行的工程步骤，并刻意控制范围：先做能评估产品形态的闭环，再扩展能力。

状态：Draft。

---

## 0) MVP 的验收标准（必须闭环）

MVP 必须能在 UI 中完成以下闭环：

- 用户登录 → 进入默认 Space（单 Space；无切换/管理 UI）
- 创建/编辑 `scope=user` AgentProfile → fork/copy 成 `scope=space`（共享给 Space）
- 发起 Conversation（强隐私）并运行 Agent
- Agent 产出“修改自身配置”的建议 → permission request 允许写入配置文件 → 立刻生效 → 可回滚
- 看用量统计（按 user + space + model）
- 所有关键动作可在审计里追溯（谁做的、何时做的、改了什么）

---

## 1) 基础域模型（先把“归属/隔离/审计”钉死）

建议的最小模型清单（命名可调整）：

- `Account`（internal）：实例唯一；后续仍保留 multi-tenant 的可能性。
- `Identity`：email 维度（可选，但有助于未来 multi-account）。
- `User`：account membership + role（owner/admin/member/system）。
- `Space`：account 下的工作区（Phase 1 锁定只有 1 个）。
- `SpaceMembership`：user ↔ space（role；Phase 1 不实现成员管理 UI）。
- `Event`：审计事件（已有 `Event` 模型，可扩展 fields/particulars）。

关键约束（建议直接写成模型校验 + DB 约束）：

- 一切用户可变资源都必须能落到明确的 scope（`account|space|user`，见 `docs/product/terminology.md`）：
  - `scope=space|user`：必须带 `space_id`
  - `scope=user`：必须带 `owner_user_id`
- 查询路径必须显式按 `space_id` 过滤（避免“忘了加 where”导致泄露）。

---

## 2) Space：隔离与最小共享的载体

MVP 范围：

- 固定一个默认 Space（可在首次启动/seed 中创建）。
- Space memberships：保留 owner/admin/member 三档的模型能力（供未来启用团队协作）。
- 资源共享先做 share-to-space：
  - Resource: `scope = user/space`（share-to-space = fork/copy 生成 `scope=space`；UI 可呈现为 Personal / Shared in Space）

不做：

- Space CRUD（create/list/switch/archive）的 UI。
- Space memberships 的成员管理 UI（邀请/移除/改角色）。
- 复杂 ACL（按用户列表/组的 share）。
- 跨 Space 复制/同步策略（可手动 export/import）。

---

## 3) Agents（最先做，因为它驱动“可变性”评估）

MVP 范围：

- `AgentProfile` 资源（space-owned, user-owned；以文件存储 + git 版本化）：
  - model/provider/params/persona/tools selection（先保留最小字段集合）
  - scope（`user|space`）
  - versioning（git commit/diff/revert；见 `docs/product/versioning_and_sync.md`）
- built-in agents（system）：
  - read-only
  - 支持 Copy 到 Space 作为用户版本

不做：

- “任意 Ruby/JS 可执行的 prompt 构造”。

---

## 4) PromptBuilder / Workflow：先定义 schema，再给编辑器

MVP 建议策略：

- 先落一个 **声明式 DSL** 的最小 schema：
  - prompt sections（system/developer/user templates）
  - few-shot 示例
  - tool calling 约束片段
- Workflow 先落一个 “Presenter 路由 + Specialist 执行” 的简化版：
  - Presenter 输出结构化 intent（短 JSON）
  - 路由失败 fallback 到默认 Specialist

编辑体验：

- 第一版可以先用 YAML editor（LLM-friendly；能跑起来、能回滚、能审计）。
- 后续再做图形化/表单化编辑器（避免前期 UI 拖慢节奏）。

可执行代码（非 MVP）：

- 如需支持用户代码，只能作为“沙箱工具/任务”交给 ExecHub/Runner 执行，并受 deny-by-default policy 约束。

---

## 5) Conversation：强隐私 + 可追溯

MVP 范围：

- Conversation 必须属于 Space（用于隔离与组织）。
- Conversation 默认且长期保持私有（owner-only）；不提供“共享开关”。
- Conversation 与 DAG/AgentCore 集成保持 lane-first（遵守 Public API safety tiers）。

未来扩展（不进入 MVP）：

- GroupChat/SharedConversation（协作对话/群聊）作为独立资源类型。

---

## 6) Git 版本化：把可变性收敛成可控边界

本阶段不实现 CR（Change Request）。改用 git 版本化作为变更边界（见 `docs/product/versioning_and_sync.md`）。

MVP 范围：

- 文件化存储 + schema validation + git commit（含 author/commit message）。
- Agent 触发的写入必须走 permission request（用户同意本次写入）。
- UI：版本历史（log + diff）+ 一键 revert（立即生效）。

Repo 形态（Phase 1）：

- 每个 Space 一个 git repo（Space repo），用于承载该 Space 下的用户可变资源（见 `docs/product/versioning_and_sync.md`）；不做远端同步（Phase 2 再做 GitHub sync）。

---

## 7) Observability：按 user + space + model 计量

MVP 范围：

- 记录每次 LLM 调用：
  - user_id / space_id / provider / model / tokens / latency / success
  - tool calling 质量信号（可选但建议）：tool calls emitted/parsed 计数 + 稳定 error codes（见 `docs/product/observability.md`）
- 记录 tool/MCP/skill 调用的 success/latency 与权限摘要。
- 记录用户反馈（可选）：thumbs up/down（按 agent/workflow/model 切片）。
- UI：用户看板 + space 聚合 + admin 聚合。

---

## 8) 插件系统（先 Tier 0 内容插件，别急着代码插件）

MVP 范围：

- Tier 0 内容插件（声明式资源包；见 `docs/product/extensions.md`）：
  - 可 system 安装（全局可见）或 space 安装（空间内可见）
  - 内含 agent/prompt/workflow 模板与 presets

不做：

- 代码插件的运行时隔离与权限模型（需要更完整的威胁模型与发布链路）。

---

## 9) 里程碑建议（按依赖排序）

- M0：Account/User/Auth（能区分用户） + Event 审计骨架
- M1：Space + memberships + 资源 scope（user/space）
- M2：AgentProfile（CRUD + versioning + copy from built-in）
- M3：Git 版本化（针对 AgentProfile）+ permission gate + 回滚 UI
- M4：Conversation 绑定 space + 运行 Agent（DAG-first）
- M5：用量统计与看板（按 user/space/model）

每个里程碑都必须可演示，否则不要进入下一个（避免“最后才发现组合不成立”）。
