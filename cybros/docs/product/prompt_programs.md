# Prompt programs（沙箱内 Prompt Building，Draft）

动机：Pro 用户的定制需求往往集中在：

- Agents 的提示词组装（PromptBuilder 的章节/顺序/条件/预算）
- 工作流与渠道行为（例如 IM bot “先回复收到，再继续运行”）
- 针对 Telegram bot 的回复文案与格式

我们已经有 “声明式 DSL + git-backed + schema validation + revert” 的路径（默认推荐）。但当 DSL 难以覆盖时，可以提供一个 **受控的逃生舱**：把 prompt building 的一部分 off-load 到沙箱运行的程序（prompt program），使其天然可编辑、可版本化、可导出与分享（GitHub repo / archive）。

立场（怀疑视角）：

- prompt program = **高风险能力**（可靠性/可诊断性/供应链/多用户隔离都更难）。
- 只应作为专家/演进能力（Evolution），并且必须有严格的输出校验与 fallback，否则会出现“改坏即无法对话”的灾难模式。
- 我们将提供一套 **first-party prompt-program 程序**作为基线：核心程序尽量稳定，主要可变性外移到模板与配置（开闭原则）。

---

## 1) 定义：Prompt program 是什么 / 不是什么

### 1.1 是什么

Prompt program 是一个在沙箱内执行的命令（脚本/二进制/容器任务均可），其职责是：

- 输入：一个结构化 `PromptBuildInput`（JSON）
- 输出：一个结构化 `PromptSpec`（JSON）

`PromptSpec` 最终被 core 用于一次 LLM 调用（messages/tools/budgets 的可解释组合）。

### 1.2 不是什么

- 不是“在 Rails 主进程执行用户代码”（禁止）。
- 不是权限边界：它不能改变 permission gate、不能打开 secrets、不能扩大网络/挂载范围。
- 不应承担“渠道层 ACK/进度回传”的职责：ACK 属于 channel/workflow（见 `docs/product/channels.md`），否则会把 prompt building 与消息投递耦合得不可维护。

---

## 2) 两条路线：DSL（默认）vs Prompt program（专家）

### 2.1 Route A：声明式 PromptBuilder DSL（默认推荐）

优势：

- 可验证（schema）
- 可回滚（git）
- 可诊断（每段注入/预算可解释）
- 不引入额外执行面（更少故障源）

### 2.2 Route B：Prompt program（专家/演进）

适用场景：

- 需要复杂的条件/路由/预算算法（DSL 不好表达）
- 希望把 prompt building 作为“可执行扩展”与代码一起演进（git + GitHub 导出/分享）

代价：

- 需要额外的运行时承诺（脚本语言/依赖/构建）
- 更难做确定性与 debug（必须强制观测与错误码）
- 多用户/共享场景需要更严格的 trust boundary（space admin 才能启用）

结论（规范性倾向）：

- Phase 1 只做 Route A。
- Phase 2+ 才引入 Route B，且默认关闭、显式启用。

---

## 3) 接口契约（必须严格）

### 3.1 PromptBuildInput（输入）

输入必须是 JSON，且包含最小集合（示例字段）：

- `schema_version`
- `space_id/user_id/conversation_id/turn_id`
- `channel`（web/telegram/discord/…）
- `now`（时间戳 + 时区）
- `selected_persona_id`（若启用 Persona Router）
- `user_message`（本 turn 的用户输入）
- `history_window`（已经裁剪后的消息窗口；避免 program 自己扫描全量历史）
- `enabled_tools`（core 已决定可用的工具集合；program 只能在其子集内选择）
- `budgets`（context/output/token/timeout 等上限）
- `context_bundle`（可选：core 预先检索/挑选的 KB/memory/doc snippets；默认推荐由 core 注入，避免 program 自己联网/跑检索）

关键约束：

- program 不应被允许读取“全量 Conversation/DAG”或任意数据库；输入必须是 core 明确选择后的窗口与 bundle。

### 3.2 PromptSpec（输出）

输出必须是 JSON，至少包含：

