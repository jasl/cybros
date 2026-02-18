# DAG 行为规范（Behavior Spec，Milestone 1）

本文档是 DAG 引擎行为的**规范性描述**（normative spec）。实现必须以本文档为准；本文档也作为后续审查设计正确性、寻找缺陷与补测试的基准。

> 约定：除非特别说明，本文档中的 “节点/边” 都指 **Active 图**（见第 1 节）。

---

## 1) Active vs Inactive（统一语义：`compressed_at`）

### 1.1 定义

- **Active node**：`dag_nodes.compressed_at IS NULL`
- **Inactive node**：`dag_nodes.compressed_at IS NOT NULL`
- **Active edge**：`dag_edges.compressed_at IS NULL`
- **Inactive edge**：`dag_edges.compressed_at IS NOT NULL`

`compressed_at` 是 DAG 的统一“活跃视图（active view）”开关，用于两类场景：

1) **子图压缩**（Compression）：用 `summary` 节点替代一个已完成子图。  
2) **版本替换/改写**（Replace/Rewrites）：`retry/regenerate/edit` 产生新版本并归档旧版本。

> 关键点：Active/Inactive 是“视图层语义”，不是数据删除；Inactive 仍可用于审计、回放与 UI 版本浏览。

### 1.2 Active 图的结构性要求（重要）

为了保证 Scheduler/Context/Leaf 等逻辑可以只看 Active 图：

- **Active edge 的端点必须都是 Active node**。  
  换句话说，归档（archive）任何节点时，必须同时归档所有 incident edges（无论 edge_type）。

实现要求：

- **写入期校验**：禁止创建 active edge 指向 inactive node（例如 model validation）。
- **查询层防御**：Context/Leaf/Scheduler/FailurePropagation 必须做 active endpoint filtering，将“active edge 指向 inactive node”的脏数据视为不存在。

### 1.2.1 Graph-scoped foreign keys（DB 级约束）

为降低脏数据故障面、避免 “跨图引用” 污染引擎行为，里程碑 1 要求以下引用在数据库层面必须是 **graph scoped**（规范性要求）：

- `dag_edges (graph_id, from_node_id)` / `(graph_id, to_node_id)` 必须外键引用 `dag_nodes (graph_id, id)`（composite FK）。
- `dag_node_visibility_patches (graph_id, node_id)` 必须外键引用 `dag_nodes (graph_id, id)`（composite FK）。
- `dag_nodes (graph_id, retry_of_id)` 必须外键引用 `dag_nodes (graph_id, id)`（composite FK；禁止跨图 retry lineage 引用）。
- `dag_nodes (graph_id, compressed_by_id)` 必须外键引用 `dag_nodes (graph_id, id)`（composite FK；禁止跨图压缩归档引用）。
- `dag_nodes (graph_id, lane_id)` 必须外键引用 `dag_lanes (graph_id, id)`（composite FK；禁止跨图 lane 引用）。

这意味着：即使绕过模型校验（例如 `save!(validate: false)`），DB 也会拒绝插入跨 graph 的 edge/patch。

另外，里程碑 1 约定压缩字段必须满足稳定一致性约束（DB check constraint）：

- `compressed_at` 与 `compressed_by_id` 必须同为 NULL 或同为 NOT NULL（禁止半边写入导致 Active/Inactive 视图与 lineage 归档不一致）。

### 1.3 include_compressed（约定）

- **默认行为**：只在 Active 图上工作（Context、Scheduler、Leaf、可视化默认）。
- **include_compressed=true**：用于审计/回放/Debug；允许同时看 Active + Inactive（即“全量图”）。

---

## 2) Nodes（类型、状态机、payload 映射）

### 2.1 节点类型（`dag_nodes.node_type`）

- `system_message`：系统提示/全局规则（不可执行；默认进入 context；默认不进入 transcript）
- `developer_message`：开发者提示/产品约束（不可执行；默认进入 context；默认不进入 transcript）
- `user_message`：用户输入
- `agent_message`：LLM/Agent 输出（可执行）
- `character_message`：角色发言（可执行；与 `agent_message` 同级，用于多角色/群聊）
- `task`：可执行动作（tool/MCP/skill 等）
- `summary`：子图压缩后的替代节点

类型约束（规范性要求）：

- 引擎**不**在 DB 层对 `dag_nodes.node_type` 做 check constraint（允许业务扩展）。
- 对 conversation graphs：`attachable.dag_node_body_namespace` 必须返回一个 NodeBody 命名空间（Module），引擎按约定将 `node_type` 映射到 `#{namespace}::#{node_type.camelize}`，且该常量必须 `< DAG::NodeBody`；未知/未定义类型默认失败，避免拼写错误/脏数据导致 Scheduler/Context/Leaf/FailurePropagation 产生不可解释行为。
- 对缺失 `dag_node_body_namespace` 的 graphs：视为图配置错误；节点创建必须失败（不做 silent fallback）。

### 2.2 节点状态（`dag_nodes.state`）

状态集合：

- `pending`：已创建，待执行
- `running`：已被 claim，执行中
- `finished`：成功完成（依赖满足仅认 `finished`）
- `errored`：执行失败
- `rejected`：用户拒绝授权
- `skipped`：未开始且不再需要（只允许 `pending → skipped`）
- `cancelled`：执行中被取消（只允许 `running → cancelled`）

**Terminal states**（终态）定义为：

- `finished | errored | rejected | skipped | cancelled`

### 2.3 状态机（允许迁移）

允许的迁移（其余迁移均为非法）：

- `pending → running`
- `running → finished | errored | rejected | cancelled`
- `pending → skipped`

