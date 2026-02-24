# Tenancy 与隔离模型（Draft）

本文档把“单租户 + 多用户 + 资源隔离/共享”说清楚，并刻意从怀疑角度列出风险与开放问题。

术语口径以 `docs/product/terminology.md` 为准；本文档若出现早期 `system/user/shared` 等旧术语，可按术语表中的“旧术语映射”理解。

---

## 0) 目标与非目标

目标：

- 在 single-tenant 部署下，定义清晰的 **user isolation** 与 **system-global** 边界。
- 为资源（MCP/KB/Agents/Hosts/Sandboxes/Workspaces）提供统一的“归属 + 访问控制”模型。
- 为 ExecHub/Runner 的隔离能力提供产品层解释与默认策略。

非目标：

- 不在本文档讨论 DAG/AgentCore 的内部表结构；产品层应走 Public API（见 `docs/dag/public_api.md`、`docs/agent_core/public_api.md`）。
- 不在本文档承诺“完全可信/完全不可信”的绝对安全；执行面威胁模型见 `docs/execution/execution_subsystem_design.md`。

---

## 1) 基本术语（建议统一）

- **Instance**：一次 self-hosted 部署出来的 Cybros 服务。
- **Tenant**：对外承诺的租户隔离边界。当前目标是 **single-tenant**（= 1 instance 对应 1 tenant）。
- **User**：该 tenant 内的用户（支持多用户；首次启动默认只有 1 个用户）。
- **Space**：工作区/空间；用于把资源与对话分组并形成隔离边界；也是最小共享的载体（Phase 1 锁定只有 1 个 Space；不实现 Space 管理/切换 UI）。
- **Resource**：可被用户创建/修改/使用的对象：MCP、KB、Agent、Host、Sandbox、Workspace 等。
- **Scope（作用域）**：Resource 的归属层级（Account / Space / User；见 `docs/product/terminology.md`）。

---

## 2) Scope 模型：Account / Space / User

我们同时需要“按用户隔离”与“系统全局共享”两种语义。建议把资源统一归到三类 scope：

### 2.1 Account scope（租户级）

特点：

- 由管理员维护；对 Account 内所有用户生效。
- 典型资源：LLM Providers、LLM Models、全局配额/限制、默认执行策略等。
- system/bundled（随 core 或插件进入系统）的只读资源通常也落在 account scope（但“是否 bundled”属于来源/可变性，而不是 scope）。

风险：

- 过度 account 化会让普通用户无法自助（需要管理员频繁介入）。

### 2.2 User scope（用户级，默认私有）

特点：

- 资源默认只对 owner 可见（owner-only；且必须属于某个 Space）。
- 典型资源：用户自建 Agents、用户的 MCP 配置、用户知识库、用户 hosts/sandboxes、用户工作区等。

风险：

- “一切都按用户隔离”会抑制协作与复用（团队共享困难），也会导致资源重复与维护负担。

### 2.3 Space scope（共享/协作）

特点：

- 最小形态：归属到某个 Space，对该 Space 成员可见/可用。
- 典型资源：Space 内共享 MCP、共享知识库、共享 Agent、共享执行环境模板等。

风险：

- ACL 复杂度高；需要非常清晰的 UI 与审计，否则会出现“以为私有其实共享”的事故。

---

## 3) Roles 与访问控制（最小模型）

最小角色模型：

- **Owner / Admin / Member** 足够。
- `system`（若存在）视为内部角色/服务账号，不进入产品心智模型。
- Phase 1：Owner 与 Admin 的区别先收敛到一条：**只有 Owner 可以删除 Space**（其余权限一致）。
- Phase 1 默认形态建议尽量简单：**1 Account（internal）/ 1 Space / 1 Owner user**。
- SpaceMembership/角色模型需要保留（为未来团队协作做铺垫），但 Phase 1 **不实现**成员管理相关的 controller 与页面。

Admin 的默认可见性（收敛版，避免引入企业级 break-glass）：

- Admin 负责 account/space scope 的运维与管理，但**不默认越权读取** `scope=user` 的内容（含 Conversation 与私有资源内容）。
- 不引入 break-glass 流程（若未来确有运维诉求，应作为独立功能设计，并配套强审计与显式用户提示）。

只读共享（可用不可改）：

