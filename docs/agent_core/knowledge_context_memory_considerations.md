# 知识管理 / 上下文管理 / 记忆管理：设计考量（Cybros）

更新时间：2026-02-21  
适用范围：Cybros `DAG 引擎 + AgentCore（DAG-first）`

本文是三块能力（Knowledge / Context / Memory）的“考量清单”。目标是把这些能力做成**强大、灵活、通用**的底座，支撑后续各种 Agent 产品形态实验；并为“可插拔外部微服务（仅服务 Cybros）”预留稳定边界。

相关对照调研见：

- `docs/research/knowledge_management.md`
- `docs/research/skills_mcp_tool_calling.md`
- `docs/research/model_workarounds.md`

> 安全说明：本文讨论的是合规、可产品化的能力设计（预算、可观测、治理、权限、缓存、稳定性）。不提供任何“绕过系统安全策略”的可操作提示词模板。

---

## 0) 先统一术语（避免把不同问题揉成一团）

我们把三块能力拆成三个不同的目标函数：

1) **Context（上下文管理）**  
本轮模型调用要带哪些内容？如何在预算内最大化成功率与稳定性？（窗口、裁剪、压缩、工具结果治理、schema 治理、解释性报告）

2) **Memory（记忆管理与运用）**  
跨上下文窗口持久保存哪些信息？如何检索、更新、遗忘、衰减？（长期偏好/事实/项目状态/总结、scope、写入策略、检索策略、citations）

3) **Knowledge（知识管理）**  
外部知识源如何被组织、索引、检索与注入？（repo docs、上传文档、网页快照、lorebook/world info、SOP 手册；chunking、索引、检索、去重、注入安全）

重要关系：

- Context 是**一次调用的可变视图**；Memory/Knowledge 是**可演进的持久系统**。
- Memory 与 Knowledge 都会“注入到 Context”，因此二者的设计必须服从 Context 的预算与可观测机制（否则膨胀必然失控）。

---

## 1) 设计目标（面向“可持续做实验”的底座）

### 1.1 平台能力目标（跨形态复用）

- **强可观测**：能回答“这次 prompt 为什么这么大/为什么选错工具/为什么召回了这段记忆”。（参考 OpenClaw 的 `/context detail` 思路）
- **强治理**：工具/技能/知识源扩张不导致系统 prompt 膨胀与选择困难。（profiles、按需加载、schema 规整、tool output 外移/裁剪）
- **强稳定性**：面对不同模型的 tool calling/格式差异，Runner 具备 repair/fallback，而不是靠“再提示一次”。（strict schema、call_id 归一、去重、修复回路）
- **强通用**：同一套底座既能支撑 coding agent，也能支撑 roleplay/lorebook，也能支撑 always-on assistant。
- **强审计**：DAG 天然审计优势要保住：持久化历史可回放；每次调用的“注入决策与成本账”可追溯。

### 1.2 工程目标（可落地、可迭代）

- **低依赖可用**：至少有一套“Lite 方案”只依赖现有 Rails + Postgres（pgvector 已有）即可跑起来。
- **可插拔演进**：Memory/Knowledge 可迁移到外部微服务以便 A/B 与多版本并行；Context 至少内置一个够用实现。
- **多租户隔离**：任何“跨会话/全局”能力必须可正确隔离 account/user/scope，不能靠约定。
- **默认安全**：deny-by-default、最小暴露、最小持久化敏感信息，符合 `docs/agent_core/security.md`。

---

## 2) 核心约束（来自 Cybros 现状与参考项目现实）

### 2.1 LLM 上下文预算的硬约束

- 预算不是“平均限制”，而是**每次调用的硬上限**；一旦超限就失败或被迫强裁剪。
- 实际膨胀来源不仅是历史消息，还有：**工具 schema、技能正文、工具输出、注入文件**。（详见 `docs/research/skills_mcp_tool_calling.md`）

### 2.2 工具协议与 Provider 差异

- tool calling 的 JSON 字段形态可能不一致（`call_id` vs `id` 等）。
- 上下文裁剪若造成 orphan tool message，会触发 provider 协议错误（Memoh 专门处理）。
- MCP 工具 schema 可能不完整（缺 `properties`），需要 best-effort 修复与 strict 化降级（OpenAI Agents SDK 的做法）。

### 2.3 多形态产品的不同“知识”结构

- coding agent 的知识多来自 repo/文件系统/命令输出；
- roleplay 的知识多来自 lorebook/world info（触发规则、递归、预算、解释性计划）；
- personal assistant 的知识多来自长期偏好、联系人/日程、跨渠道状态。

结论：KM 必须支持“结构化条目 + 规则触发 + 检索召回 + 预算配比”，而不是只做向量检索。

---

## 3) 上下文管理（Context）的考量清单（必须内置）

### 3.1 预算模型要覆盖“非对话成本”

至少需要能对以下成本做拆账（并落 metadata）：

- system/developer prompt 本体
- prompt injections（RepoDocs/FileSet/TextStore…）
- tools schema（native + MCP + skills tools）
- skills list（索引）与 skill body（若按需加载）
- tool outputs（尤其大输出、图片/附件）
- memory/knowledge snippets（检索注入）
- history messages（用户/助手/summary）

> 只做 turn-window 裁剪会错过最大头（tool outputs/schema）。

### 3.2 “裁剪”与“压缩”的职责分离