时间戳约定：

- `claimed_at`：仅在 `pending → running`（被 Scheduler claim）时写入
- `claimed_by`：claim 执行者标识（用于排障/观测）
- `started_at`：Runner 实际开始执行时写入（可能晚于 claim）
- `heartbeat_at`：Runner 续租/心跳时写入（里程碑 1 至少在开始执行时写入）
- `lease_expires_at`：running lease 过期时间（Scheduler claim 时写入，Runner 开始执行时会延长）
- `finished_at`：仅在进入 terminal state 时写入（含 skipped/cancelled）

### 2.3.1 Running lease & reclaim（可靠性）

为避免 worker 崩溃/队列卡死导致图永久停滞（例如永远有 running 节点从而无法 idle），里程碑 1 引入 running lease：

- Scheduler claim 时会写入 `lease_expires_at`（短租约，claim lease）。
- Runner 开始执行时会刷新 `heartbeat_at` 并延长 `lease_expires_at`（执行租约）。
- 租约时长由 `graph` 决定：
  - claim lease：`graph.claim_lease_seconds_for(...)`（里程碑 1 默认 `30.minutes`）
  - execution lease：`graph.execution_lease_seconds_for(node)`（里程碑 1 默认 `2.hours`）
- 若节点仍处于 `running` 且 `lease_expires_at < now`，引擎必须将其回收为：
  - `running → errored`
  - `metadata["error"] = "running_lease_expired"`

回收动作必须触发 `node_state_changed` hook（`from=running,to=errored`）。

### 2.4 可执行节点（Executable）

可执行性由 NodeBody class hook `executable?` 决定（默认 false；例如 `Messages::AgentMessage/CharacterMessage/Task` 为 true）。

新不变量（规范性要求）：

- 只有 `NodeBody.executable? == true` 的节点才允许处于 `pending` 或 `running`。

因此 Scheduler/FailurePropagation 可以只按 `state` 与拓扑关系工作，不再需要维护 `node_type IN (...)` 的可执行列表。

### 2.5 NodeBody（STI + JSONB I/O）

所有“业务重字段”放入 `dag_node_bodies`，通过 `dag_nodes.body_id` 一对一关联。

> 说明：对外（Context 输出）仍使用字段名 `payload` 来表示该 I/O 对象；在存储层它由 `NodeBody` 承载，对应列为 `input/output/output_preview`。

Payload 的列级约定：

- `input`：输入侧（用户消息内容、tool call 参数等）
- `output`：输出侧（LLM 回复、tool result 等，可能很大）
- `output_preview`：输出预览（由 output 派生的小片段，默认用于 Context/Mermaid）

#### 2.5.1 node_type ↔ body STI 的强一致性

Active 视图内必须保持一致（不允许 drift）：

- `node.body` 的 STI 类型必须等于 `graph.body_class_for_node_type(node.node_type)`

映射由 `graph.body_class_for_node_type` 决定，通常由 attachable 注入。里程碑 1 的示例：

- `Conversation`（`dag_node_body_namespace => Messages`）映射为：
  - `system_message` → `Messages::SystemMessage`
  - `developer_message` → `Messages::DeveloperMessage`
  - `user_message` → `Messages::UserMessage`
  - `agent_message` → `Messages::AgentMessage`
  - `character_message` → `Messages::CharacterMessage`
  - `task` → `Messages::Task`
  - `summary` → `Messages::Summary`
> 若 `dag_node_body_namespace` 缺失或返回非 Module：图配置错误；节点创建必须失败（不做 silent fallback）。

#### 2.5.2 负载字段最小约定

- `user_message`：
  - `payload.input["content"]`：String（必须）
  - `payload.output`：通常为空
- `system_message` / `developer_message`：
  - `payload.input["content"]`：String（必须）
- `agent_message`：
  - `payload.output["content"]`：String（常用）
- `character_message`：
  - `payload.output["content"]`：String（常用）
- `task`（Task）：
  - `payload.input["name"]`：String（建议）
  - `payload.input["arguments"]`：JSON（建议）
  - `payload.output["result"]`：JSON/String（常用）
- `summary`：
  - `payload.output["content"]`：String（必须）

#### 2.5.3 NodeBody semantic hooks（规范性要求）

里程碑 1 引入一组 **NodeBody 语义 hooks**（class-level），用于把 “哪些类型算 turn anchor / transcript 候选 / leaf terminal / 默认 leaf repair / content 写入落点 / mermaid snippet” 从 DAG 核心分支判断中抽离出来：

- `node_type_key`：默认 `name.demodulize.underscore`
- `created_content_destination`：默认 `[:output, "content"]`（用于 `Mutations#create_node(content: ...)` 的写入落点）
- `turn_anchor?`：默认 `false`（用于 `transcript_recent_turns` 的 turn SQL 预筛选）
- `transcript_candidate?`：默认 `false`（用于 `transcript_recent_turns` 的候选节点 SQL 预筛选）
- `leaf_terminal?`：默认 `false`（用于 conversation graphs 的 leaf-valid 判定）
- `default_leaf_repair?`：默认 `false`（用于 leaf invariant repair 选择默认追加的 node_type；conversation graphs 要求 **必须且只能有一个** body 返回 true）
- `mermaid_snippet(node:)`：用于 Mermaid label 片段（默认从 `output_preview["content"]` 提取；各 body 可覆盖）

引擎行为（normative）：

