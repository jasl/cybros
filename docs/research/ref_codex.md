# 参考项目调研：Codex CLI（references/codex）

更新时间：2026-02-21  
调研对象：`references/codex`  
参考版本：`64f3827d109c`（2026-02-20）

注（2026-02-22）：本仓库已在 AgentCore 落地 `Policy::PatternRules` / `Policy::PrefixRules` / `Policy::ToolGroups`；但 app 层“已批准规则”的持久化与注入仍未实现（见 `docs/research/gap_analysis.md`）。

## 1) 项目定位与核心形态

Codex CLI 是 OpenAI 的本地 coding agent harness：在用户机器上运行，通过 LLM 生成计划、调用工具（读写文件/执行命令/应用补丁）、并在必要时请求用户审批。

在架构上，它把“UI（TUI/IDE）”与“核心引擎（Codex daemon）”明确分离，并用一个协议层定义 `Session/Task/Turn` 与事件流（见 `references/codex/codex-rs/docs/protocol_v1.md`）。

## 2) Agent Loop / 调度模型

关键概念（Codex 的术语）：

- **Session**：配置与状态（含 last_response_id bookmark）
- **Task**：由一次用户输入触发的工作单元；内部包含多个 **Turn**
- **Turn**：一次“LLM 调用 → 工具执行/补丁应用 → 输出/继续”的循环；Turn 输出作为下一 Turn 输入
- **单会话单任务**：同一个 Session 同时最多跑 1 个 Task；需要并行任务建议开多个 Codex 实例

对 Cybros 的映射：

- Cybros 的 `turn_id` 语义与 Codex 的 Turn 接近；DAG 的 tool loop 会在同一 `turn_id` 下生成 task 节点并推进下一次 agent_message（这点与 Codex 的“turn output feeding”一致）
- Codex 的 `last_response_id` 是“provider thread bookmark”；Cybros 当前是“DAG 组装上下文再发给 provider”。若要获得类似“bookmark 继续线程”的优势，可考虑在 provider adapter 层把 `response_id` 持久化为 node metadata（可选增强）

## 3) Prompts（系统提示词）与上下文管理

Codex 把 prompt 作为仓库内文件维护，并按模型/模式加载（例：`references/codex/codex-rs/core/prompt.md`、`references/codex/codex-rs/protocol/src/prompts/**`）。其系统 prompt 的特征：

- 把“工具用法/输出格式/计划/安全/测试哲学”等写成非常明确的操作手册
- 强调“持续迭代直到完成”“工具调用前给 preamble”“按 repo AGENTS.md 约束编码风格”等
- 对“沙箱/审批/升级执行”有专门的系统提醒（approval policy）

上下文预算与压缩：

- `ModelInfo` 里包含 `context_window`、`auto_compact_token_limit`、`effective_context_window_percent`（见 `references/codex/codex-rs/protocol/src/openai_models.rs`）
- 这与 Cybros 的 `runtime.context_window_tokens / reserved_output_tokens / auto_compact` 高度同构（Cybros 已实现“超预算 → 丢 memory → 缩窗 → auto_compact summary”）

## 4) Tools、审批与沙箱（Codex 的“强约束”特色）

Codex 的一个显著特色是把“工具执行安全”做到非常工程化：

1. **审批策略（approval policy）+ prefix rules**
   - 支持“请求用户批准某条命令”，并建议持久化一个更泛化的 prefix rule（见 `protocol/src/prompts/permissions/approval_policy/on_request_rule.md`）
2. **沙箱与升级执行**
   - 在受限沙箱内运行命令；遇到需要写/网/危险命令时可升级（escalation）
3. **execve 拦截的 shell MCP（更强的安全语义）**
   - `@openai/codex-shell-tool-mcp` 通过拦截 `execve(2)` 获得“真实可执行路径”，用 `.rules` 精确控制 allow/prompt/forbidden（见 `references/codex/shell-tool-mcp/README.md`）

对 Cybros 的启发：

- Cybros 现有 `tool_policy` 已支持 `allow/deny/confirm(required/deny_effect)` 与 `awaiting_approval` gate；并已补齐 `Policy::PrefixRules`（前缀规则）、`Policy::PatternRules`（参数模式规则）、`Policy::ToolGroups`（工具组展开）。但仍缺少：
  - app 层“prefix rule/已批准规则”的持久化与 prompt injection（按 user/account/conversation scope）
  - 对 shell/exec 的“真实路径解析与拦截”（若要达到 Codex 的强保证，需要外部 sandbox runtime 或集成 codex-shell-tool-mcp）

