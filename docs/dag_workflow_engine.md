# Cybros Core：DAG 工作流引擎设计（里程碑 1）

本文件描述当前 Rails 项目中 “动态 DAG 会话/工作流引擎” 的核心设计与实现约定（仅覆盖里程碑 1 的 scope）。

## 目标与原则

- **动态 DAG**：会话没有固定终点；节点会随着用户对话与 Agent 执行动态新增，但图在任意时刻都必须保持合法。
- **可观测与可审计**：节点/边与 hooks 投影（例如 `Event`）用于可视化、监控、审计与回放。
- **并发可调度**：基于 edge gating 判定可执行节点；多 worker 可并发 claim，避免重复执行。
- **非破坏压缩**：压缩用于节约上下文，原始节点/边不删除，只标记为 `compressed_at`（审计保留）。

## PostgreSQL 约束

- 依赖 PostgreSQL 18 提供的 `uuidv7()` 作为主键默认值（见 `db/schema.rb`）。
- 所有核心表主键为 `uuid`，并用 `uuidv7()` 生成以获得更好的插入局部性与时间有序性。
- 可靠性例外：对引擎关键枚举字段在 DB 层增加 check constraint（避免脏数据渗透引擎）：
  - `dag_nodes.state`：仅允许固定状态集合
  - `dag_edges.edge_type`：仅允许固定边类型集合

## 领域模型与存储

### 聚合根：`DAG::Graph`

- 模型：`app/models/dag/graph.rb`
- 责任：
  - 图变更的事务边界（`mutate!(turn_id: nil)`：可选 turn_id 传播）
  - 图级别锁（`with_graph_lock!` / `with_graph_try_lock`：advisory lock + 行锁；用于与 tick/runner/mutations 串行化）
  - 语义策略（`policy`）：node_type↔body 映射、leaf invariant 的合法性/修复动作（`DAG::GraphPolicy` / `DAG::GraphPolicies::*`）
  - 叶子不变量自修复（`validate_leaf_invariant!`）
  - 触发调度推进（`kick!` → `DAG::TickGraphJob`）

`DAG::Graph` 通过 `attachable`（polymorphic）关联业务对象（当前为 `Conversation`）。业务对象可选提供：

- `dag_graph_policy`：返回 `DAG::GraphPolicy`（用于 node_type↔body 映射、leaf 修复规则等）
- `dag_graph_hooks`：返回 `DAG::GraphHooks`（用于可观测/审计的 best-effort 投影，例如写入 `events` 表）

### 节点：`DAG::Node`

- 模型：`app/models/dag/node.rb`
- 表：`dag_nodes`
- 关键字段：
  - `node_type`：`user_message | agent_message | task | summary`
  - `state`：`pending | running | finished | errored | rejected | skipped | cancelled`
  - `turn_id`：对话轮次/span 标识（同一轮产生的节点共享）
  - `metadata`：JSONB
  - `retry_of_id`：重试 lineage
  - `compressed_at / compressed_by_id`：压缩标记
  - `context_excluded_at`：从 LLM context（`context_for`）默认输出中排除（纯视图层语义）
  - `deleted_at`：软删除；从 context/transcript 默认输出中排除（纯视图层语义）
  - `claimed_at / claimed_by`：被 Scheduler claim 的时间与执行者标识
  - `lease_expires_at / heartbeat_at`：running lease 过期时间与心跳时间（用于回收卡死 running）
  - `started_at / finished_at`：Runner 实际开始执行 / 进入终态的时间戳

#### NodeBody 扩展表（STI + JSONB）

为控制 `dag_nodes` 行宽并统一存储“业务重字段”，节点负载从 `dag_nodes` 拆出到扩展表：

- 关联：`DAG::Node belongs_to :body, class_name: "DAG::NodeBody"`
- 表：`dag_node_bodies`
  - `type`：Rails STI（按负载类型拆分）
  - `input`：JSONB（输入侧：用户消息、tool call 参数等）
  - `output`：JSONB（输出侧：LLM 回复、tool result 等，可能很大）
  - `output_preview`：JSONB（输出预览：从 `output` 派生的小片段，用于 Context/Mermaid）

