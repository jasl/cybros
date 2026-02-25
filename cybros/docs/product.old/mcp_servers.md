# MCP Servers（Internal / External）与 DesktopCommanderMCP 集成策略（Draft）

本文档定义 Cybros 在产品层对 MCP 的使用方式，目标是同时满足：

- **强基础能力**：让 Agent 具备“写代码/自动化”任务的必要执行面（文件/进程/搜索/长任务）。
- **工具面收敛**：避免把上百个工具直接暴露给模型，导致可靠性与可观测性变差（以及 prompt 膨胀）。
- **安全默认值**：权限升级必须显式、可审计、可撤销；不要把安全寄托在第三方 MCP 的“目录限制”等软约束。

相关文档：

- 可编程 Agent 语义：`docs/product/programmable_agents.md`
- 沙箱能力需求：`docs/product/sandbox_requirements.md`
- Prompt programs + 内部查询 API：`docs/product/prompt_programs.md`
- 扩展分层：`docs/product/extensions.md`
- DesktopCommanderMCP 调研：`docs/research/ref_desktopcommander_mcp.md`

---

## 0) 结论（当前建议）

- ✅ **Internal MCP server**：作为 Cybros 的“内部 RPC / 工具面”承载形式（尤其用于内部查询 API）。
- ✅ **集成 DesktopCommanderMCP**：但定位为 **foundation 执行面** 的候选实现，运行在沙箱/Runner 内部；不依赖其自身的目录限制作为安全边界。
- ✅ **对模型暴露的工具面仍以少量原语为主**（Read/Write/Edit/Bash + 少量补充），DesktopCommanderMCP 的丰富工具面默认不直接暴露给模型，而由 core 做归一/包装。

---

## 1) 内部/外部 MCP server 的产品边界

### 1.1 Internal MCP server（系统内置、受控）

定义：由 Cybros core/runner 提供、随系统发布/升级的 MCP server。

规范性倾向：

- 仅用于 **系统内部通信**（runner ↔ core，或 prompt program ↔ internal query server），不作为“用户可配置扩展”的主要入口。
- endpoint 必须是 **本地/私有** 的（例如 unix socket、stdio transport、或 runner 私网），禁止暴露到公网。
- tool 必须 allowlist，且每个 tool 有稳定 schema 与稳定 error codes（便于审计/统计）。
- 每次调用都必须能落审计（server/tool/scope/耗时/返回体积等，不落内容）。

Internal MCP server 的两个典型角色：

1) **Foundation（执行面）**：文件/进程/搜索/长任务等底座能力。  
2) **Internal query（数据只读查询）**：KB/Memory 的受控只读查询能力（见 `docs/product/prompt_programs.md` 8）。

> 关键：internal server 是“实现形态”，不是“放权开关”。放权仍由 permission gate + sandbox profile 决定（见 `docs/product/behavior_spec.md` 与 `docs/product/programmable_agents.md`）。

### 1.2 External MCP server（用户安装/第三方、非受控）

定义：由用户安装、可替换、可能运行在宿主机/远端的 MCP server（包括桌面自动化类、第三方 SaaS 连接器等）。

规范性倾向：

- 默认不启用；启用属于 **能力升级**（capability upgrade），必须显式批准并可随时撤销。
- External server 的“目录限制/命令阻断”等通常是 guardrails，而不是安全边界；Cybros 不应把它当成隔离策略（参见 DesktopCommanderMCP 的安全声明）。
- external server 必须进入 tool profile（按组启用），避免在默认 agent 上无限堆叠工具。

---

## 2) 工具面策略：最小原语 + 归一（避免工具爆炸）

我们希望对模型暴露的工具面长期保持“小而稳”，建议策略：

- 模型侧工具：优先暴露 **Read/Write/Edit/Bash** 这样的少量原语（见 `docs/product/programmable_agents.md` 2）。
- 对模型暴露的 tool name 必须满足 tool calling 的命名约束（例如不支持 `.`）；建议统一使用 `snake_case`，并由 Tool Facade 做别名/归一（见 5.1）。
- internal/external MCP 的复杂能力尽量由 core “编译/归一”到这些原语之上：
  - 例如把 `ripgrep` 作为 `read` 的 `search` 子动作的一种实现，而不是暴露一个新的 `ripgrep` 工具；
  - 把“长进程 session”作为 `bash` 的子能力（start/send/kill/list），而不是暴露一组独立工具名给模型。