- `schema_version`
- `messages`（最终用于 provider 调用的 messages 列表）
- `debug`（可选：section breakdown、预算占用、选择原因；不进入 LLM prompt）

规范性要求：

- 输出必须可被 core 做 schema validation。
- 输出必须可被 core 做预算校验（messages 总大小、段落上限、tool schema 体积等）。
- 输出不得携带 secrets（core 也不得把 secrets 放进 input）。

### 3.3 校验、失败处理与回退（硬要求）

core 必须：

- 对输出做严格校验（schema + budgets + allowed roles + tool subset）。
- 对“执行失败”与“校验失败”都做可观测（稳定 error codes + safe details）：
  - 执行失败示例：exit code 非 0、timeout、stdout 非法 JSON、输出过大、违反 budgets 等。
  - 校验失败示例：schema 不合法、messages 超预算、试图选择未启用工具等。
- 失败时必须提供 **可恢复路径**，并且不能让系统进入“无法继续对话”的状态：
  - **默认建议（fail-fast，偏透明/可诊断）**：不要继续回答原问题；立即进入 remediation flow，让用户选择如何处理（禁用/回滚/切换内置 Agent 等）。为保证系统可继续交互，该 remediation flow 必须由 core 的内置逻辑驱动（不能依赖当前 prompt program 成功）。
  - **可选策略（auto-fallback，偏低打断/高可用）**：本 turn 自动降级到内置 DSL（或 `last_known_good`）生成 PromptSpec 并继续回答，但必须在 UI/渠道里醒目标记“发生了降级”，并提供同样的 remediation 选项（见下）。

实现注记（避免语义漂移）：

- 无论采用 fail-fast 还是 auto-fallback，系统都必须记录“本次实际使用的 prompt builder”（见 `docs/product/observability.md`），否则排障会变得不可能。
- `fail-fast` 的语义是“停止回答原问题”，不是“系统不能发消息”：系统仍必须能输出一条可操作的 remediation 提示/卡片。

失败后的“如何处理”（UX，规范性倾向）：

- 在 WebUI 中弹出一张明确的 remediation 卡片（不属于 permission gate），让用户选择：
  - `Keep using (retry next turn)`：保留当前版本，下次再试（适合偶发 timeout/资源不足）。
  - `Disable prompt program (use built-in DSL)`：禁用该 conversation/agent 的 prompt program，回到内置 DSL。
  - `Rollback to last known good`：回滚到上一个可用版本（git revert / 切换指针；产生审计事件）。
  - （可选）`Switch to built-in agent`：切换到系统内置 AgentProfile（救援艇）。
- 在 IM 渠道中：至少要能发送一条“失败提示 + 可选指令/按钮”的消息（例如提示使用 `/sos ...` 进入救援流程，见 `docs/product/channels.md` 5）；是否同时给出“降级后的主回复”取决于所选 failure policy（fail-fast vs auto-fallback）。

> 目标：prompt program 永远不能成为“把系统搞死”的单点失败。

---

## 4) 执行与隔离（必须比 skills 更谨慎）

建议默认执行 profile（由 Runner/沙箱策略 enforce；prompt program 不能自行放宽）：

- `NET=NONE`（禁止联网，避免直接外传与不稳定依赖）
- 只读挂载：program 自身目录 + 必要的只读资源（例如 prompt templates）
- 禁止 secrets 注入
- 严格资源限制：CPU/mem/time/max_output_bytes

若确实需要访问 KB/Memory（两种模式都可以存在，需要按延迟与复杂度权衡）：

- `context_bundle`（core 预取注入）：低延迟、易审计、实现简单；缺点是 prompt program 不能自行发起多轮检索。
- internal query API：更灵活，但需要强限额/强审计/更复杂的调试与限流；仍应视为 capability upgrade（默认关闭）。该 API 的目标是让 prompt program 能查询知识库/记忆，但不获得“任意数据库/全量对话”的读能力（见第 8 节）。

---

## 5) 版本化与 GitHub 导出（落点）

Prompt programs 作为 git-backed 资源的一部分存放在 Agent repo（示例路径）：

