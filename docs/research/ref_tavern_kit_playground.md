# 参考项目调研：TavernKit Playground（references/tavern_kit/playground）

更新时间：2026-02-21  
调研对象：`references/tavern_kit/playground`  
参考版本：`ef1dd0a78de4`（2026-02-19）

## 1) 项目定位与核心形态

Playground 是一个“生产级 SillyTavern-inspired 角色扮演聊天平台”的 Rails 参考实现，展示 TavernKit（gem）如何支持：

- 多角色对话（multi-character conversation / roleplay）
- SSE/实时流式输出
- World Info / Lorebooks（复杂触发与注入）
- Prompt builder（Preset + 章节拼装 + 历史适配 + 预算裁剪）
- Message swipes（同一条消息多个版本）
- Conversation branching（从任意消息分支）
- Auto/Auto-without-human（AI-to-AI 或 AI 替人类自动回复）
- Run 状态机（queued/running/succeeded/failed/canceled）

它与 Cybros 的技术栈非常接近（Rails 8.2 + Solid Queue/Cable/Cache），因此是“角色扮演形态”最直接的可迁移参考。

## 2) 调度与并发：ConversationRun 单槽队列（很工程化）

Playground 的执行单位是 `ConversationRun`（见 `docs/PLAYGROUND_ARCHITECTURE.md`）：

- 每个 conversation：
  - 最多 1 个 `running` run（唯一索引约束）
  - 最多 1 个 `queued` run（单槽队列）
- run 有 `run_after`（debounce）、cancel_requested_at（软取消）、heartbeat_at（stale 检测）
- 强制“所有 LLM IO 在 ActiveJob 中执行”（禁止 controller 同步调用）

对 Cybros 的映射：

- Cybros 的 DAG scheduler/runner 已经是更通用的调度底座；
- `ConversationRun` 的单槽并发控制相当于“对某类 node 的并发约束”，在 DAG 中可通过：
  - lane/graph 级 lease + scheduler 限制
  - 或 app 层对触发入口加幂等/排队规则

## 3) PromptBuilder：Preset/WorldInfo/History/预算裁剪

Playground 的 prompt 构建链路（架构文档）：

```
ContextBuilder -> PromptBuilder -> TavernKit.build(...).to_messages
```

关键工程点：

- PromptBuilder 是编排器；PromptBuilding::* 拆分成规则章节（preset/world-info/authors-note/群聊卡片合并/历史适配等）
- History 窗口不是“全量消息容器”，而是为 TavernKit 提供一个 windowed data source：
  - 默认只取最近 200 条 included messages（并避免无意全量扫描）
- Settings Schema Pack 与 PromptBuilder 对接非常明确（见 `docs/CONVERSATION_SETTINGS_PROMPT_BUILDER_INTEGRATION.md`）：
  - Space/SpaceMembership 的 preset/world_info/token budget 会映射到 TavernKit::Preset
  - world_info_budget 从百分比换算为 tokens（`(context_window - reserved_response) * percent`）
  - Lore engine 的 recursion/大小写/whole-word 等参数可配置

对 Cybros 的启发：

- 角色扮演 prompt builder 的复杂度远高于通用 agent prompt：
  - 需要非常明确的章节拼装与预算归因
  - 需要可解释的 trimming report（TavernKit plan）
- Cybros 如果要做 roleplay 实验，建议：
  - 不要把这些逻辑塞进 AgentCore 的通用 PromptBuilder
  - 而是做一个“Roleplay PromptBuilder（app 层）”，最终输出仍然是 AgentCore::Message 列表 + system prompt

## 4) Lorebook/World Info：多层 scope + 去重 + 预算

Playground 的 lorebook 系统覆盖多个 scope：

- Character 级（embedded lorebook entries；导入时补齐稳定 id）
- Space 级 lorebook 关联
- Conversation（Chat Lore）级 lorebook 关联（ConversationLorebook）