> 设计目标：调度器只依赖 `dag_nodes` 的引擎层字段；业务重字段统一落在 body（Context 输出字段名仍为 `payload`），并通过 preview 控制上下文体积。

preview 策略（里程碑 1）：

- 默认上限：`200 chars`（`DAG::NodeBody`）
- `agent_message`（`Messages::AgentMessage`）上限更长：`2000 chars`
- `task`（`Messages::ToolCall`）的 `output_preview["result"]` 对非字符串 result 使用摘要字符串（避免巨大 JSON 的 `to_json` 峰值）

node_type ↔ body STI 映射由 `graph.policy` 决定（`attachable.dag_graph_policy` 可注入）：

- `Conversation`（`Messages::GraphPolicy`）：
  - `user_message` → `Messages::UserMessage`
  - `agent_message` → `Messages::AgentMessage`
  - `task` → `Messages::ToolCall`
  - `summary` → `Messages::Summary`
- 引擎默认（`DAG::GraphPolicies::Default`）：返回 `DAG::NodeBodies::Generic`（通用 body，不依赖任何业务命名空间）

#### 状态语义（skipped/cancelled 明确化）

- `pending`：已创建但未执行
- `running`：已被 claim，正在执行
- `finished`：成功完成（依赖满足仅认 `finished`）
- `errored`：执行失败
- `rejected`：需要授权但被用户拒绝
- `skipped`：**仅允许**从 `pending` 迁移，表示任务未开始且不再需要
- `cancelled`：**仅允许**从 `running` 迁移，表示正在执行的任务被取消

### 边：`DAG::Edge`

- 模型：`app/models/dag/edge.rb`
- 表：`dag_edges`
- `edge_type`：
  - `sequence`（阻塞性）
  - `dependency`（阻塞性）
  - `branch`（非阻塞 lineage）

#### Branch metadata 约定

`branch` 边使用 `metadata["branch_kinds"]`（数组）表达 lineage（例如 `["fork"]`、`["retry"]`）。在压缩边界去重合并时，`branch_kinds` 可能包含多个值（并集）。

### Hooks（可选）：`DAG::GraphHooks`

> DAG 引擎不直接写入 `Event`（也不写任何业务副作用）；它只在关键动作上调用 hooks（best-effort：异常会被吞掉并 log）。

- 接口：`app/models/dag/graph_hooks.rb`
  - `record_event(graph:, event_type:, subject_type:, subject_id:, particulars: {})`
- 注入点：`attachable.dag_graph_hooks`（例如 `Conversation` 返回 `Messages::GraphHooks` 写入 `events` 表）
- 默认：`DAG::GraphHooks::Noop`（不做任何事）
- 约束：引擎侧会对 `event_type` 做白名单校验（`DAG::GraphHooks::EventTypes::ALL`），建议只使用常量（避免 typo）。

## 图不变量（Invariants）

### 1) 无环（Acyclic）

- 边创建时检查是否引入环：
  - 对 `DAG::Graph` 行加锁（序列化并发建边）
  - 通过 recursive CTE 判断 `to_node` 是否可达 `from_node`
- 实现在：`app/models/dag/edge.rb`

### 2) 叶子不变量（Leaf invariant）

定义 leaf：没有任何未压缩 outgoing **blocking edge**（`sequence/dependency`）指向 active node 的节点（`DAG::Graph#leaf_nodes`）。

规则：每个 leaf 必须满足其一：

- `node_type == agent_message`
- 或者 `state in {pending, running}`（允许执行中的中间态）

修复策略：leaf invariant 的合法性判定与修复动作由 `graph.policy` 决定；里程碑 1（Default policy）会在 mutation 后发现 leaf 为终态且不是 `agent_message` 时，自动追加一个 `agent_message(pending)` 子节点并以 `sequence` 连接（见 `DAG::Graph#validate_leaf_invariant!`）。

