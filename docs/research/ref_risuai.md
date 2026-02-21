# 参考项目调研：Risuai（references/Risuai）

更新时间：2026-02-21  
调研对象：`references/Risuai`  
参考版本：`b782ec7bb8f6`（2026-02-19）

## 1) 项目定位与核心形态

Risuai（Risu）是一个跨平台 AI 聊天/角色扮演应用（Svelte + Tauri + Web），目标用户更偏“长对话、角色扮演、世界观/设定注入”，并提供大量“提示词与上下文控制”的高级功能：

- 多 provider（OpenAI/Claude/Gemini/OpenRouter/…）
- 多角色群聊（Group chats）
- Lorebook（World Info / Memory book）
- Prompt order（可调整章节顺序、条件/变量、impersonate 等）
- Regex Script（对输出做正则变换，驱动 UI/自定义格式）
- 翻译器、TTS、资产（图片/音频/视频）嵌入
- **长期记忆系统**：SupaMemory / HypaMemory V2/V3 / Hanurai（总结 + embeddings 相似召回 + 预算控制）

对 Cybros：Risuai 的价值主要在 **PromptBuilder（角色扮演域）+ Lorebook + 长期记忆策略**。其桌面/UI 不是我们的重点，但其“能力包”非常适合作为 Cybros 的实验方向之一。

## 2) Prompt Builder：章节化 + 可重排顺序（prompt order）

Risuai 的 prompt 组装不是“一段 system prompt”，而是把对话输入拆成多个“章节/卡片”，并允许用户调整顺序与格式：

- 默认 `formatingOrder`（见 `src/ts/storage/database.svelte.ts`）包含：`main/description/personaPrompt/chats/lastChat/jailbreak/lorebook/globalNote/authorNote`

> 注：Risuai/SillyTavern 生态里常见把“额外指令段”命名为 `jailbreak`。这更多是历史命名与前端配置习惯，并不意味着平台侧应提供“绕过系统安全策略”的能力；在 Cybros 上落地时应把它当作“用户可配置的附加指令区块”，并保持系统/开发者约束优先（必要时对该区块做内容安全与注入防护）。
- 实际组装发生在 `src/ts/process/index.svelte.ts`（可见对 `formatOrder` 的遍历、对系统消息合并、对模板卡 `innerFormat` 的 slot 替换等）

值得注意的工程点：

- 对 GPT/Claude 等 provider，会把连续的 system message 合并（减少 message 开销）
- 支持 promptTemplate：对每个章节再套一层 innerFormat（`{{slot}}`），并可把 prompt info 写回 chat store（调试/复现）
- 继续生成（continue）会插入 `"[Continue the last response]"` 作为系统提示（针对支持的模型）

对 Cybros 的映射：

- 我们当前的 PromptBuilder（AgentCore::PromptBuilder::SimplePipeline）更偏“通用 agent”；
- 若要承载 Risuai/TavernKit 这类角色扮演产品，需要一个 **Roleplay PromptBuilder**：
  - 章节（persona/character card/scenario/jailbreak/lorebook/author note/history）
  - 顺序与条件（可配置）
  - 预算控制（lorebook budget、memory budget、history window）

## 3) Lorebook（World Info）系统

Risuai 支持 lorebook（角色/聊天/模块合并），并提供触发/脚本机制（相关入口在 `src/ts/characterCards.ts`、`src/ts/process/triggers.ts`、以及 `src/ts/cbs.ts` 的 lorebook 模块合并）。

典型能力（从代码结构可见）：

- 多来源合并：character lore + chat lore + module lorebooks
- 触发模式：strict/loose/regex（关键词/正则触发）
- 递归/深度限制（防止无限扩展）

对 Cybros：

- lorebook 更像一种“规则驱动的 prompt injection source”：
  - 输入：最新 user message（或 recent history）+ lorebook entries（含 keys/regex/priority）
  - 输出：注入到 prompt 的 world info 片段（受 token budget 限制）
- 我们已有 prompt_injection_sources 接口，适合承载 lorebook engine，但需要补：
  - lorebook 数据模型（entry、keys、priority、scope）
  - 触发与预算算法

## 4) 长期记忆：SupaMemory + HypaMemory（重点）

Risuai 的“长期记忆”不是简单的向量检索，而是一个上下文管理子系统：

### 4.1 SupaMemory（总结压缩）

`src/ts/process/memory/supaMemory.ts` 展示了 SupaMemory 的核心逻辑：

- 当 `currentTokens > maxContextTokens`：
  - 从历史 chat 中切分 chunk（chunkSize 受 maxSupaChunkSize 与 maxContextTokens/3 影响）
  - 对 chunk 做 summarization（可用本地 summarizer、OpenAI instruct、或 subModel chat）
  - 把 summary 累积进 `supaMemory`（并在过长时对 supaMemory 再 summarise）
  - 最终把 `supaMemory` 作为 system message 注入回上下文
- 能把“很长的 roleplay 历史”压缩成更短的“剧情摘要”，维持长期连续性

### 4.2 HypaMemory（V3：总结 + embeddings 相似召回 + 预算配比）

