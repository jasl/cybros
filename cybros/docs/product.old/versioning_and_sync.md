# 配置版本化与导出（git / GitHub，Draft）

本文档定义“用户可变部分（Agents / PromptBuilder / Workflow …）”的管理方式：

- 使用文件系统进行管理（LLM/人类都易于编辑）
- 默认使用 git 作为版本与回滚载体（可 diff、可 revert；但必须支持无 git 的降级）
- 改动默认 **立刻生效**（不引入额外审批流程），但必须经过 schema validation
- 可选：导出/分享到 GitHub 等远端仓库

---

## 0) 核心立场（怀疑视角）

我们希望允许 Agent 迭代自身定义（prompt/workflow），但不能走向：

- 基座被随意改动（失去上游升级与安全修复）
- 任意代码在 Rails 进程里执行（安全边界被打穿）
- “谁改了什么、为什么改、改坏了怎么回滚”无法追踪

因此把“可变性”收敛到：**文件 + schema +（可选 git）+ revert**（权限交互与 vibe coding 一致；见 `docs/product/behavior_spec.md`）。

---

## 1) 哪些东西走文件 / git 管理（建议）

Phase 1 建议先覆盖：

- User-defined agents（AgentProfile + persona + tool selection）

探索性扩展（后续）：

- PromptBuilder（声明式 DSL）
- Prompt programs（沙箱内 prompt building，输出严格校验 + fallback；高风险，见 `docs/product/prompt_programs.md`）
- Workflow/Orchestrator（声明式 DSL）
- MCP servers/configs（如果用户强烈需要“可导出/可审计”的配置文件）

不建议走 git 的：

- 系统级 secrets（API keys）与系统 hard limits（应留在 system settings，走审计 + admin 管控）
- 用户对话内容（Conversation）：强隐私，不纳入“共享/同步”

---

## 2) Repo 的归属与粒度（Programmable Agent repo）

我们需要：

- 用户可编辑、可回滚、可审计的资源（默认在 git repo 中；便于 Agent 自改与人类 review）。
- 同时避免把“协作/共享”过早做复杂（Phase 1 仍以 1 Space + 1 user 为主）。

结论（已决定）：

- 系统自带的 **global（System-provided）Agents**：只读、可升级、可复现；**不可修改**。
- 用户的 **Programmable Agent**：归属到 `scope=user`（资源 owner = user），其“定义”以 **一个目录** 作为载体（推荐初始化为 git repo；下文称 **Agent repo**）。
- **不做 Space repo**，也不做 “在实例内 fork/copy 资源并在 Space 内共享” 这套能力；共享/协作通过 **导出与分享**（见 9.1）解决。
- Phase 1 **不做远端同步**（GitHub 集成延后到 Phase 2）。

Agent repo 的目录结构（示例，建议）：

- `agent.yml`（AgentProfile + persona + tool selection…）
- `workflows/`（编排 DSL / 配置）
- `prompt_templates/`（md/yaml/liquid/erb…）
- `prompt_programs/`（可选：沙箱 prompt building）
- `skills/`（可选：技能脚本/清单）
- `facts/`（可选：有限 KV 的 YAML/JSON；便于 diff/revert）

并发与冲突（非目标，但需止损）：

- 系统只保证 repo 不损坏（实现上建议对 git 操作加粗粒度锁）。
- 不保证多会话并发编辑不会产生“丢更新”；最差可用 revert 恢复到可用版本。

高级用法（可选）：

- 高级用户可以在宿主机上对 Agent repo 使用 `git worktree` 等能力自行管理分支/冲突；Cybros 不提供工作流保证，只保证提交历史可审计与可回滚。

---

## 3) 立刻生效（Immediate apply）的规则

规范性要求：

- 写入前应尽可能做 schema validation（失败则拒绝写入，不更新 active 版本）。
- 写入成功后必须立刻可见（新版本 = active version）。
- 若 Agent repo 是 git：
  - 写入应产生可追溯记录（commit/diff/revert），用于快速恢复与分享。
- 若 Agent repo 不是 git：
  - 系统必须继续工作；但缺少历史/diff/revert 等能力（UI 应显式提示）。
- 任何一次“运行 Agent”的行为都应记录其使用的配置版本（优先 `git_commit_sha`；否则记录一个 `config_version` 占位，例如目录内容 hash），用于回放与归因（见 `docs/product/observability.md`）。