## 调度与执行

### Scheduler：claim executable nodes

- 入口：`DAG::Scheduler.claim_executable_nodes`
- 实现：`lib/dag/scheduler.rb`
- 可执行（executable）判定：
  - `dag_nodes.state = pending`
  - `node_type in (task, agent_message)`
  - incoming 阻塞边满足 edge gating：
    - `sequence`：父节点为 **terminal**（`finished/errored/rejected/skipped/cancelled`）即可 unblock
    - `dependency`：父节点必须为 **finished** 才 unblock
- 并发语义：
  - `SELECT ... FOR UPDATE SKIP LOCKED`
  - 原子更新为 `running` 并设置 `claimed_at/claimed_by/lease_expires_at`（`started_at` 由 Runner 实际开始执行时写入）

> 依赖失败传播：对 `dependency` 的父节点若进入 terminal 但非 finished，下游 executable `pending` 节点会被自动标记为 `skipped`（见 `DAG::FailurePropagation`），避免图推进卡死。

> 可观测（hooks）：Scheduler claim 会尝试 emit `node_state_changed`（`pending → running`）。

### Runner：执行与落库

- 实现：`lib/dag/runner.rb`
- 幂等：
  - 非 `running` 节点直接 no-op
  - 状态写入使用“期望状态条件更新”（避免竞态覆盖）
- 执行流程：
  1. 组装上下文 `graph.context_for(node)`
  2. `DAG.executor_registry.execute(node:, context:)`
  3. 按结果落库为终态（并尝试 emit `node_state_changed` hooks）
     - 观测信息：
       - `dag_nodes.metadata["usage"]`：executor 回传的 tokens/cost usage（一次执行/一次调用）
       - `dag_nodes.metadata["output_stats"]`：输出体积/结构统计（含 `pg_column_size` 的 DB 侧字节大小；仅 finished 写入）
  4. 执行后触发下一轮 tick

> 语义约束：`skipped` 是 `pending` 终态，因此 Runner（处理 running 节点）收到 `ExecutionResult.skipped` 视为不合法并转为 `errored`。

> 可观测（hooks）：FailurePropagation 会尝试 emit `node_state_changed`（`pending → skipped`）。

### Jobs：推进图执行（Solid Queue / ActiveJob）

- `DAG::TickGraphJob`
  - 对同一 graph 做 tick 去重（advisory lock try-lock）
  - 在图锁内执行顺序：`FailurePropagation` → `graph.apply_visibility_patches_if_idle!` → Scheduler claim
  - claim executable nodes → enqueue `DAG::ExecuteNodeJob`
- `DAG::ExecuteNodeJob`
  - 调用 Runner 执行单节点
  - finally 再 enqueue tick 以推进后继

相关代码：
- `app/jobs/dag/tick_graph_job.rb`
- `app/jobs/dag/execute_node_job.rb`

## 上下文组装（Context Assembly）

入口：`DAG::Graph#context_for(target_node_id)`（`Conversation#context_for` delegate）

实现：`lib/dag/context_assembly.rb`

步骤：

1. recursive CTE 收集祖先闭包（只走未压缩的 **因果边**）：
   - 仅包含：`sequence/dependency`
   - `branch` 为纯 lineage，不参与 context
   - 防御性硬化：忽略 “active edge 指向 inactive node” 的端点（active endpoint filtering）
2. 过滤已压缩节点：默认排除 `compressed_at IS NOT NULL`
3. 对闭包内 `sequence/dependency` 做稳定拓扑排序（tie-breaker：`id` 字典序）
4. 输出结构（默认 preview）：`[{node_id, node_type, state, payload:{input,output_preview}, metadata}]`
   - 每个节点额外包含：`turn_id`（用于按轮次分组与强 gating 输入）

`context_for_full` 会额外输出 `payload.output`（用于审计/调试/特殊 executor）。

Context 可见性（视图层）：

- `context_for` 默认会过滤：
  - `context_excluded_at IS NOT NULL`
  - `deleted_at IS NOT NULL`