收益：

- 模型选择更稳定（避免几十个重叠的 file/exec 工具）。
- 权限语义更清晰（Read vs 副作用 vs capability upgrade）。
- 观测与回放更容易（统一的 tool name / error codes）。

---

## 3) DesktopCommanderMCP：如何“集成”而不失控

DesktopCommanderMCP 的优点是：文件/进程/搜索/长任务 + 强审计日志的“一站式执行面”。但它的 SECURITY.md 也明确说明：它的限制更多是 guardrails，而不是 hardened boundary。

因此对 Cybros 的产品层结论是：

### 3.1 定位：foundation 执行面（在沙箱内）

规范性倾向：

- DesktopCommanderMCP 应当运行在 **untrusted sandbox** 或 runner 的受控执行环境中：
  - 只挂载目标 workspace（project workspace），不挂载宿主敏感路径；
  - 禁止把它当成“目录限制能防逃逸”的安全边界；
  - 允许它在沙箱内更自由，但把破坏半径限制在 workspace + 沙箱资源上限内。

### 3.2 暴露策略：默认不把完整工具面直接给模型

建议两种产品策略（择一即可，避免双轨）：

1) **包装（推荐）**：core 只暴露 Read/Write/Edit/Bash；DesktopCommanderMCP 仅作为实现后端。  
2) **工具组（可选）**：把 DesktopCommanderMCP 的工具作为一个可启用的 tool group（例如 `tool_group=desktop_commander`），仅在特定 agent/profile 下显式开启，并对高风险子工具二次 gate。

无论哪种策略，都必须满足：

- permission gate 与 plan gate 语义不被绕过（见 `docs/product/behavior_spec.md`）。
- 审计以 Cybros 的事件为准（DesktopCommander 的日志可作为 debug 参考，但不能成为唯一审计来源）。

### 3.3 默认关闭的“领域能力”（直到有清晰策略）

DesktopCommanderMCP 里与 PDF/Excel/内存执行/远程控制相关的能力，默认建议不开启，直到我们能回答：

- 它们算不算 “标准沙箱动作”？（大概率不是）
- 它们的输入/输出体积与敏感度怎么控？（文件内容、结构化数据、潜在泄露）
- 它们是否需要单独的 tool budget 与审计摘要？（强烈建议）

建议把这些能力作为 Tier 1 sandbox plugin / skills（见 `docs/product/extensions.md` 3.2），并由 admin 明确启用。

### 3.4 “桌面自动化”与 “服务端沙箱”要分开

如果用户想把 DesktopCommanderMCP 跑在宿主机来做桌面自动化（macOS app control 等），那应当被视为 **external MCP server + host profile** 的能力升级：

- 默认不启用；
- 必须显式批准；
- 与 “服务端沙箱（untrusted）” 的默认能力严格区分（避免把桌面自动化混成默认能力）。

---

## 4) Internal query API：用 MCP 做受控只读查询

内部查询 API（KB/Memory）在产品层被视为“高风险只读能力”，其风险不在于写入，而在于：

- 扩大了数据可达范围（尤其是 conversation/memory 的边界容易被写坏）。

规范性倾向：

- 以 **internal MCP server** 的形式提供，工具 allowlist（例如 `kb_search`, `memory_search`, `facts_get`…）。
- 强 scope：所有请求都绑定 `user_id/space_id/conversation_id/turn_id`，由 core 侧 enforce。
- 强限额：每次 prompt build 的最大请求数、最大返回字节数、最大候选数。
- 强审计：记录 method、scope、耗时、返回条数/字节数（不落内容）。
- 默认关闭：仅在 Evolution 或显式启用的 prompt-program profile 下开放（见 `docs/product/prompt_programs.md`）。

---

## 5) 平台级防护：MCP Proxy / Tool Facade（可吸收 Claude.app 思路）

你提到 Claude.app 的“额外平台防护”很诱人。我们认为这类能力 **可以吸收**，并且应当被建模成：