## 5) 记忆（Memory）系统

Codex CLI 更偏“coding harness”，其“记忆”主要来自：

- 工作区文件内容（读文件）
- Session 的 response_id bookmark（继续线程）
- conversation summaries（用于 UI 列表/回顾；不是典型 RAG）

对 Cybros：我们的 pgvector memory 更像 OpenClaw/Memoh/Risuai 那套“长期记忆”。若要复刻 Codex 的体验，memory 不是关键短板，关键在**安全工具执行与 UX 协议**。

## 6) 在 Cybros 上实现的可行性评估

### 能做到（现有底座基本覆盖）

- tool loop（LLM → tool_calls → tasks → next LLM）与审批 gate（awaiting_approval）
- streaming 输出（node events output_delta）
- token budget + auto_compact（summary 节点）
- MCP 工具接入（可把 shell-tool-mcp 当作工具来源）

### 需要补的能力（建议优先级）

P0（平台能力）：

- **Policy profiles + prefix rules**：把“用户批准过什么”变成可持久化规则，并在 policy authorize 时生效
- **Context pruning（工具结果裁剪）**：Codex/类 Codex 会话长跑时可降低上下文膨胀

P1（运行时/产品形态）：

- **强沙箱执行**：集成 codex-shell-tool-mcp 或自研 container exec runtime（网络/路径/写权限控制）
- **协议化 UI 事件流**：Codex 的 protocol_v1 对 UI/daemon 的契约很清晰；Cybros 若要做“coding CLI/IDE 插件”，可参考其事件模型（turn started/complete、approval request、plan delta 等）

## 7) 建议的落地路径（如果要做“Cybros 的 Codex-like 实验”）

1. 先在 Web UI 里做：`agent_message` + `task` + `awaiting_approval` 的基本交互（我们已有 DAG API 支撑）
2. 已补 `Policy::PrefixRules`（P0）；下一步把审批从“每次问”升级为“可授予能力范围”的关键是 app 层规则持久化与注入
3. 将 shell/exec 切换为“受控 MCP shell”（P1）：优先复用 `codex-shell-tool-mcp` 作为强安全层
4. 再考虑做 CLI/IDE：把 DAG node events 映射到协议事件（可借鉴 Codex protocol_v1）

## 8) Skills、MCP、tool calling：如何避免“膨胀”与“选择困难”

Codex 的整体策略更偏“**能力可控 + 安全可解释**”，其对“膨胀”的治理更多体现在 **减少歧义**，而不是“把所有东西都塞进 prompt”：

- **避免同类工具重叠**：`codex-shell-tool-mcp` README 明确建议禁用默认 shell tool，保证只有一个“shell-like”工具可用（减少模型在多个近似工具之间摇摆的概率）。
- **Skills 作为可复用流程包**：Codex 的记忆/巩固模板里把 skills 定义为目录包（`skills/<skill-name>/SKILL.md` + scripts/templates/examples），并明确提出“SKILL.md 要短、细节放 supporting files、避免 do-everything skills”等规则（见 `references/codex/codex-rs/core/templates/memories/consolidation.md`）。这是典型的“把可复用程序从 prompt 里外移”的做法。

对 Cybros：如果后续引入大量 MCP tools / skills，建议优先做两件事：

1. **工具集合 profile 化**：每个实验只暴露最小工具子集（plan/explore/build 分离）。
2. **技能按需加载**：prompt 里只注入 `<available_skills>` 元数据列表，真正的 SKILL.md 让模型在需要时 `read` 或通过 `skill.load` 类 meta-tool 拉取。

## 9) 模型/运行时 workaround 线索（偏 harness，而不是 prompt）

- **execve 拦截 = “真实可执行路径”**：通过拦截 `execve(2)` 避免 `$PATH`/alias 带来的歧义；这属于“让工具执行语义更确定”，比在 prompt 里反复强调更可靠。
- **审批策略与 prefix rule**：把“批准一次”升级为“批准一类命令”，减少反复确认导致的对话噪声与上下文膨胀，也能降低模型在反复问答里跑偏的概率。