- 对 conversation graphs（attachable 提供 `dag_node_body_namespace`）：
  - 引擎会扫描该 namespace 下所有 `< DAG::NodeBody` 的子类，基于 hooks 计算 turn anchor / transcript candidates / leaf terminal types / default leaf repair type。
  - 这意味着：扩展新 node_type 时，除了提供 `node_type ↔ body` 的约定映射外，还应在对应 body 上声明必要的 hooks（而不是修改 DAG 核心）。
- `dag_node_body_namespace` 缺失时，不保证 hooks 扫描与 leaf 修复等行为可用（因为该图本身被视为 misconfigured）。

### 2.6 节点观测字段（usage/output_stats）

为支持成本统计与压缩策略输入，里程碑 1 约定引擎将以下观测信息写入 `dag_nodes.metadata`（而不是 NodeBody）：

#### 2.6.1 `metadata["usage"]`（tokens/cost 等）

- `metadata["usage"]` 表示 **一次执行/一次调用** 的资源消耗（attempt-specific）。
- 写入来源：executor 返回的 `ExecutionResult.usage`（以及/或 result.metadata 内的同类信息），由 Runner 统一写入。
- 内容结构不做强约束（provider/model/cost/prompt_tokens/...），但 key 必须为 string。

#### 2.6.2 `metadata["output_stats"]`（输出体积与结构统计）

`metadata["output_stats"]` 用于补齐 tokens 不足以解释的维度（例如 task JSON 很大但 tokens 不高）：

- `body_output_bytes`：`pg_column_size(dag_node_bodies.output)`（DB 侧真实存储字节）
- `body_output_preview_bytes`：`pg_column_size(dag_node_bodies.output_preview)`
- `output_top_level_keys`：`payload.output` 的顶层 key 数
- 当 `payload.output["result"]` 存在时：
  - `result_type`：`string|hash|array|number|boolean|null|other`
  - `result_key_count`（仅 hash）
  - `result_array_len`（仅 array）

写入时机：

- 仅在节点进入 `finished` 且 output 已落库后写入（attempt-specific）。

#### 2.6.3 `metadata["timing"]` / `metadata["worker"]`（排障与时序观测）

为支持 “队列延迟/执行耗时/工作进程排障” 等需求，里程碑 1 约定 Runner 在节点执行过程中写入：

- `metadata["timing"]["queue_latency_ms"]`：Integer
  - 定义：`(started_at - claimed_at) * 1000`
  - 仅当 `claimed_at` 与 `started_at` 均存在时写入
- `metadata["timing"]["run_duration_ms"]`：Integer
  - 定义：`(finished_at - started_at) * 1000`
  - 仅当 `started_at` 与 `finished_at` 均存在时写入
- `metadata["worker"]["execute_job_id"]`：String（可选）
  - 由 `ExecuteNodeJob` 透传给 Runner，用于定位具体 job 实例（排障/审计）

> 说明：这些字段均为 attempt-specific 观测字段，不应通过 lineage 继承到新的 attempt/version。

#### 2.6.4 attempt-specific（禁止继承）

`retry/regenerate/edit` 生成的新节点必须 **不继承** 旧节点的：

- `metadata["usage"]`
- `metadata["output_stats"]`
- `metadata["timing"]`
- `metadata["worker"]`

### 2.7 `lane_id`（分区 / Thread-like Lane）

里程碑 1 引入 Lane 分区模型，用于把一张 DAG 图中的分支子图“染色/索引”为若干个分区（Thread-like）。规范性要求：

- `dag_nodes.lane_id` **必须存在**（一个 node 只能属于一个 lane）。
- 每个 `DAG::Graph` 必须存在且仅存在一个 `main` lane（主线）。
- `fork` 必须创建一个新的 `branch` lane，并把 fork 创建的第一条新 node 作为该 lane 的 `root_node`。
- `archived_at` 非空表示 lane 已归档。归档后的 lane **禁止开启新 turn**（但允许同一 turn 的收尾）：
  - 若要创建的 node 的 `turn_id` 在该 lane 内不存在任何 Active 节点：视为新 turn，必须失败
  - 若该 `turn_id` 在该 lane 内已存在 Active 节点：视为同 turn 延续，允许创建（用于 executor/tool 链补节点、leaf repair 等）

引擎默认 lane 选择（`Mutations#create_node`，normative）：

- 若显式传入 `lane_id`：使用该 lane（但必须与本次 `turn_id` 已存在节点的 lane 一致，否则必须 raise）。
- 否则若存在有效的 `turn_id`：必须继承该 turn 内既有 active 节点的 `lane_id`（用于保证 executor 在同一轮内创建的 task/tool 节点不会落错 lane）。
- 否则：默认落在 `graph.main_lane`。

其它引擎行为（normative）：

- leaf invariant repair 创建的默认 leaf repair 节点必须继承 leaf 的 `lane_id`。
- Compression 不允许跨 lane 压缩；summary 节点必须继承被压缩子图的 `lane_id`。
- Context/Transcript 输出必须携带 `lane_id`（用于 UI 染色与对话树展示）。

### 2.8 `turn_id`（对话轮次 / 执行 span）

为支持 “圈定本轮产生的子图集合” 与未来的强 gating 校验（例如 squash/rewire），里程碑 1 引入：

- `dag_nodes.turn_id`：UUID（默认值 `uuidv7()`），用于标记某个节点属于哪一轮（turn/span）。

核心语义（normative）：