同时：

- PromptBuilder 会解析 world info books，并对重复 books 做去重（按 raw 内容签名）
- World info 注入受预算控制（budget/budget_cap），并支持 recursion 深度与 scoring

对 Cybros：

- 这基本就是 Risuai lorebook 的 Rails 版本；
- 可以把 lorebook engine 做成一个 prompt injection source（或 roleplay prompt builder 的一个章节），并把预算作为一等参数（可观测、可调）

## 5) Message swipes 与 branching：版本/分支是一等公民

Playground 的消息模型（简化理解）：

- `Message`：时间线上的一条消息（content 缓存当前活跃 swipe）
- `MessageSwipe`：同一 message 的多个版本（position 递增；active_message_swipe_id 指向当前版本）
- Conversation 是树结构（root/branch/thread），从任意 message fork

对 Cybros 的映射：

- swipes ≈ DAG Node 的版本能力（retry/rerun/adopt_version/edit），但需要 UI 与 domain 约束：
  - “同一位置的多版本消息”在 DAG 里可以是“同 turn 的多 attempt nodes”，或“同 node 的 versions”
- branching：DAG `fork_from!` 已提供（更通用），只需要把 UI/业务语义对齐（forked_from_message_id 类似 turn anchor）

## 6) Auto / Auto-without-human：AI-to-AI 与人类代理

Playground 支持：

- Auto without human：AI 之间自动对话（带延迟）
- Auto：AI 替 persona 自动回复（budgeted auto replies）

PromptBuilder 对 auto 还支持：

- human membership 的 persona 组合（human+character / pure human+persona / pure human）
- impersonate generation_type（对齐 SillyTavern）

对 Cybros：

- DAG-first 对这种自动化非常友好：每一步都是可审计节点；
- 但要注意并发与“用户输入策略”（during_generation_user_input_policy：reject/queue/restart）——这是产品层策略，不应写死在 AgentCore。

## 7) 在 Cybros 上实现的可行性评估

### 能做到（且很适合做“实验产品”）

- PromptBuilder（角色扮演域）：可在 app 层实现并复用 AgentCore 的 provider/tool/memory 注入能力
- lorebook/world info：做成章节/注入源即可
- swipes/branching：DAG 版本/分支能力可对齐
- runs/job：DAG scheduler 足够强（甚至比 run 状态机更通用）

### 建议补的能力（为了更顺滑地承载 roleplay）

P0：

- Roleplay PromptBuilder 的“章节化 + 预算”框架（可借鉴 TavernKit 的 plan/trimming 报告）
- lorebook engine（触发、去重、预算、递归）

P1：

- UI 约定：把 swipes 显示为“同一 turn 的多个版本”，并与 adopt_version 对齐
- auto 模式策略（队列/重启/拒绝）作为 app 配置

## 8) 借鉴要点总结

- 角色扮演产品的核心竞争力在 PromptBuilder：可配置章节顺序、world info 触发、预算裁剪、解释性报告
- “Run 状态机 + 单槽队列”是工程化并发控制的好模板，但在 DAG-first 框架里可以用更通用的节点调度表达
- swipes/branching 是“版本/分支一等公民”，与 DAG 的核心抽象天然契合

## 9) 补充：知识管理与“破限”字段的安全落地

- Tavern/SillyTavern 生态里常见把某些可配置章节命名为 `jailbreak`、`post_history_instructions`（PHI）等。对我们来说更合适的抽象是“用户可配置的附加指令/后置指令区块”，用于实验 PromptBuilder 组合与顺序，而不是提供绕过系统安全策略的能力。
- 真正可迁移的工程价值是：**把 lorebook/world info 当作知识管理系统**（分层 scope、触发规则、递归上限、预算归因、trimming report）。这些能力可以在 Cybros 里复用到“任意需要 domain knowledge 的 PromptBuilder”上，而不局限于 roleplay。
