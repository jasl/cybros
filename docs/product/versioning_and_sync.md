# 配置版本化与同步（GitOps 风格，Draft）

本文档定义“用户可变部分（Agents / PromptBuilder / Workflow …）”的管理方式：

- 使用文件系统进行管理（LLM/人类都易于编辑）
- 以 git 作为版本与审计载体（可 diff、可 revert）
- 改动默认 **立刻生效**（不引入额外审批流程），但必须经过 schema validation
- 可选：与 GitHub 等远端仓库同步

---

## 0) 核心立场（怀疑视角）

我们希望允许 Agent 迭代自身定义（prompt/workflow），但不能走向：

- 基座被随意改动（失去上游升级与安全修复）
- 任意代码在 Rails 进程里执行（安全边界被打穿）
- “谁改了什么、为什么改、改坏了怎么回滚”无法追踪

因此把“可变性”收敛到：**文件 + schema + git + permission gate + revert**。

---

## 1) 哪些东西走 git 管理（建议）

Phase 1 建议先覆盖：

- User-defined agents（AgentProfile + persona + tool selection）

探索性扩展（后续）：

- PromptBuilder（声明式 DSL）
- Workflow/Orchestrator（声明式 DSL）
- MCP servers/configs（如果用户强烈需要“可导出/可审计”的配置文件）

不建议走 git 的：

- 系统级 secrets（API keys）与系统 hard limits（应留在 system settings，走审计 + admin 管控）
- 用户对话内容（Conversation）：强隐私，不纳入“共享/同步”

---

## 2) Repo 的作用域（Space 与用户）

我们既要“Space 内共享”，又要“用户私有”，并且希望支持（未来的）GitHub 同步。

结论（Phase 1）：

- 每个 Space 只使用 **一个 git repo（Space repo）**，用于承载该 Space 下的用户可变资源（Agents / PromptBuilder / Workflow …）。
- repo 内同时承载 `scope=user` 与 `scope=space` 的资源（见 `docs/product/terminology.md`），但 **repo 不作为安全边界**：权限必须由应用层 enforce。
- system/bundled（只读）资源不进入该 repo；用户修改必须先 fork/copy 成用户资源，再进入 repo。
- Phase 1 **不做远端同步**（GitHub sync 延后到 Phase 2）。

建议的目录结构（示例）：

- `agents/user/<user_id>/<key>.yml`（`scope=user`）
- `agents/space/<key>.yml`（`scope=space`）
- `workflows/user/<user_id>/<key>.yml`
- `workflows/space/<key>.yml`

私有 ↔ 共享（scope 迁移）的语义（规范性倾向）：

- “共享到 Space”不是切换一个可见性开关；应当通过 **fork/copy** 生成一份 `scope=space` 的新资源（产生 git commit + Event 审计）。
- 反向同理：space → user 通过 fork/copy 生成 `scope=user` 资源。
- “撤销共享”= 删除（或禁用）目标 `scope=space` 资源；不影响源 `scope=user` 资源。
- Phase 1 不支持“就地 move 改 scope”（避免误把私有变共享）；如需转移，显式 fork + delete。

并发与冲突（非目标，但需止损）：

- 系统只保证 repo 不损坏（实现上建议对 git 操作加粗粒度锁）。
- 不保证多会话并发编辑不会产生“丢更新”；最差可用 revert 恢复到可用版本。

高级用法（可选）：

- 高级用户可以在宿主机上对 Space repo 使用 `git worktree` 等能力自行管理分支/冲突；Cybros 不提供工作流保证，只保证提交历史可审计与可回滚。

---

## 3) 立刻生效（Immediate apply）的规则

规范性要求：

- 写入前必须做 schema validation（失败则拒绝写入，不更新 active 版本）。
- 写入成功后必须立刻可见（新的 HEAD = active version）。
- 所有写入都必须产生可追溯记录：
  - git commit（diff + message + author）
  - Event（who/when/space/resource/commit_sha）
- 任何一次“运行 Agent”的行为都必须记录其使用的配置版本（commit_sha），用于回放与归因（见 `docs/product/observability.md`）。

“立刻生效”的关键是：**失败要原子回滚**，不能让系统进入半配置状态。

---

## 4) Permission gate：不做 CR，但必须有“写权限请求”

你提出的“不要额外审批”可以成立，但前提是：

- 任何由 Agent 触发的文件写入，都必须走正常 permission request（用户明确同意这次写入）。
- 人类用户在 UI 编辑属于显式操作，不需要额外 gate（但仍需要 schema validation + 审计）。

写入类动作的“会话级自动放行”（规范性倾向）：

