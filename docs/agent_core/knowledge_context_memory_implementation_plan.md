# 知识管理 / 上下文管理 / 记忆管理：实施计划（迭代路线图）

更新时间：2026-02-21  
适用范围：Cybros `DAG 引擎 + AgentCore（DAG-first）`

本文把 `docs/agent_core/knowledge_context_memory_design.md` 的 Lite/Ultimate 方案落成一个可执行的迭代计划。目标是：

- **先把 Lite 跑稳**（可观测 + 可控 + 可插拔）
- **再逐步演进到 Ultimate**（服务化、多版本并行、hybrid/rerank、自动写入链路）

---

## 0) 交付物列表（最终要“看得见摸得着”）

### 0.1 AgentCore（L1，通用 SDK）

- `ContextCostReport`（每次调用落 node metadata）
- `ToolOutputPruner`（只影响本次 prompt，保护最近 N turns）
- `ToolProfiles + StrictJsonSchema`（工具可见性分层 + schema 规整）
- `MemoryTools`（`memory_search/memory_store/memory_forget`；`memory_get` 可选）

### 0.2 App 层（L2，Rails 产品层）

- lorebook/world info 引擎（先做成 prompt injection source，后续可服务化）
- KM 配置面（每个 conversation/lane 选择 profile、预算、KM variant）
- 评估/对比工具（A/B 对照跑、成功率与成本报表）

### 0.3 KM 微服务（L3，仅 Ultimate）

- `km-service`（Memory/Knowledge HTTP API）
- 可选：embedding/rerank 组件（可内嵌到 km-service，或拆成子服务）

---

## 1) Phase P0（Lite 起步，优先做“可观测 + 可控”）

目标：不引入外部服务，也能明显改善长对话/多工具场景的稳定性，并为后续 A/B 打底。

### P0-1：ContextCostReport（必须先做）

落点（建议）：

- `AgentCore::DAG::ContextBudgetManager` / `PromptAssembly` 产出 report
- 写入 `agent_message.metadata["context_cost"]`（String keys）

验收标准：

- 每次 LLM 调用都能看到：预算、估算 tokens、关键决策（memory_dropped、limit_turns、是否 auto_compact）
- 至少能拆分：system/history/tools/tool_results/injections/memory_knowledge（粗粒度即可）

### P0-2：ToolOutputPruner（session pruning）

落点（建议）：

- 在 PromptAssembly 的“最终 messages”生成后、发起 provider call 之前执行（不写回 DAG 历史）
- 默认保护最近 2 个 user turns

验收标准：

- 长会话中 tool outputs 不会持续线性膨胀导致超窗
- 不出现 orphan tool message（provider 400 的典型错误）
- pruning 决策写入 ContextCostReport（action + strategy + protected_turns）

### P0-3：ToolProfiles（最少 minimal/full）+ strict schema（best-effort）

落点（建议）：

- tools_registry 上方增加“本轮可见工具子集”的选择层（profile/group）
- MCP tools schema 做 strict 化（additionalProperties=false、补 properties 等；失败降级）

验收标准：

- 只要切换 profile，就能显著缩小 tools_schema tokens
- tool args 的解析失败率下降（至少在典型用例里）

### P0-4：MemoryTools（把 memory 从“自动注入”升级为“工具化”）

落点（建议）：

- 在 tools_registry 注册 memory 工具（由 runtime 注入 memory_store）
- 保留现有 `<relevant_context>` 注入，但允许配置为 0（禁用自动注入，仅 tool 调用）

验收标准：

- 模型能按需调用 `memory_search/memory_store`
- tool result 至少返回 `memory_entry id`（metadata 可携带 scope/citations；输出受 size cap 控制）

---

## 2) Phase P1（Lite 增强：可解释的写入机制 + 更好的检索）

目标：让 memory/knowledge 开始“可持续变好”，而不是越用越乱。

### P1-1：Pre-compaction memory flush

落点（建议）：