- 同一轮产生的所有节点共享相同 `turn_id`。
- 同一 graph 内，对任意 `turn_id`（只看 Active）：该 turn 的所有节点必须属于同一个 lane（`lane_id` 不可跨 lane）。
- `retry/regenerate/edit` 是同一轮的版本替换：`new_node.turn_id == old.turn_id`
- `fork` 开启新轮次：fork 出来的 `new_node.turn_id` 由 DB default 生成（不继承父节点 turn_id）
- leaf invariant repair 创建的默认 leaf repair 消息节点（里程碑 1 默认 `agent_message(pending)`）必须继承 leaf 的 `turn_id`（引擎层强制）

推荐用法：

- executor/业务代码在执行某个节点 `node` 时，若要创建本轮下游节点，使用：
  - `graph.mutate!(turn_id: node.turn_id) { |m| ... }`
  - 这样 `m.create_node` 会默认继承该 `turn_id`（除非显式传 `turn_id: nil` 强制开新轮次）。

### 2.9 `idempotency_key`（去重键，graph+turn 作用域）

为避免同一轮次内重复创建相同节点（尤其是 tool call / 下游任务），里程碑 1 引入可选字段：

- `dag_nodes.idempotency_key`：String（可为空）

规范性约束：

- 在 Active 视图内，`(graph_id, turn_id, node_type, idempotency_key)` 必须唯一（当 `idempotency_key IS NOT NULL`）。
- `idempotency_key` 只能用于 **已知 turn_id 的场景**（本规范要求：使用 idempotency_key 时必须显式/隐式提供 turn_id）。

引擎行为（normative）：

- `Mutations#create_node(..., idempotency_key: k)`：
  - 若同 scope 下已存在节点，则必须返回既有节点（不新建）。
  - 若调用参数与既有节点的 body I/O 或 state 不一致，必须 raise（避免 silent drift）。

---

## 3) Edges（正交语义：Causal vs Lineage）

### 3.1 Edge types（`dag_edges.edge_type`）

- `sequence`（因果/阻塞，causal + blocking）：表示 “A 之后才能做 B”
- `dependency`（因果/阻塞，causal + blocking）：表示 “B 依赖 A 的成功输出”
- `branch`（谱系/非阻塞，lineage）：用于 provenance（fork/edit/regenerate/retry）

定义：

- **blocking edges**：`sequence | dependency`
- **lineage edges**：`branch`

> branch 边必须是**纯 lineage**：不参与 Scheduler/Context/Leaf 的任何判定。

### 3.2 Scheduler edge gating 真值表

仅对 **incoming blocking edges** 做 gating（branch 不参与）。

| parent.state | `sequence` 是否 unblock child | `dependency` 是否 unblock child |
|---|---:|---:|
| `pending` | 否 | 否 |
| `running` | 否 | 否 |
| `finished` | 是 | 是 |
| `errored` | 是 | 否 |
| `rejected` | 是 | 否 |
| `skipped` | 是 | 否 |
| `cancelled` | 是 | 否 |

补充规则：

- **Inactive edge**（`compressed_at IS NOT NULL`）视为不存在。
- **Inactive parent node** 不应出现在 Active edge 的端点上（第 1 节结构性要求）；若出现，实现需在 Leaf/Context 层做防御性过滤，但该情况视为 bug。

---

## 4) Context（仅 causal 闭包；preview 默认）

### 4.1 Ancestor closure（祖先闭包）

`context_for(target_node_id)` 的祖先闭包定义为：

- 从 target 开始，沿 **Active blocking edges**（`sequence/dependency`）向上递归收集所有祖先；
  - 其中 “Active blocking edge” 的判定必须同时满足：edge active 且两端节点 active（防御性忽略 “active edge 指向 inactive node” 的脏数据）
- **不沿 branch** 边遍历（branch 不属于因果图）。

### 4.2 排序（稳定拓扑序）

闭包内节点按 blocking edges 做拓扑排序，要求稳定：

- 基于 `sequence/dependency` 的 DAG 拓扑序；
- 当存在多个可选节点时，以 `node_id` 字典序（uuidv7）作为 tie-breaker，确保输出可复现。

### 4.3 输出 schema（preview/full）

默认输出 `mode=:preview`，每个节点结构：

```json
{
  "node_id": "...",
  "turn_id": "...",
  "lane_id": "...",
  "node_type": "user_message|system_message|developer_message|agent_message|character_message|task|summary",
  "state": "pending|running|finished|errored|rejected|skipped|cancelled",
  "payload": {
    "input": { },
    "output_preview": { },
    "output": { } // 仅 full mode
  },
  "metadata": { }
}
```

- `mode=:preview`：只输出 `payload.input + payload.output_preview`
- `mode=:full`：额外输出 `payload.output`（用于审计/调试/特殊 executor）

### 4.4 output_preview 规则（分型、可验证）

`output_preview` 只用于 “小片段可读输出”，必须满足：

- **上限固定**：字符串按 `body.preview_max_chars` 截断
  - 默认上限：`200 chars`（`DAG::NodeBody`）
  - `agent_message/character_message`（`Messages::AgentMessage` 家族）：`2000 chars`
- **Task result**（`Messages::Task`）：
  - `payload.output_preview["result"]` 必须始终为 **String**
  - 当 `payload.output["result"]` 为 Hash/Array 时，preview 必须是摘要字符串（不允许全量 JSON 序列化再截断）
- 其它 body 类型：非字符串值可按 JSON 序列化后截断
- 默认优先级（从 output 派生）：
  1) 有 `content` 则取 `content`
  2) 否则有 `result` 则取 `result`
  3) 否则若 output 只有一个 key，取该 key/value
  4) 否则取整段 JSON 的截断字符串

允许 STI 子类覆写派生逻辑（例如 Task 的摘要化），但必须遵守上限与可读性目标。

