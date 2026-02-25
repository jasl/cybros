# 产品层行为规范（Behavior Spec，Draft）

本文档是产品层的“规范性描述（normative spec）”草案，用于在讨论阶段就把默认行为写清楚、减少口头约定的漂移。

状态：Draft（可随时推翻/重写）。

---

## 1) 术语与字段模型（Scope / Visibility）

术语口径以 `docs/product/terminology.md` 为准（避免不同文档对同一个词的含义不一致）。

规范性要求：

- 资源必须具备 `scope`：`global|space|user`。
- 资源必须具备 `visibility`：`scoped|public`（默认 `scoped`）。
- `scope=space|user` 的资源必须归属到一个 Space（`space_id`）。
- `scope=user` 的资源必须标记 `owner_user_id`。
- system/bundled 资源默认只读、可升级；用户不能直接修改系统版本。如需自定义，应创建新的 user-defined 资源（写入 Agent repo；见 `docs/product/versioning_and_sync.md` 与 `docs/product/terminology.md`）。
- 不建议通过“切换一个 visibility/共享开关”隐式扩大可见性（`visibility=public` 例外用于匿名只读分享页）；若未来引入 `scope=space` 的共享能力，应当以“显式创建新资源 + 审计”实现。

补充（Conversation 的强隐私语义，MVP 规范）：

- Conversation 必须归属到一个 Space（用于隔离与组织）。
- Conversation 视为 `scope=user` 且默认保持私有（owner-only），不提供 `visibility=public`（不提供“共享私聊”开关）。
- 如果需要协作对话/群聊，必须作为独立资源类型实现（例如 GroupChat/SharedConversation），避免误把私聊共享出去。

---

## 2) 系统内置资源的可变性规则

规范性要求：

- 系统内置 Agents 为只读；用户若要自定义，通过“基于模板创建新的 Programmable Agent（Agent repo）”完成（不污染系统版本）。
- 系统内置 LLM Providers / Models / hard limits 仅 admin 可改；所有修改必须记录审计事件。

---

## 3) Agent 自我修改：沙箱内自改 + 可选 git（best-effort）

本阶段结论：**不引入 CR（Change Request）审批流**，也不把“自改”当成特殊的审批域。Programmable Agent 的定义被映射进沙箱（Agent repo workspace），其修改行为与正常 vibe coding 一致：能不能改、能不能执行、能不能联网，交给沙箱策略与会话内的权限交互决定。

规范性要求：

- 用户定义的 Agents / PromptBuilder / Workflow / prompt programs 等资源以文件形式存在于 Agent repo（见 `docs/product/versioning_and_sync.md`）。
- schema validation 属于 best-effort：能验证的配置应在生效前验证；不可验证/可执行扩展的失败必须 **fail-fast**，并在 UI/IM 中给出明确错误与修复选项（例如回滚或切回系统内置 agent）。
- git 是推荐默认值（便于 diff/revert/分享），但系统必须保证在没有 git 的情况下核心逻辑不崩溃（仅降级：缺少历史、diff、revert 等能力）。
- 修改权限必须与 scope 对齐（并受 Space role 约束）：
  - `scope=user`：owner 可改（其余用户不可见/不可改）。
  - `scope=space`：space admin 可改；space member 默认不可改（若未来要支持共享编辑，再补齐规则与审计）。
  - `scope=global`：system admin 可改；非 admin 不可改。

Permission request（UX）：

- 对 Agent repo 的写入/执行不引入独立的 “GitOps 审批”。它们属于正常的 workspace `Write/Edit/Execute`，其交互与 “Auto-allow … in this conversation” 规则见第 6.1 节。

备注：

- “不做 CR”不等于“无恢复”。默认用 git 提供历史与回滚；若未启用 git，则至少应提供“切回系统内置不可变 agents”的救援路径。

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

默认策略（面向 Pro 用户；**默认 Cowork**）：

- `Read`（默认放行）：读取 workspace/资源内容；读取互联网信息（HTTP(S) fetch；必须通过 Safe Retrieval，见 `docs/product/safe_retrieval.md`）。
- `Execute` / `Write`（Cowork 默认自动）：对 **标准沙箱动作** 默认不弹审批卡（等价于会话级 auto-allow）。
  - 标准沙箱动作（规范性倾向，Phase 1 最小集合）：
    - sandbox profile = `untrusted`（强隔离）
    - 单 workspace 挂载（project workspace 或 agent repo；不跨挂载）
    - 无 secrets 注入、无宿主 IO、`NET=NONE`（bash 无网络；互联网读取仅通过 Safe Retrieval）
    - 有明确的资源上限（CPU/mem/disk/time/output）