- 在 auto_compact 前插入一个“silent step”：让 agent 把耐久信息写入 memory（或由 UI 引导用户 pin）
- flush 成功与否写入 metadata（避免黑盒）

验收标准：

- 压缩后仍能保留关键偏好/事实（通过 `memory_search` 可召回）

### P1-2：Memory scopes（conversation/user/account）与隔离

落点（建议）：

- 明确 scope 字段与隔离键（account_id/user_id/conversation_id）
- 对“共享 scope”（account/global）增加 guardrail 或审批门槛

验收标准：

- 多租户/多用户不会互相召回到对方记忆（单测 + 迁移验证）

### P1-3：Hybrid retrieval（轻量版）

落点（建议）：

- 不引入新服务的情况下：Postgres FTS/trigram 作为 sparse，pgvector 作为 semantic
- 用简单 rank fusion 合并（先不要 rerank）

验收标准：

- 对“有关键词/实体”的查询召回更稳（不依赖 embeddings 完全命中）

---

## 3) Phase P2（Knowledge：把 lorebook/docs 体系做成一等能力）

目标：让“知识管理”不仅能 RAG，还能承载 roleplay/world info、企业 SOP 等规则注入形态。

### P2-1：Knowledge ingestion（chunking + embeddings）与 citations

落点（建议）：

- 上传文档、repo docs（可选）进入统一 KnowledgeChunk 表（或服务）
- citations 能定位 chunk→原文（path+sha/attachment id）

验收标准：

- knowledge_search 返回可追溯片段，并能通过 knowledge_get 取原文

### P2-2：Lorebook engine（规则触发 + 预算裁剪 + trimming report）

落点（建议）：

- 先在 app 层实现（prompt injection source），产出：
  - snippets（注入内容）
  - build_report（解释性计划：触发了哪些条目、为何被裁剪）

验收标准：

- 在 roleplay 场景可控地注入 world info，且预算可解释

---

## 4) Phase P3（Ultimate：KM 微服务化 + 多版本并行评估）

目标：让 KM 成为可独立演进系统，并能在同一 Cybros 中并行对比多个版本效果。

### P3-1：抽象 ports/adapters（先在单体内对齐接口）

落点（建议）：

- memory_store/knowledge_source 统一走“接口对象”，先实现 LocalAdapter（现有 Postgres）
- 代码层不直接依赖“具体库/具体表结构”，只依赖接口

验收标准：

- 不改业务逻辑即可切换 LocalAdapter / RemoteAdapter

### P3-2：km-service（HTTP API）+ RemoteAdapter

落点（建议）：

- km-service 提供 `/v1/memory/*` 与 `/v1/knowledge/*`
- Cybros 侧实现 `RemoteMemoryStore` 与 `RemoteKnowledgeSource`
- runtime_resolver 支持按 conversation 选择 variant（A/B）

验收标准：

- 同一测试集可以在 v1/v2 两个 variant 上跑出对照结果（成功率/成本/延迟）
- 服务不可用时能降级，不影响基础对话

### P3-3：hybrid + rerank + mem0 自动写入（在服务内快速迭代）

验收标准：

- 明确的离线评估集 + 在线指标，证明“强力方案”确实带来提升（而不是黑盒更玄学）

---

## 5) 评估与回归（每一阶段都要做）

建议从 P0 就建立两类评估：

1) **离线场景集（golden conversations）**
   - coding：大工具输出、长日志、需要读多文件
   - roleplay：lorebook 触发、长剧情连续性
   - assistant：跨会话偏好、联系人/日程类记忆

2) **在线指标（observability）**
   - tokens：total 与分项（tools_schema/tool_results/memory_knowledge）
   - 成功率：工具调用成功率、任务完成率、blocked 比例
   - 延迟：检索耗时、LLM 耗时、总 wall time
   - 安全：跨租户召回 0 容忍、注入片段触发危险工具的拦截率

没有评估体系，Ultimate 会不可控地变成黑盒。