### 4.5 Context 可见性标记（exclude/delete，非结构性）

为支持 LLM Playground 等产品场景，Active 图允许对节点设置“可见性标记”。这些标记是**纯视图层语义**：

- 不改变 DAG 的结构（不影响 `compressed_at`、不重连边）
- 不影响 Scheduler/Leaf/FailurePropagation（引擎推进只看结构与状态）

字段：

- `dag_nodes.context_excluded_at`：从 **Context 输出**中排除该节点（默认）
- `dag_nodes.deleted_at`：软删除；从 **Context 输出**与 **Transcript 输出**中排除该节点（默认）

#### 4.5.0 写入期 gating（防止执行中不可解释行为）

为避免 “节点执行中（running）上下文被改写” 导致不可解释行为，里程碑 1 采用严格 gating：

- 仅允许对 **terminal 节点**设置/清除 `context_excluded_at/deleted_at`
- 且要求 graph 处于 idle：Active 图中不存在任何 `state=running` 的节点

实现要求：

- gating 的决策权由 `graph.visibility_mutation_error(node:, graph:)` 统一提供（返回 String reason 或 nil）。
- 引擎提供的 strict API（例如 `DAG::Node#exclude_from_context!/soft_delete!`）必须在图锁内强制执行该 gating，并在不允许时 raise 该 reason（便于 UI 与调试）。
- 数据库层面必须以 check constraint 固化 “terminal-only” 的约束（running/pending 无法被标记为 excluded/deleted）

#### 4.5.0.1 Defer queue（request_* API，运行中申请，idle 时生效）

严格 gating 对引擎正确性最安全，但在产品层（例如 LLM Playground）往往需要 “运行中先申请隐藏/删除，稍后自动生效”。因此里程碑 1 额外提供 defer queue：

- **strict API（会 raise）**：
  - `exclude_from_context! / include_in_context! / soft_delete! / restore!`
  - 当 node 非 terminal 或 graph 非 idle（存在 running 节点）时直接拒绝（raise）。
- **request API（不会因 gating raise）**：
  - `request_exclude_from_context! / request_include_in_context! / request_soft_delete! / request_restore!`
  - 返回值为 `:applied`（立即生效）或 `:deferred`（已入队，等待自动生效）。

defer queue 的存储与应用规则（normative）：

- 表：`dag_node_visibility_patches`
  - 每个 node 最多一条 pending patch（唯一键：`(graph_id,node_id)`）。
  - patch 记录保存的是**最终 desired 值**（而不是 delta），并对 `context_excluded_at` 与 `deleted_at` 两列做字段级 last-write-wins 合并。
  - patch 表不强制 terminal-only 约束；terminal-only 仍由 `dag_nodes` 的 check constraint 固化。
- 自动应用（apply）条件：**graph idle（无 running）且 node terminal**。
  - 应用在 `TickGraphJob` 的图锁内执行，并要求发生在 Scheduler claim 之前（避免 “本轮 tick claim 出 running 导致永远不 idle”）。
  - 应用成功后必须删除 patch 记录（队列消费）。
- stale patch 清理：
  - 若 node 变为 inactive（`compressed_at` 非空）或不存在，patch 视为 stale 并删除。

#### 4.5.1 Context 输出过滤（默认）

`graph.context_for(target_node_id)` 的默认行为：

- 祖先闭包与拓扑排序基准仍基于 **完整 Active causal 子图**（包含被 exclude/delete 的节点），以保证输出顺序稳定且不因过滤而错乱。
- 输出时过滤：
  - 若 `deleted_at` 非空：默认不输出该节点（除非 `include_deleted:true`）
  - 若 `context_excluded_at` 非空：默认不输出该节点（除非 `include_excluded:true`）
- **target 节点必须强制输出**：即使它被 exclude 或 soft-delete，也必须包含在 context 中（避免 executor 无法获得自身 I/O）。

#### 4.5.2 Transcript 视图（不受 exclude 影响）

`graph.transcript_for(target_node_id)` 提供“取对话记录”的稳定入口，默认规则：

- transcript 不受 `context_excluded_at` 影响（exclude 是 context-only 语义）
- transcript 默认不包含：
  - `system_message` / `developer_message`（默认不暴露 prompt）
  - `task` / `summary`
  - “无可读 content 的中间 `agent_message/character_message`”（例如只用于 tool planning 或 tool_calls 的节点）
- 对 `agent_message/character_message`，除 “可读 content” 外：
  - `pending/running` 必须允许进入 transcript（用于 UI 占位/typing indicator）
  - 允许通过 metadata 显式进入 transcript：
    - `metadata["transcript_visible"] == true`：强制进入 transcript
    - `metadata["transcript_preview"]`（可选 String）：当 `payload.output_preview["content"]` 为空时，作为 transcript 展示文本（view 层注入，不写回 body）
  - 终态可见性强化：当节点进入终态且 `metadata["reason"]` 或 `metadata["error"]` 存在时，即使没有可读 content 也必须进入 transcript（典型场景：FailurePropagation 导致下游消息被 `skipped`）
- soft-delete（`deleted_at`）默认从 transcript 中排除（除非 `include_deleted:true`）
- 若 target 节点已 soft-delete 且未显式 `include_deleted:true`，则 transcript 返回空数组

实现要求：

- transcript 的过滤与可选的 preview 覆写应由 `graph.transcript_include?` / `graph.transcript_preview_override` 提供（里程碑 1 默认实现必须满足上述规则；attachable 可覆写以满足不同产品语义）。
- preview 覆写必须满足：
  - 当 `payload.output_preview["content"]` 为空时，优先使用 `metadata["transcript_preview"]`（若存在）
  - 否则对 `errored/rejected/cancelled/skipped` 生成安全预览文本（基于 `metadata["error"]/["reason"]`，截断），避免 UI 空白或泄漏敏感信息