- 必须支持 “只读共享”。
- 建议产品体验对齐 ChatGPT 网页版分享：
  - 被分享者可查看/使用（run）该资源，但不能直接修改源资源；
  - 被分享者可以 **Copy/Fork** 到自己的 user scope 再修改。
- Phase 1 建议：`scope=space` 资源的“维护权”默认只给 Owner/Admin；Member 以“只读 + 可 fork”为主（避免协作复杂度过早爆炸）。

---

## 4) 资源归属建议（初稿）

> 注：这不是实现承诺，是“默认产品语义”的建议表。

- LLM Provider / Models：Account scope
- System settings（API keys / hard limits / default sandbox policy）：Account scope
- Prompt cache：Account scope（但必须满足隐私与不可枚举要求；见 5.2）
- Built-in Agents：Account scope（Bundled/System-provided；只读，可 fork/copy）
- User Agents：User scope（可 fork/copy 到 Space scope）
- MCP servers/configs：User scope（可 fork/copy 到 Space scope）
- Knowledge bases：User scope（可 fork/copy 到 Space scope）
- Hosts / Sandboxes / Workspaces：
  - 默认 User scope（属于某个 Space，强隔离）
  - admin 可提供 account-level “执行模板/runner pool”，用户只选择引用（更易运维）

---

## 5) 关键怀疑点（必须提前正面回答）

### 5.1 “单租户”与现有 Account 模型的关系？

当前代码基座是 account-aware 的（multi-tenant 方向）。单租户产品可以有三种落点：

1) **保留 Account，但实例只允许一个 Account**（最小改动；URL 前缀可隐藏或保持）。  
2) **保留 Account，但对用户屏蔽“租户”概念**（UI/URL 不出现 account_id）。  
3) **彻底移除 Account**（改动最大；短期风险高）。

本阶段选择：

- **保留 Account，但实例只允许一个 Account，并尽量对用户隐藏（概念/文案/UI）**。
- URL **不使用** path-based `/{account_id}` 前缀；Account 在产品层面完全隐式（instance = 1 tenant = 1 account）。
- 工程落点：从“无前缀 URL + 默认 account”开始；未来如果需要多租户，再引入 URL 前缀或其他路由策略。

### 5.2 Prompt cache 全局共享的隐私/安全问题

即使 cache 不对用户暴露，仍有两个风险：

- **数据落盘**：cache 可能包含用户隐私/密钥/商业数据（即便用户之间不可读，也增加泄露面）。
- **跨用户复用**：若 cache 命中导致输出复用，需要保证不会出现“输出携带另一用户数据”的可能性。

建议默认策略（草案）：

- cache 仅作为内部优化，**不可枚举/不可检索**；
- cache key 必须包含模型/参数/工具上下文等，避免“不该复用的复用”；
- 对含 secrets/附件/KB 引用的请求，默认不缓存或做强 redaction；
- 提供 admin 级开关与审计。

### 5.3 “资源隔离包含主机和沙箱”意味着什么？

“按用户隔离 hosts/sandboxes”在产品语义上很清晰，但在工程上代价很高：

- 同一台 Runner 机器上多个用户的 workspace 是否物理隔离？（容器？microVM？）
- 谁来承担镜像/依赖缓存的共享？共享会引入侧信道与污染。

这里必须以 `docs/execution/execution_subsystem_design.md` 的 threat model 为准，产品层要做：

- 默认 deny-by-default 的执行 profile；
- 给出“可信/不可信”清晰开关与后果说明；
- 强审计（谁批准了放权、放了什么权、执行了什么）。

---

## 6) Conversation：隐私与“协作对话/群聊”

结论（Phase 1）：

- 先专注 “人类 ↔ AI 一对一”的 Conversation。
- Conversation 为 owner-only（不因 admin 角色而改变）；不引入 break-glass（见 3 节 Admin 默认可见性）。
- 不提供“共享私聊”的开关；协作应通过 **独立资源**（例如 GroupChat/SharedConversation）实现，而不是把私聊改成共享。

群聊（未来需求方向，非 Phase 1）：

- 形态更接近 group chat：多个参与者 + 共享上下文。
- AI 默认被动：只有在被 `@`（或等价显式触发）后才发言，避免“抢话/刷屏/误触发工具”。
- 成员与授权模型需要单独设计（不在 Phase 1 范围内）。

---

## 7) Open questions（刻意保留）

（暂无）