`src/ts/process/memory/hypav3.ts`（以及 hypamemory/hypamemoryv2 等）显示 HypaMemory V3 更进阶：

- 维护 summaries（每条 summary 关联一组 chat memo ids）
- 在上下文预算里为 memory 预留比例（memoryTokensRatio），并在：
  - recent/important/similar/random summaries 之间做配比（recentMemoryRatio/similarMemoryRatio…）
  - 通过 embedding similarity 选择“与当前对话相关”的 past events summary
- 支持并发/限流（TaskRateLimiter）、实验实现、modal 显示（解释性 UI）

对 Cybros 的启发：

- Cybros 的 auto_compact 是“图内历史总结”，但缺少 HypaMemory 的“按相关性回填摘要片段”的策略；
- 我们已有 pgvector memory_store，理论上可实现 HypaMemory 的“summary embeddings”回填：
  1) 压缩时生成 summary entry → 存入 memory_store（含 turn_id、chat memo、time）
  2) 每次 prompt 组装时，对最新 query 做 memory_search，注入 top-k past summaries（受 budget 限制）
- 这会把 Risuai 的“长剧情连续性”能力迁移到 Cybros 的通用框架中（不依赖前端实现）。

## 5) Regex Script / Translator / Assets

这些能力更多是前端产品形态相关（格式化、UI 组件、TTS、多媒体渲染），对 Agent SDK 的要求主要是：

- 支持多模态内容（图片/音频/文档）作为 message content 或附件
- 支持“输出后处理管道”（regex/transformer），可把模型输出变成结构化段落或触发 UI 行为

对 Cybros：

- AgentCore 已支持 Image/Document/Audio content 类型（见安全文档），但默认禁用 URL sources（安全合理）
- 若要支持“资产嵌入”，建议：
  - 资产存储走应用侧（ActiveStorage）
  - tool_result 可返回“附件引用”，UI 渲染
  - 输出后处理（regex pipeline）建议作为 app 层可配置 transformer，不写进 AgentCore 核心

## 6) 在 Cybros 上实现的可行性评估

### 能做到（底座可承载）

- 长对话压缩：auto_compact summary + memory_store 检索回填（需要补策略，但不需要改 DAG 基础）
- lorebook：做成 prompt injection source（需要补 lore engine + 数据模型）
- 多角色：DAG node types 已有 `character_message`，可建多 speaker 规则与 UI
- branching：DAG 原生支持 fork（但需要 UI 支持）

### 需要补的能力（建议优先级）

P0：

- Memory tools + citations + scope（让“长期记忆”成为可解释可审计的机制）
- Roleplay PromptBuilder（章节化 + 顺序可配 + lorebook budget）

P1：

- “swipes/多版本回复”建模：可映射 DAG node versioning（retry/adopt_version），但需要 UI 设计
- 输出 transformer 管道（regex/翻译/TTS）作为 app 层扩展点

## 7) 借鉴要点总结

- Risuai 的核心不是模型，而是**把 prompt 与上下文当作可编排系统**（order/条件/模板/预算）
- Hypa/Supa 的长期记忆策略可以抽象成“summary → embedding → 按相关性回填”的通用能力
- lorebook 是规则驱动注入的典型案例，适合沉淀为 prompt injection engine

## 8) Tools / MCP / tool calling：适配层与“选择困难”治理

虽然 Risuai 的主战场是 roleplay，但它在 tool calling 适配上做了不少工程（尤其是多 provider）：

- **统一 tools 入口**：请求层（`src/ts/process/request/request.ts`）把 tools（含 MCP tools）作为参数下发到各 provider adapter（OpenAI/Anthropic/Gemini 等）。
- **提供“简化工具使用”开关**：`simplifiedToolUse` 会在存在 tool calls 时减少/移除自然语言回复片段（见 `src/ts/process/request/openAI.ts`、`src/ts/process/request/google.ts`），降低“工具调用+长文本”双重膨胀，并减少模型在“解释 vs 调用工具”之间摇摆。
- **MCP 作为插件能力**：插件 API 类型定义里提供 `registerMCP/unregisterMCP`（`src/ts/plugins/apiV3/risuai.d.ts`），更接近“工具生态”的产品定位。

对 Cybros 的启发：

- 不要把“工具生态（很多工具）”直接推到 system prompt 里；需要 profiles / 分组 / progressive disclosure，否则会出现典型的 tool selection 失败。
- 对 roleplay 这类长文本场景，工具调用阶段可以采用“短文本/无解释”策略（类似 simplifiedToolUse），把解释性内容延后到汇总阶段。

## 9) 模型 workaround：多 provider 下的现实问题

- **继续生成/补全协议**：Risuai 的 continue 逻辑会插入特定系统提示来触发“续写”（见 `src/ts/process/index.svelte.ts`），属于典型的“模型行为不稳定 → 产品侧协议兜底”。
- **聚合/重排 tool_calls**：在 OpenAI adapter 里会收集并合并多个 choices 的 tool_calls（`src/ts/process/request/openAI.ts`），属于对 provider 返回形态不一致的工程 workaround。