> transcript 的目标是支持 “取最近 X 条对话记录” 等产品需求；它是一种视图层投影，不影响引擎正确性。

> 后续（不在里程碑 1）：当图很大时，`transcript_for` 可能不应依赖 `context_for` 的祖先闭包；建议引入 turn_id 或显式 transcript 索引/边来提供更高效的查询路径。

---

## 5) Leaf invariant（只看 causal；自动修复）

### 5.1 leaf 的定义（Active causal leaf）

一个节点是 leaf，当且仅当：

- 在 Active 图中，它**不存在任何 outgoing blocking edge**（`sequence/dependency`）指向 Active node。
- outgoing `branch` 不影响 leaf 判定。

### 5.2 不变量与修复

leaf 不变量由 `graph.leaf_valid?` / `graph.leaf_repair_*` 决定其 “合法性” 与 “修复动作”；`DAG::Graph` 负责锁/事务/写库/事件。

里程碑 1（Default policy）规则：每个 leaf 必须满足其一：

- `leaf_terminal? == true`（由 NodeBody hooks 决定；里程碑 1 内置为 `agent_message/character_message`）
- 或者 `state in {pending, running}`（允许执行中的中间态 leaf）

里程碑 1（Default policy）修复策略：

- 若发现 leaf 为 terminal 且 `leaf_terminal? == false`，系统自动追加 “默认 leaf repair” 子节点（由 NodeBody hooks 中唯一 `default_leaf_repair? == true` 的 body 决定；里程碑 1 默认 `agent_message(pending)`），并用 `sequence` 连接。
- 修复必须在图锁+事务内进行，并记录事件 `leaf_invariant_repaired`。
- 修复必须在图锁+事务内进行（可观测可通过 hooks 投影，见第 9 节）。

---

## 6) Failure propagation（依赖失败下游自动跳过）

### 6.1 目标

对 dependency 语义：如果父节点进入 terminal 且非 finished，下游依赖它的 pending executable 节点将永远无法被 claim/执行。FailurePropagation 的目标是：

- 防止“永久 pending”的卡死；
- 用显式的 `skipped` 终态表达 “blocked by failed dependencies”。

### 6.2 判定与行为

对任意 Active 节点 `child`：

- `child.state == pending`
- 由于 “pending/running 必须可执行” 不变量，`child` 必须是可执行节点（`NodeBody.executable? == true`）
- 存在任一 incoming `dependency` Active edge，使得其 parent 满足：
  - parent 为 terminal 且 `parent.state != finished`

则：

- `child` 迁移为 `skipped`
- 写入 `finished_at`
- `metadata` 合并：
  - `"reason": "blocked_by_failed_dependencies"`
  - `"blocked_by": [{"node_id": "...", "state": "...", "edge_id": "..."}, ...]`

### 6.3 幂等与闭包

- 仅允许 `pending → skipped`，对 terminal 节点无副作用（幂等）。
- 需要反复运行直到稳定（fixpoint），以处理 “A blocked → B blocked → C blocked” 的链式传播。

---

## 7) Graph mutations（fork/retry/regenerate/edit）

### 7.1 统一约束（必须）

所有“改图”操作必须满足：

- 在 `DAG::Graph#mutate!` 内执行（图锁 + 事务边界 + leaf 修复 + kick）
- 只操作 Active 图（目标节点必须 `compressed_at IS NULL`）
- 任何归档（archive）必须同时归档 **nodes + incident edges**，保持 Active 图结构性要求（第 1.2）。
- 可观测/审计可通过 hooks 投影实现（见第 9 节；不影响引擎正确性）。

### 7.2 fork（新增分支，不改写旧图）

目的：从某个历史节点分出一条新“继续对话/继续任务”的分支。

前置条件：

- `from_node` 为 Active
- `from_node` 为 terminal（避免从执行中 fork）

行为：

1) 创建新的 `branch` lane（分区）：
   - `role = "branch"`
   - `parent_lane_id = from_node.lane_id`
   - `forked_from_node_id = from_node.id`
2) 创建 `new_node`（按入参 node_type/state/payload），并显式写入 `lane_id = new_lane.id`
3) 创建 causal `sequence`: `from_node → new_node`
4) 创建 lineage `branch`: `from_node → new_node`，`metadata["branch_kinds"] = ["fork"]`
5) 写回 `new_lane.root_node_id = new_node.id`

### 7.3 replace（版本替换：retry/regenerate/edit 的共同骨架）

replace 的共同语义：在 Active 图中以 `new_node` 替换 `old_node`，并将旧版本归档到 Inactive 图。

共同步骤（old → new）：

1) 创建 `new_node`（同 node_type；payload/input 复制或覆盖；output 清空或保留按操作定义）
2) 复制 old 的 **incoming blocking edges** 到 new（from 不变，to=new）
3) 创建 lineage `branch`：`old → new`，`branch_kinds=["retry|regenerate|edit"]`
4) 归档 old（以及需要归档的下游子图/边界，见各操作定义）
5) 可通过 hooks 投影 `node_replaced`（kind、old_id/new_id、归档范围；见第 9 节）

Active 版本确定规则：

- **未归档（`compressed_at IS NULL`）的版本即为当前 Active 版本**。

### 7.4 retry（失败节点重试：接管 pending 下游）

目的：对失败的 executable 节点重试，同时接管其尚未执行的下游主路径。