- permission request 卡片应支持 `Allow once` 与 `Auto-allow writes in this conversation` 两档。
- `Auto-allow writes` 与 `Auto-allow executes` 是两套独立开关（按 kind 分开，见 `docs/product/behavior_spec.md`）；本节仅讨论写入类动作。
- `Auto-allow writes` 仅对 **当前 Conversation** 生效，且只覆盖 repo 写入 + git commit（git-backed resources）；不覆盖网络、secrets 读取、沙箱执行等危险能力。
- 该状态必须在 UI 中持续可见，并允许随时关闭；开启与关闭都应落审计事件（不记录敏感细节）。

共享资源的修改权限（建议最小规则）：

- 私有资源：owner 可改。
- `scope=space` 资源：space admin 可改；space member 默认只能 copy/fork 到自己的 `scope=user` 再改。

---

## 5) Revert：回滚必须是一等能力

规范性要求：

- UI 必须能查看历史版本（commit log + diff）。
- 用户必须能一键 revert 到某个历史 commit（并且立即生效）。
- revert 也必须落 Event（可审计）。

---

## 6) YAML 序列化（LLM-friendly）

你希望 YAML 风格序列化，这很适合 LLM 编辑与 human review，但必须满足：

- 只允许安全加载（`YAML.safe_load`），禁止任意对象反序列化。
- 明确 schema（字段、类型、默认值、限制），并提供稳定错误码与安全 details（遵守本仓库的 coercion 原则）。
- 禁止 silent coercion（例如 `" "` 变 `0` 的 `to_i` 风险）。

---

## 7) 用户可变资源中的可执行代码：只能在沙箱中运行

原则：

- **Git-backed 用户可变资源**（Agents / PromptBuilder / Workflow …）中的可执行代码不能在 Rails 进程内运行；必须作为“可执行任务”交给 ExecHub/Runner（沙箱）运行，并受 policy 限制（deny-by-default、网络/文件/环境变量）。
- 如需在 Rails 进程内运行代码，只能通过 **system admin 安装的 Core plugin**（高信任、强风险提示、可一键禁用/安全模式）提供，不属于本文件讨论的“用户可变资源”范畴（见 `docs/product/extensions.md`）。

这意味着：即使用户写了代码，它也只是“工具/任务”的一种，而不是“改写基座”的方式。

---

## 8) Open questions

- Phase 2 如果引入 GitHub 同步：是否只同步 Space repo（space admin 管理），还是需要支持“按 user 导出/同步自己的私有目录”？后者可能意味着需要额外的导出工具或重新引入 User repo。

---

## 9) 已确定的决策（Resolved）

### 9.1 GitHub 同步（Phase 2 目标，最小形态）

- Phase 1：不做 GitHub 同步。
- Phase 2：系统不负责“自动同步/冲突策略”，只提供最小能力：
  - space admin 自行决定何时 `push`/`pull`（无后台定时 sync）。
  - 发生冲突就是标准 git 冲突：由用户自行处理；也允许让 LLM 在沙箱内辅助解决（编辑冲突文件、commit）。

认证与安全边界（自托管单租户优先）：

- 不让用户把 GitHub token 交给系统保存或注入沙箱。
- 使用 SSH：由系统/Agent 提供用于 git 的 SSH `public key`，用户将其添加为目标仓库的 deploy key（或等价机制）并授予写权限。
- remote URL 使用 `git@github.com:ORG/REPO.git`（或同类 SSH URL）。

备注：

- “不使用 token”仅针对 **git 远端同步** 这条链路；插件系统仍可能需要以 secrets 的方式配置第三方 API 凭据（见 `docs/product/extensions/settings.md`）。

### 9.2 Repo 的存储位置（persistent volume）

规范性要求：

- git repo 存在 `storage/` 下，并要求容器部署时为 `storage/` 提供 persistent volume（否则重启即丢失历史与回滚能力）。
- 每个 Space 一个 repo，推荐路径形态：
  - Space repo：`storage/cybros/repos/spaces/<space_id>/space_repo`

体积控制（硬约束）：

- 每个 repo 设定硬上限（例如 **16MB**）；超过上限时拒绝写入/commit，并给出可行动的错误（例如提示用户清理历史、删除大文件、或拆分资源）。

### 9.3 Permission request（UX）

规范性要求：

- Agent 触发的 repo 写入与 git commit：复用系统现有的 permission request 交互（与网络/文件等权限一致）。
- Persona/AgentProfile 的修改不引入特殊规则或特殊弹窗。
- Phase 1：允许 “Auto-allow writes in this conversation”（会话级、可撤销），但不提供 repo-level 或 agent-level 的跨会话永久信任（避免扩大误操作与提示注入的风险）。