- **平台能力（core/runtime）**，而不是某个第三方 MCP server 的特性；
- **确定性管道（deterministic pipeline）**，而不是 prompt trick。

建议落点：在 MCP server（internal/external）与模型之间插入一个 **MCP Proxy / Tool Facade** 层，拦截 `tools/list` 与 `tools/call`：

### 5.1 `tools/list` 虚拟化（减少工具爆炸 + 减少误用）

规范性倾向：

- **过滤/裁剪**：按 tool profile + policy + sender role（owner-only）裁剪工具集（对齐 OpenClaw 的 profiles/policy 思路）。
- **别名与规范化**：允许把多个底层工具归一到更稳定的名字（例如把不同实现的 search/exec 归一），减少模型“选错工具”的概率。
- **描述前缀/风险提示**（可选）：平台可对危险工具追加统一前缀（例如“requires approval / writes files / network”），用于提高模型自我约束与用户可解释性（注意：这不是安全边界，只是 UX + 可靠性辅助）。
- **Schema 清洗**：对不同 provider 的 tool schema 兼容性做 deterministic 变换（OpenClaw 有类似实践：按 provider 清洗 JSON Schema，避免被 provider 拒绝）。

### 5.2 `tools/call` 拦截（把“防护”做成执行前的确定性校验）

规范性倾向：

- **参数校验**：严格 schema validation + 参数归一化（禁止 silent coercion），失败返回稳定 error codes。
- **权限/能力 gate**：在真正执行前对齐 permission gate 与 capability upgrade（即使模型“看到了工具”，也不能绕过审批与 policy）。
- **预算与限额**：对 tool args size、输出 bytes、tool call count、并发、walltime 做 hard caps（避免“工具调用把系统拖死”）。
- **路径与 scope**：所有文件/进程/网络操作都必须绑定 workspace/scope；跨 workspace 属于能力升级。
- **输出校验**：对工具输出做基本的 shape/size 校验与截断（避免把不受控大输出灌回 LLM）。

### 5.3 Prompt/模板类响应校验（降低“扩展注入 prompt”的风险）

Claude.app 的一个关键点是：对扩展返回的 prompt 响应做模板匹配校验（只有“已声明模板 + 参数替换”的结果才允许通过）。

对 Cybros 的映射建议：

- 我们不一定需要引入“扩展 prompt 响应”这种能力，但凡涉及“外部扩展能影响 prompt 组装”，都应当遵循：
  - **声明式模板 + 参数化**（模板是 source-of-truth）
  - **平台侧校验**（输出必须匹配模板渲染结果）
  - **失败即拒绝/回退**（避免 prompt 注入与不可诊断行为）
- prompt programs 的输出校验 + fallback（见 `docs/product/prompt_programs.md`）本质上就是同一类思想：把“可执行扩展”变成可验证的协议。

### 5.4 MCP server 托管运行时（生命周期、隔离与日志）

规范性倾向：

- **受控启动**：平台负责启动/停止/restart MCP servers（而不是让 agent 通过 `bash` 自己拉起常驻进程）。
- **日志分离**：协议输出与日志严格分离（stdout 仅 JSON-RPC；stderr/log file 用于 debug），避免污染协议。
- **生命周期策略**：ephemeral vs keep-alive（按 server/profile 配置）；keep-alive 需要额外的资源预算与 kill switch。
- **隔离优先**：external MCP server 默认运行在沙箱（或受控 sidecar），避免把 host 变成“默认工具执行面”。

> 参考：Claude.app 的 MCP 托管与拦截机制（见 `docs/research/ref_claude_desktop_app.md`）。

---

## 6) Open questions（需要尽早收敛）

- DesktopCommanderMCP 作为 foundation backend 的“最小启用子集”是什么？（文件/搜索/exec/session vs PDF/Excel）
- internal MCP server 的 transport 选择：stdio vs unix socket vs runner 私网？（目标：易调试、易审计、默认不暴露）
- external MCP server 的“启用与审批”粒度：按 server enable、按 tool group enable、还是按具体 tool call gate？
- MCP Proxy / Tool Facade 的最小实现边界是什么？（Phase 1 先做 tool policy + schema validation + 预算 hard caps；其余后移）