- `prompt_programs/<name>/...`

规则：

- 仅 Agent repo owner 可启用与修改（降低“共享 program 影响他人对话行为”的风险）。

GitHub 导出与分享（Phase 2）：

- 与 Agent repo 导出策略一致（见 `docs/product/versioning_and_sync.md`）。

---

## 6) First-party prompt-program（官方基线程序，开闭原则）

你已决定：我们需要提供 prompt-program 的整套程序作为“基线能力”，并尽可能遵守开闭原则：

- **程序本体尽量稳定**（升级由 core/插件发布）
- **Prompt 模板尽量代码外置**（由文件/模板语言承载，可被 git 版本化并导出/分享到 GitHub）
- 用户若要“魔改”，优先改模板/配置；需要改程序本体时再 fork（代价与风险由用户承担）

### 6.0 实现形态（已确定）

官方基线 prompt-program 以 **脚本** 形态交付，并提供一个 **Ruby 参考实现**（因为 Cybros 本体是 Ruby/Rails，利于统一规范与维护）。

但协议层保持语言无关：任何语言的实现只要遵守 `PromptBuildInput -> PromptSpec` 的 JSON 契约即可被执行侧调用。

### 6.1 推荐交付形态（Tier 1 sandbox plugin / first-party bundle）

建议把官方 prompt-program 作为 Tier 1（Sandbox plugin）交付：

- core 安装/升级该 bundle（system install）
- 用户可以在自己的 Agent repo 中创建/启用用户版本再改（不污染系统版本）

### 6.2 模板语言（建议：Liquid 默认 + ERB 可选）

为了在“安全/可预测”与“可表达”之间取平衡：

- **Liquid**：建议作为默认模板语言（表达受限但更可控）
- **ERB**：可作为可选/专家模式（模板即代码；必须明确风险与资源限制）

> 二者都只是在沙箱内执行，并不改变权限边界；但 ERB 的“可执行性”会显著增加维护与故障面。

### 6.3 模板与配置的推荐结构（示例）

Agent repo 内建议形成一个“可导出、可回滚、可解释”的目录：

- `prompt_programs/<name>/`
  - `prompt_program.yml`（声明入口命令、模板语言、模板路径、参数）
  - `templates/`（Liquid/ERB 模板文件；支持 partials/includes）
  - `schemas/`（可选：用于约束输出 `PromptSpec` 的附加 schema/断言）

官方程序只需要知道“如何加载模板并渲染为 PromptSpec”，而不把业务 prompt 写死在代码里。

### 6.4 内置扩展点（建议）

为减少“用户必须改程序代码”的概率，官方程序应当至少提供这些扩展点：

- section templates（system/developer/user/history/tools/budgets…）
- 可配置的 prompt order（章节顺序）
- 可配置的 channel adapters（同一 PromptSpec 在 web/telegram 下的微调；但 **不负责 ACK**）
- 可配置的 redaction / truncation 策略（确保预算与安全）

注意：ACK/Progress/Final 模板不属于 prompt-program；应当属于 channel/workflow（见 `docs/product/channels.md`）。

---

## 7) 运行协议（建议：STDIN/STDOUT JSON + 稳定错误码）

为了让脚本实现可被多语言复用，建议约定一个极简、可测试的运行协议：

- 输入：`PromptBuildInput` 作为 JSON 写入 STDIN
- 输出：`PromptSpec` 作为 JSON 写入 STDOUT
- 成功：exit code = 0
- 失败：exit code != 0，且必须输出一个稳定的 `error_code`（可 JSON 写入 STDERR，或写入 STDOUT 的 error envelope；但必须在 spec 中固定一种方式）

规范性倾向：

- 输出必须是“可机器解析”的：禁止在 JSON 之外混入日志文本（避免污染解析）。
- 错误 details 必须 safe（不包含 secrets / 大段对话内容）。
- core 侧永远以 “校验 + fallback” 兜底（见 3.3）。

---

## 8) 内部查询 API（受控、只读、默认关闭）

