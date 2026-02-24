# 术语表与资源模型（Glossary，Draft）

本文档为 `docs/product/*` 提供统一术语，避免“同一个词在不同文档里含义不同”导致实现跑偏。

状态：Draft（可随时推翻/重写）。

---

## 1) 核心实体

- **Instance**：一次 self-hosted 部署出来的 Cybros 服务。
- **Account（Tenant）**：租户边界；当前是**软单租户**（实例仅使用一个 Account，并尽量对用户隐藏）。
- **Space**：组织/团队/项目空间；资源隔离与协作边界；当前是**软单团队**（Phase 1 只有 1 个默认 Space）。
- **User**：账号内用户；属于 Account，且可加入多个 Space；当前是**软单用户**（Phase 1 默认只有 1 个用户）。
- **Conversation**：强隐私的对话资源（背后 attach DAG graph）；属于某个 Space，但默认始终为 user-scope（见 4）。
- **Resource**：可被创建/修改/复用的对象（AgentProfile、Workflow、MCP config、KB、Sandbox/Workspace…）。

---

## 2) Resource：scope 与 visibility（两个正交维度）

### 2.1 `scope`（归属层级 / 拥有边界）

`scope` 用于表达“资源属于谁、由谁管理、默认在什么边界内可见/可用”。

- `account`：租户级资源（对 Account 内用户生效/可见）。
- `space`：空间级资源（对该 Space 的成员可见/可用）。
- `user`：用户级资源（仅对该用户可见/可用；并且必须归属到一个 Space，用于组织与隔离）。

> 注：本文档刻意不把 `system` 当成 scope。**system/bundled** 更像是“资源来源/可变性（provenance/mutability）”，见 3。

### 2.2 `visibility`（是否允许 public 分享）

`visibility` 用于表达“在 scope 之外是否允许公开分享”：

- `scoped`（默认）：只在 scope 边界内可见/可用。
- `public`：允许生成 public share link，并**允许匿名访问**该分享页（share page）；分享页为只读展示，不扩展写权限/执行权限。

建议约束（产品语义）：

- share page 必须与可交互页面隔离（单独 controller/view），避免“分享页也能执行/写入”带来的风险面扩大。
- share page 对匿名用户为 **read-only**。
- 登录用户的“操作”（编辑/执行/回滚等）仍必须在正常的可交互页面中发生，并遵守 scope + permission gate（share link 不授予额外权限）。
- share page 可以提供“Copy/Fork / Open in app”等入口，但这些入口本身不应触发执行与写入。

---

## 3) Resource 的来源与可变性（建议术语）

同一个 scope 下，资源仍可能有不同的“来源/可变性”：

- **Bundled / System-provided**：随 core 或插件安装进入系统；默认只读、可升级；用户若要改动，必须 **Fork/Copy** 成 `space` 或 `user` scope 的用户资源。
- **User-defined**：由用户创建/维护（git-backed）；可编辑、可版本化、可回滚。

这套区分用于避免把“系统默认资源”与“用户可变资源”混在一个模型里导致升级/回滚困难。

---

## 4) Conversation（强隐私语义，规范性倾向）

- Conversation 必须归属到一个 `space_id`（用于组织与隔离）。
- Conversation 的 scope 视为 `user`，默认且长期保持私有（owner-only）。
- Conversation **不允许** `visibility=public`（不提供“共享私聊”开关）。
- 如需协作对话/群聊，应作为独立资源类型实现（例如 GroupChat/SharedConversation），避免误把私聊共享出去。

---

## 5) 字段模型（建议：实现对齐用）

> 这不是对当前代码的“事实描述”，而是产品层建议的**规范性字段模型**，用于实现对齐与避免“忘了加 where”。

对任意 Resource（包含 Conversation 在内），建议至少具备：

- `account_id`：租户隔离硬边界（single-tenant 也保留）。
- `scope`：`account|space|user`（见 2.1）。
- `visibility`：`scoped|public`（见 2.2）。
- `space_id`：
  - `scope=space|user`：必须存在
  - `scope=account`：必须为空（或约定为 NULL）
- `owner_user_id`：
  - `scope=user`：必须存在
  - `scope=account|space`：必须为空（或约定为 NULL）
- `public_share_token`（或单独 ShareLink 表）：
  - `visibility=public`：必须存在
  - `visibility=scoped`：必须为空

---

## 6) 旧术语映射（过渡期）

早期草案文档中出现过的旧术语建议映射为：

- `system`（旧 scope）→ `scope=account` + “Bundled/System-provided（只读，可 fork）”
- `shared`（旧 scope 或 `shared_in_space`）→ `scope=space`
- `user`（旧 scope 或 `private`）→ `scope=user`

---

## 7) Open questions

- 公开分享的最小审计策略：是否记录匿名访问日志？如果记录，保留多久？（默认倾向：不记录或只做聚合计数，避免引入隐私负担）
- share token 的撤销/轮换语义：撤销是否必须导致旧链接立刻失效？是否允许生成多个 share links？