- **Plan gate（默认开启）**：当一个 turn 需要执行任何 `Execute/Write/Edit`（即产生副作用）时，必须先向用户展示计划（plan）并获得一次性 “Start Cowork run” 确认；确认后才允许在该 turn 内对标准沙箱动作自动放行（见下文 6.1.1）。

Permission request（UX，规范性倾向）：

- 对需要审批的动作，在审批卡片上必须提供三种决策：
  - `Allow once`：仅批准本次动作。
  - `Auto-allow <kind> in this conversation`：本会话内自动批准后续同类动作（建议按“动作类型 + 作用域”区分，避免误把自改/配置写入也放开）：
    - `Auto-allow workspace executes in this conversation`
    - `Auto-allow workspace writes in this conversation`
  - `Reject`：拒绝本次动作。
  - `Auto-allow` 是会话级开关，必须满足：
    - UI 必须持续显示显式标记，并提供一键关闭入口（关闭后立即生效）。
    - 审计中必须区分 “manual approval” 与 “auto-allowed (conversation)”。
    - `Auto-allow` 仅覆盖“标准动作”，不应自动批准权限升级：当某次请求涉及额外危险能力（例如宿主读写、secrets 读取、私网访问、unrestricted network、扩大文件挂载范围、启用 external MCP server、启用内部查询 API 等）时，即使已开启 `Auto-allow` 也必须重新 ask，并把“能力变化摘要”展示在审批卡片上。

#### 6.1.1 Cowork 的 Plan gate（规范性要求）

目的：在“默认 Cowork 自动执行”的前提下，给用户一个**可解释的起跑线**，避免模型在未对齐目标/风险/边界时就开始产生副作用。

规范性要求：

- Plan gate 只在 “本 turn 将产生副作用” 时触发：
  - 纯 `Read` turn 不需要 plan gate。
  - 一旦该 turn 需要 `Execute/Write/Edit`，必须先出 plan，再请求 “Start Cowork run”。
- Plan gate 的确认不等于能力升级：
  - 仅意味着：在 **标准沙箱动作** 边界内，允许该 turn 内无人值守连续执行；
  - 任何能力升级（secrets/host IO/private/unrestricted network/跨 workspace 挂载等）仍必须走单独的 permission request。
- UI（最低要求）必须能让用户看到：
  - 计划步骤（step list，含验证步骤）
  - 目标 workspace 与 sandbox profile（至少 `untrusted` 标识）
  - 资源上限摘要（time/mem/disk/output）
  - 明确提示“执行中如需能力升级仍会弹出审批”

补充（产品形态提示）：

- “Cowork（会话级无人值守）/Evolution（自改）”等模式本质上是对 `Auto-allow` 的产品化包装与信任阶梯设计，规范草案见 `docs/product/programmable_agents.md`。
- Automation runs 没有在线用户点击确认：启用 Automation 视为对其“预授权范围”内副作用执行的起跑线确认；每次 run 仍应生成 plan 以便可观测与回放，见 `docs/product/automations.md`。

#### 6.1.2 Permission rules（Wildcard patterns + Tool-specific rules，建议补齐）

动机：仅靠 “Allow once / Auto-allow <kind> in this conversation” 这类粗粒度开关，容易出现两类问题：

- **太吵**：Manual 模式/高风险空间下审批过多，Pro 用户希望“我只允许 `git status` / `rg` / `bundle exec rails test` 这类命令，不要每次都问”。
- **太粗**：Cowork 默认自动执行时，用户希望“除了某些路径/命令必须 ask 或直接 deny（例如 `.env`、`rm -rf`）”。

因此建议在 Conversation 与 Space 两层都支持 **permission rules**：用可解释的 wildcard patterns 对不同工具做更细粒度的 allow/ask/deny。

> 重要：permission rules 不是安全边界。它们只能在 **core 已决定的 enabled_tools/budgets + sandbox policy** 边界内生效，不能通过规则“偷偷扩权”。

##### (A) 规则层级与存储（建议）

- `conversation` 级规则：默认空；用于本会话临时放行/阻断；可由审批卡片直接添加。
- `space` 级规则：作为 `scope=space` 的可版本化资源（建议：schema validation + 审计；可选支持导出到 git），用于给该 Space 提供“默认权限基线”。

##### (B) 规则语义（规范性倾向）

每条规则 = `effect + tool matcher + specifier`：

- `effect`：`allow | ask | deny`
- `tool matcher`：匹配工具（建议支持 wildcard，例如 `bash`、`read`、`mcp_call`、`*`）
- `specifier`：tool-specific 的匹配条件（可选），用于表达更细粒度约束：
  - 文件类：路径 patterns
  - 执行类：命令 patterns
  - 网络类：domain patterns
  - MCP：server/tool patterns

##### (C) 规则评估顺序（规范性要求）

