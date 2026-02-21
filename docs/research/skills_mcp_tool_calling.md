# Skills / MCP / tool calling 实践总结（避免膨胀与选择困难）

更新时间：2026-02-21  
调研来源：`docs/research/ref_*.md`（Codex/OpenCode/OpenClaw/Bub/Memoh/Risuai/OpenAI Agents SDK/Claude Agent SDK 等）

本篇是跨项目的“工程实践摘要”，目标是回答两个问题：

1) Skills 与 MCP 工具库扩大后，如何避免 prompt 体积膨胀、挤占历史与任务信息？
2) 工具太多导致 LLM“选择困难/乱用工具”时，有哪些可复用的治理手段？

## 1) 膨胀的来源：不是只有对话历史

在真实系统里，上下文成本通常来自四类“非对话”内容：

1. **工具 schema**：尤其 MCP tools 很多、每个 tool schema 很大时会线性膨胀（OpenClaw 有 `/context detail` 专门拆解这部分）。
2. **Skills 正文**：把多个技能全文直接注入 system prompt（Memoh 的 enabled skills）会快速把预算打满。
3. **工具输出（tool results）**：搜索/爬取/日志/截图 base64 等是最常见的“重内容”来源（OpenCode、Accomplish、OpenAI Agents SDK 都有针对性裁剪/外移机制）。
4. **重复的规则文本**：在每轮对话里重复塞“工具使用说明/安全条款/协议块”，会让模型难以抓住当前任务重点（Bub/OpenClaw 更倾向把规则变成稳定章节 + 渐进展开）。

结论：治理必须覆盖 **schema、skills、tool results、规则文本** 四个通道，而不是只裁剪聊天历史。

## 2) Skills 设计：默认只注入“索引”，正文按需加载

跨项目最有效的模式是：

- **只注入可检索的 skills 索引**（name/description/location），而不是技能正文（OpenClaw 的 `<available_skills>`；OpenCode 也倾向只在需要时读取 SKILL.md）。
- 模型需要某个技能时，通过 Cybros 的 `skills_load` / `skills_read_file` **按需加载**，并且加载后只把“必要片段”进入本轮上下文。
- 对“很长的技能/大量参考资料”，把详情外置到 `references/` 或本地 docs，并用“检索工具 + 引用”取回（Bub 的 skill-creator、OpenClaw 的 docs search 工具链）。

反例（用于提醒）：Memoh 的 enabled skills 把正文直接拼进 system prompt，命中率更高但扩张性差；适合“少量固定技能”的产品，不适合作为可扩张 SDK 默认。

对 Cybros 的建议（落地到 AgentCore/PromptAssembly）：

- skills 注入固定为“元信息清单 + 路径/ID”，并提供原生 tools：`skills_list` / `skills_load` / `skills_read_file`（支持截断与缓存）。
- 对 skills store 建立治理规范（类似 Bub 的 500 行以内 + references 外置）：避免单技能变成“prompt 巨石”。

## 3) MCP 工具治理：工具很多时必须“分层暴露”

当 MCP tools 数量上百时，“全量暴露”会导致：

- prompt 体积巨大（schema 占预算）
- LLM 选择困难（同类工具重叠、描述相似）
- 安全风险上升（越多工具越难审计与授权）

可复用的治理策略：

1) **Profiles / tool groups**（OpenClaw/OpenCode/Codex）
   - 把工具按域分组（fs/web/memory/devtools…）并提供 profile（minimal/coding/messaging/full）。
   - 运行时只暴露当前 profile 的工具集合，必要时再升级 profile（并走审批/审计）。

2) **渐进式工具视图（progressive disclosure）**（Bub）
   - 默认给“精简工具列表”，需要时再 describe / 展开某个工具的完整 schema。
   - 这能显著降低“系统提示词里塞满工具手册”的倾向。

3) **Schema 规整与严格化**（OpenCode、OpenAI Agents SDK）
   - 强制 tool schema 为 object 且 `additionalProperties: false`，并做 provider 兼容转换（strict schema）。
   - 目的不是“更形式主义”，而是减少模型填参的自由度，让 tool calling 更稳定。

对 Cybros 的建议：

- 在 `tools_registry` 之上加一层 `ToolExposure`：按 lane/runtime/profile/step 选择“本轮可见工具子集”。
- 提供一个“工具成本报告”（类似 OpenClaw `/context detail`）：按 tool schema size 排序，帮助治理工具膨胀。

## 4) 工具输出治理：重内容外移 + 本次调用裁剪

跨项目共识非常清晰：**不要让原始 tool outputs 无限堆在上下文里**。

常见且有效的组合拳：

1) **外移（store-and-pointer）**
   - 大输出写到文件/对象存储/DB，仅在对话里保留“摘要 + 指针”（OpenCode 把大输出落盘；Accomplish 把截图抽成附件）。

2) **裁剪只影响本次调用**
   - OpenClaw session pruning、OpenAI Agents SDK 的 `ToolOutputTrimmer`：在发起下一次模型调用前，对旧 tool outputs 做 soft-trim/hard-clear，但不改持久化历史。
   - 这与 Cybros 的 DAG 审计理念兼容：历史可回放，prompt 组装可变“视图”。

3) **保护最近 N 轮**
   - 裁剪应保留最近若干 turn 的完整工具结果，避免模型丢失正在进行的关键上下文（ToolOutputTrimmer 的 sliding window 是一个可直接复用的算法形状）。

## 5) 一条可操作的“最小治理清单”（给 Cybros）

如果只做最小增量，建议按以下顺序落地（覆盖面最大）：

1. `ContextCostReport`：system prompt / injected files / tool schemas / tool results / skills list 的 breakdown（参考 OpenClaw `/context detail`）。
2. `SkillIndexOnly`：skills 默认只注入索引，正文通过 tool 按需加载（避免 Memoh 式全文注入）。
3. `ToolProfiles`：minimal/coding/web-only/full + groups，默认 minimal，需要时升级（并走审批）。
4. `ToolOutputPruner`：旧 tool results 的 soft-trim/hard-clear（只影响本次 prompt），并保护最近 N turns（参考 ToolOutputTrimmer）。
5. `StrictJsonSchema`：对 MCP/tools 的 schema 做 strict 化与兼容转换（减少 tool args 失败）。

以上 5 项能把“prompt 膨胀”从一种玄学问题，变成可观测、可治理、可渐进演进的工程问题。