前置条件：

- `old.body.retriable? == true`（当前：`task`/`agent_message`/`character_message`）
- `old.state in {errored, rejected, cancelled}`
- `old` 为 Active
- old 的 **Active causal descendants（不含 old）必须全部为 pending**  
  （即：下游允许存在，但必须全部未执行；禁止出现 running/terminal，以避免改写已执行语义）

行为差异点：

- new 节点：
  - `state = pending`
  - `retry_of_id = old.id`
  - `metadata["attempt"]` 自增（若缺省则从 1 起）
- `payload.input` 复制自 `old.body.input_for_retry`
- outgoing：
  - old 的 **outgoing blocking edges** 会被 new 接管（重新创建为 `new → child`）
  - old 的 incident edges 会被归档（从 Active 图移除）

### 7.5 regenerate（LLM 回复重新生成：leaf 版本替换）

目的：对已完成的 `agent_message/character_message` 重新生成（swipe 多版本）。

前置条件：

- `old.body.regeneratable? == true`（当前：`agent_message`/`character_message`）
- `old.state == finished`
- `old` 为 **leaf**（无 outgoing blocking edges）

行为差异点：

- new 节点：
  - `state = pending`
- `payload.input` 复制自 `old.body.input_for_retry`
- 不接管 outgoing（因为 leaf）
- old 归档

### 7.6 edit（用户编辑历史输入：归档下游并重生）

目的：编辑过去的 `user_message/system_message/developer_message` 内容，旧下游全部失效，需归档并重新生成新下游。

前置条件（2A 稳定性）：

- `old.body.editable? == true`（当前：`user_message`/`system_message`/`developer_message`）
- `old.state == finished`
- old 的 Active causal descendants（不含 old）中 **不得存在 pending/running**
  - 允许存在已完成的下游（将被归档）

行为差异点：

- new 节点：
  - `state = finished`（用户输入立即生效）
  - `finished_at = now`
- `payload.input = old.body.input_for_retry deep_merge new_input`
- 归档范围：
  - 归档 old **以及其 entire Active causal descendant closure**（包含 old 自身）
- 不接管 outgoing（下游将由 leaf invariant 重新长出新的默认 leaf repair 节点；里程碑 1 为 `agent_message(pending)`）

### 7.7 多版本（swipe）表达

- regenerate/edit/retry 都通过 replace 产生多版本。
- 历史版本表现为 Inactive nodes/edges；Active 图永远只有一个“当前版本”。
- UI 若要提供 swipe/版本浏览，应：
  - 以 `node_replaced` hooks 的投影（若接入）或 Inactive `branch` 边回溯版本关系；
  - 以 `created_at` 或 `id(uuidv7)` 排序呈现版本序列。

### 7.8 merge（分支合并回目标 lane：创建 join 节点）

目的：把若干 source lanes 的当前 head “汇总/合并” 回目标 lane（通常为 main），引擎通过在 target lane 创建 join 节点表达“汇总点”。

> 重要：merge **不**隐式归档 source lanes。产品若希望 “merge 后结束分支”，应显式调用 `archive_lane!`（见第 7.9 节）。

前置条件（normative）：

- `target_lane.archived_at IS NULL`
- 所有 source lanes 均满足：
  - lane 可以已归档（允许 archived source）
  - `lane.id != target_lane.id`
  - 与 target 属于同一 graph
  - `lane.role != main`（main lane 不允许作为 source 合并进其它 lane）
- `target_from_node.lane_id == target_lane.id`
- 对每个 source：`source_from_node.lane_id == source_lane.id`

行为（normative）：

1) 在 `target_lane` 创建一个新的 join 节点 `join_node`：
   - `state = pending`
   - `lane_id = target_lane.id`
   - `turn_id` 由 DB default 生成（不开启/不继承任何既有 turn）
   - `node_type` 由入参决定（产品示例：`agent_message`）
2) 创建 causal `sequence`: `target_from_node → join_node`（`metadata["generated_by"]="merge"`）
3) 对每个 source 创建 causal `dependency`: `source_from_node → join_node`
   - `metadata["generated_by"]="merge"`
   - `metadata["source_lane_id"]=source_lane.id`

### 7.9 archive_lane（归档 lane：禁止新 turn，可选取消在途执行）

目的：把某个 lane 标记为“对话结束/只允许收尾”。归档后禁止开启新 turn；同 turn 的在途执行（executor/tool 链）可继续补节点并跑完（默认策略）。

API（引擎层示例）：`Mutations#archive_lane!(lane:, mode: :finish|:cancel, at: now, reason: "lane_archived")`

行为（normative）：

- 写入 `lane.archived_at = at`。
- `mode = :finish`（默认）：仅归档，不修改节点状态；归档后仍允许同 turn 收尾（见第 2.7 节）。
- `mode = :cancel`：
  - 将该 lane 内 Active 的 `running → cancelled`（写 `finished_at`，metadata 合并 `reason`）
  - 将该 lane 内 Active 的 `pending → skipped`（写 `finished_at`，metadata 合并 `reason`）
  - 对每个被变更节点 emit `node_state_changed`（`from`/`to`）
- leaf repair 在 archived lane 中 **不得**创建新的 pending work；修复节点应为 terminal（建议 `agent_message(finished)` 并写入 `finished_at`），以避免归档后重新生成待执行节点。

---

## 8) Compression（summary）

### 8.1 与 replace 的区别

- replace：替换一个节点（或归档下游）以形成新版本，语义是“改写主路径”。
- compression：替换一个**已完成子图**为 summary，语义是“上下文经济（context economy）”，不改变因果结构的外部可达性（通过重连边界边保持）。