- 可通过参数显式包含：
  - `include_excluded:true`
  - `include_deleted:true`
- target 节点无论是否被 exclude/delete 都会强制包含在输出中（避免 executor 缺失自身 I/O）。
- 写入期 gating（里程碑 1）：
  - 仅允许对 terminal 节点设置/清除 `context_excluded_at/deleted_at`
  - 且要求 graph idle（Active 图中不存在任何 `state=running` 的节点）
  - 目的：避免执行中上下文被改导致不可解释行为
  - 若需要 “运行中先申请，空闲后生效”，可使用 request API（defer queue）：
    - `request_exclude_from_context!/request_include_in_context!/request_soft_delete!/request_restore!`
    - 可能返回 `:deferred` 并写入 `dag_node_visibility_patches`；Tick job 在 graph idle + node terminal 时自动应用并消费队列（详见 behavior spec）。

> 压缩的替代来自“重连”后的边：summary 节点与外部边界相连，因此闭包会包含 summary 而不是被压缩的原始节点。

更完整的 DAG 行为规范见：`docs/dag_behavior_spec.md`。

## Transcript（对话记录视图）

为支持产品侧 “取最近 X 条对话记录” 等需求，`DAG::Graph` 提供 transcript 投影：

- `graph.transcript_for(target_node_id, limit: nil, mode: :preview, include_deleted: false)`
  - 默认只保留 `user_message` 与可读的 `agent_message`
  - 默认不包含 `task/summary`，不暴露 tool chain 细节
  - `context_excluded_at` 不影响 transcript（exclude 是 context-only）
  - `agent_message` 可通过 metadata 显式进入 transcript：
    - `metadata["transcript_visible"] == true`
    - `metadata["transcript_preview"]`（可选 String，作为展示文本）

> transcript 是视图层 API，不改变 DAG 结构与调度语义。

> 后续建议：当图很大时，考虑用 turn_id / transcript 索引（或专用边）提供不依赖 context 闭包的 transcript 查询路径。

## 子图压缩（Manual）

入口：`DAG::Graph#compress!`（`Conversation#compress!` delegate）

实现：`lib/dag/compression.rb`

约束（事务内校验）：

- 所选节点必须同一 graph、且均 `finished`
- 节点/相关边必须尚未压缩
- summary **不得成为 leaf**（必须存在至少一条 outgoing 边到外部）

操作：

1. 创建 summary 节点（`node_type=summary,state=finished`），`metadata["replaces_node_ids"]`
2. 标记 inside 节点 `compressed_at/compressed_by_id`；标记 inside 相关边 `compressed_at`
3. 识别边界边并重连：
   - outside → summary（复制 edge_type/metadata）
   - summary → outside（复制 edge_type/metadata）
4. **边界去重合并**：若多个边界边重连后会坍缩为同一条边（触发 `dag_edges` 唯一索引冲突），会合并为一条，并在 `metadata["replaces_edge_ids"]` 记录被合并的边集合。

## 可视化（Mermaid）

入口：`DAG::Graph#to_mermaid`（`Conversation#to_mermaid` delegate）

实现：`lib/dag/visualization/mermaid_exporter.rb`

- 输出：`flowchart TD`
- 节点 label：`{type}:{state} {snippet}`
- `branch` 边 label：`branch:{branch_kinds.join(",")}`

## Bench（非 CI gate）

脚本：`script/bench/dag_engine.rb`

目前覆盖：

- 线性 1k 节点创建
- fan-out + join 的 context_for
- scheduler claim 100

运行：

```bash
bin/rails runner script/bench/dag_engine.rb
```

## 当前已知限制（里程碑 1 范围内）

- executor 仅提供接口与默认 NotImplemented 行为（真实 LLM/tool/MCP 执行不在当前 scope）
- branch 边为纯 lineage：用于 provenance/可视化；不参与 scheduler/context/leaf（更复杂的分支合并/回放策略留到后续里程碑讨论）
