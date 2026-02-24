# 产品层行为规范（Behavior Spec，Draft）

本文档是产品层的“规范性描述（normative spec）”草案，用于在讨论阶段就把默认行为写清楚、减少口头约定的漂移。

状态：Draft（可随时推翻/重写）。

---

## 1) 术语与字段模型（Scope / Visibility）

术语口径以 `docs/product/terminology.md` 为准（避免不同文档对同一个词的含义不一致）。

规范性要求：

- 资源必须具备 `scope`：`account|space|user`。
- 资源必须具备 `visibility`：`scoped|public`（默认 `scoped`）。
- `scope=space|user` 的资源必须归属到一个 Space（`space_id`）。
- `scope=user` 的资源必须标记 `owner_user_id`。
- system/bundled 资源默认只读；用户若要修改，必须通过 **Fork/Copy** 创建 `space` 或 `user` scope 的用户版本（见 `docs/product/terminology.md`）。
- scope 的变化（`user↔space↔account`）应当通过 fork/copy 实现；不建议通过“切换一个 visibility/共享开关”隐式扩大可见性（`visibility=public` 例外）。

补充（Conversation 的强隐私语义，MVP 规范）：

- Conversation 必须归属到一个 Space（用于隔离与组织）。
- Conversation 视为 `scope=user` 且默认保持私有（owner-only），不提供 `visibility=public`（不提供“共享私聊”开关）。
- 如果需要协作对话/群聊，必须作为独立资源类型实现（例如 GroupChat/SharedConversation），避免误把私聊共享出去。

---

## 2) 系统内置资源的可变性规则

规范性要求：

- 系统内置 Agents 为只读；用户若要修改，必须通过 **Copy** 创建用户版本。
- 系统内置 LLM Providers / Models / hard limits 仅 admin 可改；所有修改必须记录审计事件。

---

## 3) Agent 自我修改：GitOps + permission gate

本阶段结论：**不引入 CR（Change Request）审批流**。用户可变资源采用 “文件 + git” 管理，并且改动立刻生效。

规范性要求：

- 用户定义的 Agents / PromptBuilder / Workflow 等资源必须是可版本化的（git commit），并可 revert（见 `docs/product/versioning_and_sync.md`）。
- 改动必须先通过 schema validation；失败不得更新 active 版本（严禁半配置状态）。
- **由 Agent 触发的写入**必须走正常 permission request（用户显式同意本次写入/修改）。
- 修改权限必须与 scope 对齐（并受 Space role 约束）：
  - `scope=user`：owner 可改（其余用户不可见/不可改）。
  - `scope=space`：space admin 可改；space member 默认只能 fork/copy 到自己的 `scope=user` 再改。
  - `scope=account`：account admin 可改；非 admin 只能 fork/copy 到 `scope=space|user` 再改。

Permission request（UX）：

- 由 Agent 触发的写入类动作必须进入 permission request；其具体交互与 “Auto-allow … in this conversation” 规则见第 6.1 节。

备注：

- “不做 CR”不等于“无审计/无回滚”。相反，git + Event 使得每次改动都可追踪与快速恢复。

---

## 4) Prompt cache 的默认行为

规范性要求（草案）：

- Prompt cache 属于内部机制，不提供给用户枚举/搜索。
- cache 必须有严格的 key 维度（至少包含：provider/model/params + tool/mcp/KB 上下文摘要），避免跨语义复用。
- 对可能包含敏感信息的请求，默认不缓存或必须做强 redaction（具体规则另文定义）。
- admin 可配置开启/关闭与保留策略，并有审计。

---

## 5) 用量统计的最小精度

规范性要求：

- LLM 用量必须可统计到具体 model（provider+model），并可追溯到 user + agent/workflow + conversation/turn。
- tool/MCP/skill 的执行必须可统计成功率与耗时，并记录权限摘要（用于审计与用量/性能归因）。

---

## 6) 权限与危险能力的默认策略

本节同时定义：

- 产品侧 permission gate 的默认行为（哪些默认放行/哪些默认需要 ask）
- 执行侧 policy 的硬边界（哪些必须显式授予、且必须可审计/可撤销）

### 6.1 Permission gate：默认行为（结论）

默认策略（对齐 coding agent 体验）：

- `Read`（默认放行）：读取 workspace/资源内容；读取互联网信息（HTTP(S) fetch）。
- `Execute`（默认 ask）：运行命令（沙箱内执行）。
- `Write`（默认 ask）：写入文件、应用 patch、git commit、写 KB/资源等。

Permission request（UX，规范性倾向）：

- 对 `Execute` 与 `Write` 在审批卡片上必须提供三种决策：
  - `Allow once`：仅批准本次动作。
  - `Auto-allow <kind> in this conversation`：本会话内自动批准后续同类动作：
    - `Auto-allow executes in this conversation`
    - `Auto-allow writes in this conversation`
  - `Reject`：拒绝本次动作。
- `Auto-allow` 是 **按 kind 分开** 的会话级开关（execute/write 各自独立），并且必须满足：
  - UI 必须持续显示显式标记，并提供一键关闭入口（关闭后立即生效）。
  - 审计中必须区分 “manual approval” 与 “auto-allowed (conversation)”。
  - `Auto-allow` 仅覆盖“标准动作”，不应自动批准权限升级：当某次请求涉及额外危险能力（例如宿主读写、secrets 读取、私网访问、unrestricted network、扩大文件挂载范围等）时，即使已开启 `Auto-allow` 也必须重新 ask，并把“能力变化摘要”展示在审批卡片上。

### 6.2 执行侧 policy：危险能力（规范性倾向）

- 仍然遵循 deny-by-default：宿主读写、环境变量注入、secrets 读取、私网访问、unrestricted network 等都必须有 policy 显式授予。
- `Read` 中的“互联网访问”必须通过 Safe Retrieval 契约执行（见 `docs/product/safe_retrieval.md`），并收敛为 **read-oriented** 的网络能力；更宽的网络能力属于危险能力，必须走审批与审计。
- “放权”必须有审批能力与审计记录；并允许事后撤销（禁用 runner/模板/资源）。

---

## 7) Open questions

- prompt cache 的“敏感请求识别”靠什么？（显式标记、启发式、还是按 tool/KB 引用判定）
- 用户个性化设置的边界是什么？哪些属于 system policy 不可被用户覆盖？

补充：

- 是否引入 SharedConversation（协作对话）资源？其成员/权限模型如何与 Space 关系对齐？