“立刻生效”的关键是：不能让系统进入半配置状态；一旦新版本在运行时被证明不可用，必须 **fail-fast** 并进入 remediation flow（提示回滚/切回内置 agent 等）。

---

## 4) 权限与写入：与 vibe coding 一致（trade-off）

你已决定：Programmable Agent 的自改不作为单独的“GitOps 审批域”。因此：

- Agent repo 的读/写/执行都交给 **沙箱策略 + permission gate**（与正常 vibe coding 相同；见 `docs/product/behavior_spec.md`）。
- 产品不引入 “gitops writes” 这类额外审批类型；是否自动放行 `Write/Edit/Execute` 由用户选择的模式（Cowork/Manual/Evolution）决定。

共享与协作（明确不做）：

- Phase 1/2 不提供 “把我的 Agent repo 共享到 Space 内供他人直接使用/修改” 的能力。
- 若需要共享：通过导出/分享一个 GitHub repo URL（或 archive）让他人导入为自己的 Programmable Agent。

---

## 5) Revert：回滚必须是一等能力

规范性要求：

- 若 Agent repo 是 git：
  - UI 必须能查看历史版本（commit log + diff）。
  - 用户必须能一键 revert 到某个历史 commit（并且立即生效）。
- 若 Agent repo 不是 git：
  - UI 不得崩溃；应提示“未启用 git，无法回滚”，并引导用户手动修复 / 重新导入 / 切回系统内置不可变 agent。

---

## 6) YAML 序列化（LLM-friendly）

你希望 YAML 风格序列化，这很适合 LLM 编辑与 human review，但必须满足：

- 只允许安全加载（`YAML.safe_load`），禁止任意对象反序列化。
- 明确 schema（字段、类型、默认值、限制），并提供稳定错误码与安全 details（遵守本仓库的 coercion 原则）。
- 禁止 silent coercion（例如 `" "` 变 `0` 的 `to_i` 风险）。

---

## 7) 用户可变资源中的可执行代码：只能在沙箱中运行

原则：

- 用户可变资源（Agents / PromptBuilder / Workflow …）中的可执行代码不能在 Rails 进程内运行；必须作为“可执行任务”交给 ExecHub/Runner（沙箱）运行，并受 policy 限制（deny-by-default、网络/文件/环境变量）。
- 如需在 Rails 进程内运行代码，只能通过 **system admin 安装的 Core plugin**（高信任、强风险提示、可一键禁用/安全模式）提供，不属于本文件讨论的“用户可变资源”范畴（见 `docs/product/extensions.md`）。

这意味着：即使用户写了代码，它也只是“工具/任务”的一种，而不是“改写基座”的方式。

---

## 8) Open questions

- GitHub 集成是否只做 “导出/分享”（push）而不做 “同步”（pull/双向）？若要支持 pull，冲突策略与审计口径如何定义？

---

## 9) 已确定的决策（Resolved）

### 9.1 GitHub 导出与分享（Phase 2 目标，最小形态）

- Phase 1：不做 GitHub 集成。
- Phase 2：只支持对 **Agent repo** 做“导出与分享”：
  - 用户可为某个 Agent repo 关联一个 GitHub 远端（repo URL）。
  - 系统不做后台定时 pull/push；只提供显式 `export`（push）动作，便于备份与分享。

认证与安全边界（自托管单租户优先）：

- 不让用户把 GitHub token 交给系统保存或注入沙箱。
- 使用 SSH：由沙箱提供用于 git 的 SSH `public key`，用户将其添加为目标仓库的 deploy key（或等价机制）并授予写权限。
- remote URL 使用 `git@github.com:ORG/REPO.git`（或同类 SSH URL）。

备注：

- “不使用 token”仅针对 **git 远端导出（push）** 这条链路；插件系统仍可能需要以 secrets 的方式配置第三方 API 凭据（见 `docs/product/extensions/settings.md`）。

### 9.2 Repo 的存储位置（persistent volume）

规范性要求：

- git repo 存在 `storage/` 下，并要求容器部署时为 `storage/` 提供 persistent volume（否则重启即丢失历史与回滚能力）。
- 每个 Programmable Agent 一个 repo，推荐路径形态：
  - Agent repo：`storage/cybros/repos/users/<user_id>/agents/<agent_id>/agent_repo`

体积控制（暂不做限制）：

- Phase 1/2：不引入 repo 配额/硬上限；best-effort。
- （未来）如出现真实运维压力，再引入上限与配套的错误提示/清理工具。
