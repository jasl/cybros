# 术语表与资源模型（Glossary，Draft）

本文档为 `docs/product/*` 提供统一术语，避免“同一个词在不同文档里含义不同”导致实现跑偏。

状态：Draft（可随时推翻/重写）。

---

## 1) 核心实体

- **Instance**：一次 self-hosted 部署出来的 Cybros 服务。
- **Space**：组织/团队/项目空间；资源隔离与协作边界；当前是**软单团队**（Phase 1 只有 1 个默认 Space）。
- **User**：实例内用户；可加入多个 Space；当前是**软单用户**（Phase 1 默认只有 1 个用户）。
- **Conversation**：强隐私的对话资源（背后 attach DAG graph）；属于某个 Space，但默认始终为 user-scope（见 4）。
- **Resource**：可被创建/修改/复用的对象（AgentProfile、Workflow、MCP config、KB、Sandbox/Workspace…）。
- **Persona**：一种可切换的“对话行为配置”（风格/策略/工具倾向/模型偏好等）。建议把 persona 作为 workflow 的一个阶段（Persona Router）或作为 AgentProfile 的变体来实现（见 `docs/product/persona_switching.md`）。
- **Workspace（执行工作区）**：Runner/Sandbox 内的文件系统边界，用于承载“被操作的对象”（例如项目仓库）或“可变资源仓库”（Agent repo）。Workspace 必须可被限制（路径穿越/符号链接逃逸不可越界），并支持重建/清理（见 `docs/product/sandbox_requirements.md` 与 `docs/product/programmable_agents.md`）。
- **Sandbox / Executor（执行环境/执行节点）**：用于运行命令与文件操作的隔离环境与其宿主节点；实现可以是容器/microVM/VM/host exec，但在产品层必须可表达能力与限制（net/fs/secrets/limits），并与 permission gate 对齐（见 `docs/product/sandbox_requirements.md` 与 `docs/execution/execution_subsystem_design.md`）。
- **Sandbox profile（信任档位）**：面向用户的执行安全层级（例如 `untrusted/trusted/host`）；用于把“放权”变成显式升级（可审计、可撤销），而不是隐式行为变化（见 `docs/product/programmable_agents.md`）。
- **Permission rules（权限规则 / PermissionProfile）**：用于 tool calls 的细粒度 allow/ask/deny 规则，支持 wildcard patterns 与 tool-specific specifiers（命令、路径、域名、MCP tool 等），并在 `space` 与 `conversation` 两层生效（见 `docs/product/behavior_spec.md` 6.1.2）。
- **Prompt program（Prompt 程序）**：在沙箱内运行的 prompt building 程序（可版本化、可同步 GitHub），用于输出结构化 prompt spec；输出必须被 core 严格校验并具备 fallback（见 `docs/product/prompt_programs.md`）。
- **MCP server**：通过 MCP 协议向 Agent 暴露一组可调用工具（tools）的服务端实现；可以是系统内置或用户安装的外部服务。
- **Internal MCP server**：系统内置、受控的 MCP server，用于系统内部能力（foundation 执行面、内部查询 API 等）；默认不作为用户扩展入口，且必须本地/私有可达、强审计（见 `docs/product/mcp_servers.md`）。
- **External MCP server**：用户安装/第三方的 MCP server（可能运行在宿主机或远端）；默认不启用，启用属于能力升级，需要显式批准与可撤销（见 `docs/product/mcp_servers.md`）。
- **Internal query API（内部查询 API）**：由 core/runner 暴露给沙箱程序的受控只读查询能力（例如 KB/Memory search），必须强 scope、强审计、限流限额且默认关闭；用于支持 prompt programs 等需要检索但不应获得“任意内网/数据库访问”的场景（见 `docs/product/prompt_programs.md`）。
- **Facts（有限 KV 存储）**：规模受限的结构化“事实/常量/偏好”存储（key-value），用于替代“用向量检索猜小事实”的不确定性；推荐以 git-backed YAML/JSON 存放并可回滚；读取可通过 `context_bundle` 注入或 internal query（只读），写入必须走 permission gate（见 `docs/product/prompt_programs.md` 8.1）。
- **DesktopCommanderMCP**：一个提供文件/进程/搜索/长任务等能力的 MCP server；对 Cybros 的建议定位是“foundation 执行面”的候选实现，但不应被当作安全边界（见 `docs/product/mcp_servers.md` 与 `docs/research/ref_desktopcommander_mcp.md`）。
- **Channel（渠道）**：对话的外部入口/出口（WebUI、Telegram、Discord…）；渠道决定消息的 ACK/进度/最终回传语义与格式约束（见 `docs/product/channels.md`）。
- **Agent UI / App mode（Agent 驱动 UI）**：agent 以声明式协议生成可交互 UI（表单/仪表板/可视化等），由客户端用白名单组件渲染；权限审批 UI 必须由 core 渲染以避免 spoofing（见 `docs/product/agent_ui.md`）。

---

## 2) Resource：scope 与 visibility（两个正交维度）

### 2.1 `scope`（归属层级 / 拥有边界）

`scope` 用于表达“资源属于谁、由谁管理、默认在什么边界内可见/可用”。

- `global`：实例级资源（对该实例内所有用户生效/可见；由 system admin 管理）。UI 文案可显示为 “System”。
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
- share page 可以提供“导入为自己的资源 / Open in app”等入口，但这些入口本身不应触发执行与写入。

---

## 3) Resource 的来源与可变性（建议术语）

同一个 scope 下，资源仍可能有不同的“来源/可变性”：

- **Bundled / System-provided**：随 core 或插件安装进入系统；默认只读、可升级；用户若要自定义，应创建新的 user-defined 资源（写入 Agent repo），而不是修改系统版本。
- **User-defined**：由用户创建/维护（git-backed Agent repo）；可编辑、可版本化、可回滚。

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

- `scope`：`global|space|user`（见 2.1）。
- `visibility`：`scoped|public`（见 2.2）。
- `space_id`：
  - `scope=space|user`：必须存在
  - `scope=global`：必须为空（或约定为 NULL）
- `owner_user_id`：
  - `scope=user`：必须存在
  - `scope=global|space`：必须为空（或约定为 NULL）
- `public_share_token`（或单独 ShareLink 表）：
  - `visibility=public`：必须存在
  - `visibility=scoped`：必须为空

---

## 6) Open questions

- 公开分享的最小审计策略：是否记录匿名访问日志？如果记录，保留多久？（默认倾向：不记录或只做聚合计数，避免引入隐私负担）
- share token 的撤销/轮换语义：撤销是否必须导致旧链接立刻失效？是否允许生成多个 share links？