1) **硬边界先判定**：若该动作超出 sandbox policy / enabled_tools / budgets（例如需要 host IO / secrets / private network / 跨 workspace 挂载），必须走 capability upgrade 的 ask（规则不能绕过）。
2) **deny 优先**：任意匹配 `deny` → 直接拒绝（并返回稳定错误码与安全 details）。
3) **ask 次之**：匹配 `ask` → 必须弹出审批（即使在 Cowork/Auto-allow 下也要 ask）。
4) **allow 其后**：匹配 `allow` → 自动通过（即使在 Manual 下也可减少审批）。
5) **无匹配**：退回到默认模式策略（Manual/Cowork/Evolution + Plan gate）。

补充：

- `Auto-allow <kind> in this conversation` 可视为“生成一组更粗的 conversation-level allow 规则”，但仍必须被 `deny/ask` 覆盖（用于止损）。
- space-level 的 `deny` 必须能覆盖 conversation-level 的 `allow`（团队基线不应被单会话绕过）。

##### (D) Patterns（建议：安全子集）

规范性倾向：

- 只支持 **glob-like wildcard**（`*` / `**` / `?`），不支持用户输入正则（避免 ReDoS 与可执行表达式注入）。
- patterns 必须有长度/条数上限；解析失败必须给稳定错误码（不允许异常外泄）。
- 规则匹配对象应当是“归一化后的 canonical 形态”，避免被空格/引号/路径穿越绕过。

##### (E) Tool-specific 规则（示例，建议）

以下仅展示“表达能力”。产品层建议 **规则在存储时用结构化字段**（便于 schema validation），UI 可把它渲染成 `tool(specifier)` 的紧凑表示。

示例（结构化，YAML）：

```yaml
- effect: deny
  tool: edit
  workspace: project
  path: "/.env"
- effect: ask
  tool: bash
  workspace: project
  command: "rm *"
- effect: allow
  tool: read
  sub_action: web_fetch
  domain: "docs.ruby-lang.org"
```

1) `bash`（命令 patterns）
   - 示例：
     - `allow bash("git status*")`
     - `ask bash("rm *")`
     - `deny bash("curl *")`（配合 Safe Retrieval，避免用 bash 绕开网络限制）
   - 规范性倾向：
     - 解析应当“operator-aware”：`"git status"` 的 allow 不应放行 `"git status && rm -rf /"`。
     - URL/域名限制不要靠 bash patterns 做（脆弱）；网络应优先通过 `web_fetch` 的 domain 规则治理。

2) `read/write/edit`（路径 patterns）
   - 示例：
     - `deny edit("/.env")`
     - `ask edit("/config/credentials.yml.enc")`
     - `allow read("/docs/**")`
   - 路径 patterns 的口径（建议）：
     - 以 workspace root 为基准（`/` 表示 workspace root）。
     - `**` 表示跨目录匹配（例如 `/docs/**`）。

3) `read(web_fetch)`（domain patterns）
   - 示例：
     - `allow read(web_fetch:"docs.ruby-lang.org")`
     - `deny read(web_fetch:"*.example.com")`
   - 备注：最终仍必须满足 `docs/product/safe_retrieval.md` 的硬契约（大小/类型/SSRF 等）。

4) `mcp_call`（server/tool patterns，若对模型暴露）
   - 示例：
     - `allow mcp_call("desktop_commander", "*")`
     - `ask mcp_call("github", "create_issue")`

##### (F) Open questions

- space-level permission rules 是“git-backed”还是“DB 配置”？（git-backed 更可审计/可回滚，但需要 repo 读写链路）
- 是否需要一个 `dont_ask` / “仅 allowlist 模式”（类似 `default=deny`）来做极端保守的空间？
- bash 的 operator-aware 匹配应做到什么程度才算不易绕过？（先做最小安全子集，再逐步增强）

### 6.2 执行侧 policy：危险能力（规范性倾向）

- 仍然遵循 deny-by-default：宿主读写、环境变量注入、secrets 读取、私网访问、unrestricted network 等都必须有 policy 显式授予。
- `Read` 中的“互联网访问”必须通过 Safe Retrieval 契约执行（见 `docs/product/safe_retrieval.md`），并收敛为 **read-oriented** 的网络能力；更宽的网络能力属于危险能力，必须走审批与审计。
- “放权”必须有审批能力与审计记录；并允许事后撤销（禁用 runner/模板/资源）。

---

## 7) Open questions

- prompt cache 的“敏感请求识别”靠什么？（显式标记、启发式、还是按 tool/KB 引用判定）
- 用户个性化设置的边界是什么？哪些属于 system policy 不可被用户覆盖？
- 是否引入 workflow 级 “Persona Router / persona switching”？（动机与规范草案见 `docs/product/persona_switching.md`）

补充：

- 是否引入 SharedConversation（协作对话）资源？其成员/权限模型如何与 Space 关系对齐？