- **裁剪（pruning）**：只影响本次 prompt 视图，不改历史（OpenClaw 的 session pruning、OpenAI Agents SDK 的 ToolOutputTrimmer）。
- **压缩（compaction）**：写入持久 summary（Cybros 已有 DAG summary；Memoh/Risuai 也有 long history summary）。

二者混在一起会导致：审计与复现困难、难以做 A/B、难以解释“为什么丢了那段工具输出”。

### 3.3 工具可见性必须“分层暴露”

工具越多，模型越容易选择困难。需要：

- tool groups + profiles（minimal/coding/web/full）
- 渐进式工具视图（默认 compact，需要时再展开 schema）
- strict schema 与工具别名归一（减少歧义）

### 3.4 “正确性保护栏”

- orphan tool message 防护（裁剪后仍保证 tool_call↔tool_result 成对）
- “最近 N turns 完整保真”规则（避免裁剪掉当前关键上下文）
- 失败可解释：每次调用的预算决策、裁剪决策写入 metadata（便于 debug）

---

## 4) 记忆管理（Memory）的考量清单

### 4.1 Memory 的作用域（scope）必须是一等概念

最少需要区分：

- conversation-scoped（仅当前会话）
- user-scoped（跨会话，但仅当前用户）
- account-scoped（团队共享）
- global/system-scoped（谨慎；通常需要更严格治理）

并且所有 scope 都要有：

- **隔离键**（account_id / user_id / conversation_id）
- **可删除与可审计**（GDPR/合规与产品需求）

### 4.2 写入策略：不要只做“检索注入”

长期有效的系统都需要“写入机制”，常见两条路线：

- **用户显式写入**（通过 tool `memory_store` 或 UI pin）→ 可控、可靠
- **系统自动写入**（facts extraction / pre-compaction flush / heuristic）→ 覆盖广但要防误写/误删

Memoh 的 mem0 风格（extract→recall→decide→apply→decay）说明：自动写入要变成一条工程链路，而不是“每轮都塞一段 relevant_context”。

### 4.3 检索策略：vector 只是起点

随着规模增长，常见演进：

- vector（语义）→ sparse（关键词/实体）→ hybrid（融合）→ rerank（精排）
- 去重与时间衰减（防重复注入与陈旧信息占位）
- 预算配比（类似 HypaMemory：recent vs similar vs important）

### 4.4 citations 与可解释性

Memory/Knowledge 的注入必须携带 citations（来源、时间、scope），否则：

- debug 困难
- 注入安全难做（无法区分“系统规则”与“引用材料”）
- 评估难做（无法量化“召回是否有用”）

---

## 5) 知识管理（Knowledge）的考量清单

### 5.1 知识源是多样的（且信任等级不同）

常见来源：

- repo docs / AGENTS / design docs
- 用户上传文档与聊天附件
- 外部网页/第三方文档（快照）
- lorebook/world info（规则条目）
- 工具输出沉淀（例如 crawl 结果、搜索结果的“精选摘要”）

信任等级建议至少分两层：

- **trusted**：我们自己维护的系统/开发者文档（仍需 budget 控制）
- **untrusted**：用户提供/外部抓取/检索片段（必须做注入防护）

### 5.2 注入防护：KM 必须与安全策略耦合

核心原则：

- 检索片段永远以“引用材料”身份注入，不能与 system/developer 同层级混合。
- 片段进入 prompt 前要做长度限制、格式包装、以及（可选）内容过滤/清洗。
- 工具调用仍由 tool_policy/审批控制，不能被检索片段绕过。

### 5.3 lorebook/world info 是知识管理的“极端但有价值”样本

Risuai/TavernKit 的 lorebook 证明：知识管理不一定是“搜索 top-k”，也可以是：

- 规则触发（关键词/regex/strict vs loose）
- 递归与深度限制
- 预算 cap 与解释性计划（trimming report）

结论：Knowledge 模块应能承载“规则驱动注入引擎”这一类形态，而不是只做 RAG。

---

## 6) 可插拔外部微服务（仅服务 Cybros）的考量

### 6.1 为什么值得做

- 三块能力会反复调整（算法/预算/策略/数据模型），外置后可多版本并行与 A/B。
- Heavy 计算（embedding、rerank、chunking、事实抽取）可独立扩缩。
- 可把“知识/记忆系统”从 Rails 请求路径剥离，减少主进程复杂性。

### 6.2 代价与风险

- 延迟与可用性：每轮 LLM 调用会多一次或多次网络依赖。
- 一致性：写入/索引/删除的时序会更复杂（尤其是自动写入链路）。
- 多租户隔离的边界更长：必须有强认证/授权与审计。

### 6.3 边界建议（保持 Context 内置）

建议边界：

- **Context 组装与预算决策**：留在 AgentCore 内置（本地确定性更强、失败更可控）。
- **Memory/Knowledge 的索引与检索**：可外置为服务（提供 search/store/get/forget + citations）。
- **Embedding/Rerank**：可作为服务内组件或独立服务（Ultimate 方案）。

---

## 7) Lite vs Ultimate 的选择标准（考量层面的结论）

- 你需要“尽快能跑、尽快能做实验” → 先做 Lite（内置 + Postgres）
- 你需要“多版本算法并行、重度 RAG/重度长记忆、成本可控” → 再上 Ultimate（微服务化 + hybrid + rerank）

关键是：两者必须共享同一套 **稳定的内部接口**（ports/adapters），否则无法平滑切换与对比评估。