你倾向的方向是：允许 prompt program 通过一个受控的内部查询 API 访问 KB/Memory（而不是只能靠 core 预取 `context_bundle`）。

风险（必须明确）：

- 这是一个新的数据出入口：一旦 API 过宽，会变相把“沙箱程序”变成“可读系统内部数据的客户端”，扩大数据外传面。
- 也更难调试与限流：prompt program 可能在一次 build 中发起多次查询，拖慢整体 latency。

因此规范性倾向：

- API 必须是 **只读**，且方法必须 allowlist（例如 `kb_search`, `kb_get_snippets`, `memory_search`, `facts_get`）。
- 必须强 scope：所有查询都绑定 `user_id/space_id/conversation_id/turn_id`，并由 core 侧按 scope 过滤。
- 必须强审计：记录方法名、scope、耗时、结果条数/字节数（不落内容）。
- 必须限流与限额：每次 prompt build 的最大请求数、最大返回字节数、最大候选数。
- 默认关闭：只有在 Evolution 或显式启用的 prompt-program profile 下才开放。

### 8.1 Facts（有限 KV，用于“事实”）（Draft）

除了记忆系统（通常更适合非结构化、可检索的长文本），我们可以提供一个**规模有限**的 KV 存储用于存放“事实/常量/偏好”，典型例子：

- `user_preferred_name` / `user_timezone` / `project_repo_url` / `default_branch`
- “不应该靠向量检索猜”的小事实：直接 key lookup 更可靠、更便宜

规范性倾向（把边界说清）：

- facts 不是“对话日志”，也不替代 memory；它更像一个可审计的结构化设置/事实表。
- 必须有严格的体积上限（keys 数、单 value bytes、总 bytes），避免变成隐形数据库。
- 写入属于持久化副作用：建议走 permission gate（并尽可能落审计）；默认不自动写入（通常只在 Evolution 下允许更激进的自动化）。

落点建议（与 Agent repo 版本化对齐）：

- facts 作为 git-backed 资源（YAML/JSON）存放在 Agent repo（便于 review/diff/revert）。
- prompt program 的读取方式：
  - core 预取注入到 `context_bundle`（低延迟），或
  - 通过 internal query API 读取（例如 `facts_get`；只读、强 scope、强限额）。
- prompt program 本身不应拥有“通过内部查询 API 直接写 facts”的能力（内部查询 API 默认为只读）。
- facts 的更新应通过对 Agent repo 文件的普通写入完成（可选 git 版本化；便于 review/diff/revert）。

实现落点（✅ 已决定）：

1) **Internal MCP server**：由 core 提供一个只读 MCP server（或 MCP-like 协议），prompt program 通过 runner 暴露的本地端点访问；统一复用工具 schema、审计与 policy。
   - 建议把“内部查询工具”作为一个独立的 internal server（而不是复用执行/文件类 server），以便做最小 allowlist 与单独的限流/审计策略。
   - internal MCP server 的整体策略（internal vs external、以及 DesktopCommanderMCP 的集成方式）见 `docs/product/mcp_servers.md`。

明确不做（Phase 2+ 仍不建议开启双栈）：

- **HTTP JSON API**：除非 MCP 被证明无法满足需求，否则不引入第二套并行协议与审计面；否则会导致“同一能力两套实现”带来长期维护与安全差异。

与 Safe Retrieval 的关系：

- 内部查询 API 不等同于联网；但它同样是“数据外传”的前置环节，必须与 permission/policy 的危险能力升级对齐。

---

## 9) Open questions

- ✅ 已决定：官方 prompt-program 以脚本形态交付，并提供 Ruby 参考实现；协议保持语言无关。
- 官方 prompt-program 是否提供官方 image/profile（包含 Ruby/依赖/模板运行时），还是只提供脚本并要求用户自行准备运行时？
- 输出 `PromptSpec` 是否允许声明“工具子集/工具组”？如何避免变相绕过 tool policy？
- ✅ 已决定：受控内部查询 API 以 **Internal MCP server** 形态提供（只读、强 scope/审计/限流、默认关闭）。