### 8.2 约束（必须）

- 被压缩的节点必须全部 `finished` 且为 Active
- 被压缩的节点必须全部属于同一个 lane（禁止跨 lane 压缩；summary 必须继承该 `lane_id`）
- summary 节点 **不得成为 leaf**（必须存在至少一条 outgoing blocking edge 指向外部 Active node）

### 8.3 summary payload 约定

- summary 的文本内容写入：
- `body.output["content"] = summary_content`
  - 同步 `output_preview`（截断规则同第 4.4）

---

## 9) Hooks（非规范：可观测/副作用投影）

Hooks 用于将 DAG 引擎的关键动作投影到外部系统（例如 `events` 表、metrics、审计日志）。**Hooks 不参与引擎正确性**：

- hooks 的实现是可选的（默认 no-op）。
- hooks 任何异常会被吞掉并记录日志，不能阻塞图推进。

接口约定：

- attachable 可以实现 `dag_graph_hooks` 返回一个 hooks 对象（否则使用 no-op）。
- hooks 的统一入口为：`hooks.record_event(graph:, event_type:, subject_type:, subject_id:, particulars: {})`

约定的 `event_type`（里程碑 1）：

- `node_created`：创建 node
- `edge_created`：创建 edge
- `node_replaced`：replace（retry/regenerate/edit）产生新版本
- `subgraph_compressed`：压缩子图产生 summary
- `leaf_invariant_repaired`：leaf 修复追加节点
- `node_state_changed`：节点状态迁移
- `node_visibility_change_requested`：可见性变更请求被 defer 入队（`request_*` 返回 `:deferred`）
- `node_visibility_changed`：节点可见性字段实际发生变化（strict 立即生效、或 defer patch apply 生效）
- `node_visibility_patch_dropped`：pending patch 被清理（例如 node 已归档/不存在导致 patch stale）

实现约束：

- 引擎侧会对 `event_type` 做白名单校验（`DAG::GraphHooks::EventTypes::ALL`）。新增类型必须同步更新常量与本文档，否则视为实现与规范不一致。

`node_state_changed` 的触发点（里程碑 1）：

- Scheduler claim：`pending → running`
- Runner apply_result：`running → finished/errored/rejected/cancelled`
- FailurePropagation：`pending → skipped`

可见性相关 hooks 的触发点（里程碑 1）：

- `node_visibility_change_requested`：`DAG::Node#request_*` 在不满足 strict gating 时写入 `dag_node_visibility_patches`
- `node_visibility_changed`：
  - `DAG::Node#exclude_from_context!/include_in_context!/soft_delete!/restore!`（strict）
  - `DAG::Node#request_*` 在满足 gating 时立即生效（source=`request_applied`）
  - `DAG::Graph#apply_visibility_patches_if_idle!` 消费 patch（source=`defer_apply`）
- `node_visibility_patch_dropped`：`DAG::Graph#apply_visibility_patches_if_idle!` 清理 stale patch（node missing/inactive）

---

## 10) Audit/Repair（非规范：诊断与自愈工具）

为降低脏数据的连带故障面、支持 CI/线上排障，里程碑 1 提供 `DAG::GraphAudit`（非规范性工具）：

- `DAG::GraphAudit.scan(graph:)`：只读扫描常见问题（返回 issue 列表）
- `DAG::GraphAudit.repair!(graph:)`：在 graph lock 内 best-effort 修复一组安全问题（不改变引擎语义）

覆盖的 issue 类型（里程碑 1）：

- `misconfigured_graph`：图配置错误（例如 `dag_node_body_namespace` 缺失/非法、NodeBody hooks 互相冲突等；修复：无自动修复，仅用于诊断）
- `cycle_detected`：Active 图存在环（修复：无自动修复，仅用于诊断）
- `toposort_failed`：Active 图拓扑排序异常（非环导致的失败；修复：无自动修复，仅用于诊断）
- `active_edge_to_inactive_node`：active edge 指向 inactive node（修复：压缩该 edge）
- `stale_visibility_patch`：patch 指向 inactive node（修复：删除 patch）
- `leaf_invariant_violation`：Active 图 leaf 不合法（修复：调用 `validate_leaf_invariant!`）
- `stale_running_node`：running lease 过期（修复：running→errored，见 2.3.1）
- `unknown_node_type`：Active node 的 `node_type` 无法映射到 NodeBody class（修复：无自动修复，仅用于诊断）
- `node_type_maps_to_non_node_body`：`node_type` 映射到了非 NodeBody 的常量（修复：无自动修复，仅用于诊断）
- `node_body_drift`：`node_type` 约定映射与存储的 NodeBody STI `type` 不一致（修复：无自动修复，仅用于诊断）

`misconfigured_graph` 的 `details.problems[].code`（里程碑 1）：

- `attachable_missing`
- `dag_node_body_namespace_missing`
- `dag_node_body_namespace_not_module`
- `node_body_namespace_has_no_bodies`
- `node_body_class_load_error`
- `node_type_key_mismatch`
- `node_type_key_collision`
- `node_body_hook_error`
- `default_leaf_repair_not_unique`
- `default_leaf_repair_not_executable`
- `default_leaf_repair_not_leaf_terminal`
- `invalid_created_content_destination`
- `missing_turn_anchor_node_type`（warn）
- `missing_transcript_candidate_node_type`（warn）

Rake tasks（可选）：

- `bin/rails dag:audit[graph_id]`
- `bin/rails dag:repair[graph_id]`
