# 知识管理（Knowledge Management）调研总结：memory / lorebook / docs / citations

更新时间：2026-02-21  
调研来源：`docs/research/ref_openclaw.md`、`docs/research/ref_memoh.md`、`docs/research/ref_risuai.md`、`docs/research/ref_tavern_kit_playground.md` 等

本篇把“记忆/知识/设定/文档”统一抽象为 Knowledge Management（KM）能力包，用来支撑后续各种 Agent 产品实验，而不把知识逻辑写死在某一种产品形态里。

## 1) 先统一术语：KM 不是只有向量检索

在参考项目里，常见至少三层：

1. **Context（工作记忆）**：当前对话窗口（最近 N turns / 最近 T 时间 / tokens 预算），需要可裁剪、可压缩。
2. **Memory（长期记忆）**：跨窗口保留的“可持续影响行为的信息”（偏好、身份、长期目标、历史事实摘要），需要可检索、可编辑、可遗忘。
3. **Knowledge（外部知识）**：文档/代码库/网页/手册/世界观设定（lorebook/world info），需要检索、引用、与注入防护。

Skills/MCP/tool calling 也会携带大量“知识性文本”（工具说明/协议/示例），因此 KM 与“prompt 膨胀治理”天然耦合（参见 `docs/research/skills_mcp_tool_calling.md`）。

## 2) 参考项目的 KM 形态对照

### 2.1 OpenClaw：文件为真相 + 工具化检索 + citations

OpenClaw 的 memory 体系更像一个“小型个人知识库”：

- **文件为真相**：`MEMORY.md`（curated）+ `memory/YYYY-MM-DD.md`（append-only 日志）。
- **工具化**：`memory_search`（语义检索，返回 snippet/path/行号，可选 citations）+ `memory_get`（按路径读取，避免大文件塞进上下文）。
- **写入策略**：pre-compaction flush（压缩前提醒把耐久信息写入 memory，避免被 summary 丢失）。
- **可观测**：`/context list`、`/context detail` 直接显示“哪些注入/工具/skills 占了上下文预算”，把 KM 变成可调参系统。
- **Docs 也是知识源**：提供 docs search 命令，通过 MCP 工具检索本地/镜像文档（`mcporter call`）。

### 2.2 Memoh：Mem0 风格“结构化记忆链路”（extract→recall→decide→apply→decay）

Memoh 把“长期记忆管理”当作一条流水线：

- 从对话抽取 facts（结构化 JSON）
- 召回候选旧记忆（vector + sparse/hybrid）
- 决策 ADD/UPDATE/DELETE/NONE
- 应用变更并 compact/time decay

它的价值在于：记忆不是 append-only，而是可维护、可衰减、可纠错的实体（更接近真实的“知识管理”而不是日志堆积）。

### 2.3 Risuai / TavernKit：Lorebook（World Info）是“规则驱动知识注入引擎”

角色扮演产品的“知识”往往不是通用文档，而是世界观/设定条目：

- 多 scope（角色/聊天/空间/模块）合并
- 触发规则（关键词/正则/strict vs loose）
- 递归与深度上限（防无限扩展）
- 预算与归因（world_info_budget、recursion、去重、trimming report）

这类 lorebook 引擎本质上是一个“规则驱动的检索 + 注入 + 预算控制”系统，完全可以抽象成通用 KM 能力：只要把“条目/触发/预算/去重/解释性报告”做成可复用组件，就能在非 roleplay 场景（比如企业 SOP/产品手册）复用。

## 3) KM 的两个核心风险：注入与膨胀

### 3.1 Prompt injection（知识源不可信）

无论知识来自网页、repo docs、还是用户上传文档，都可能包含“让模型忽略系统规则/泄露 secrets/执行危险操作”的指令。工程上建议：

- **信任边界清晰**：检索结果永远以“引用材料/参考片段”身份注入，不应与 system/developer 规则同层级。
- **显式引用/来源**：保存 citations（file/path/url/node_id），并在 UI/日志中可追溯。
- **检索前后 guardrails**：对注入片段做内容过滤/长度限制；对模型的工具调用做 policy 审批。

### 3.2 预算膨胀（知识越多越差）

- 不做预算与去重，注入越多模型越难用（选择困难、注意力稀释）。
- 需要“分层 + 按需 + 可观测”：always-injected 必须极小；其余走检索工具；并能看到每次调用的成本账。

## 4) 对 Cybros 的“KM 能力包”建议（面向实验底座）

结合现有 DAG/AgentCore 基础，建议把 KM 拆成 4 个可插拔组件：

1) **Knowledge sources（来源）**
   - DAG（messages/summary nodes）、RepoDocs/FileSet、上传文档、外部 docs（MCP）、lorebook entries（规则条目）。

2) **Indexing & retrieval（索引与检索）**
   - 向量检索（pgvector 已有）
   - 轻量 sparse（Postgres FTS/trigram）→ 进阶 hybrid（BM25+vector）→ 可选 rerank
   - 时间衰减与去重（避免重复注入同一条目）

3) **Tools（工具化接口）**
   - `memory_search/get/store/forget`（长期记忆）
   - `docs_search/get`（repo docs/外部 docs）
   - `lorebook_query`（规则触发 + 预算裁剪 + 解释性报告，偏 app 层）
   - 所有工具返回都带 citations（source + anchor），便于 UI/审计。

4) **Budgets & observability（预算与可观测）**
   - PromptAssembly 产出 “context cost report”（system/injections/tools schema/tool results/memory snippets），并落 metadata
   - tracing spans：memory_search / docs_search / lorebook_build

## 5) 最小落地顺序（覆盖面最大）

建议按这条顺序落地，以最快获得“可持续做实验”的 KM 底座：

1. Memory tools + citations（长期记忆工具化）  
2. Context cost report（让 KM 成本可见）  
3. Pre-compaction memory flush（避免 summary 丢耐久信息）  
4. Lorebook engine（规则触发 + 预算 + 去重 + 解释性报告，偏 roleplay/知识域实验）  
5. Hybrid retrieval（vector + sparse）+ time decay（减少陈旧/重复注入）
