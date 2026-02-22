# DAG Public API（v1 草案）

本文件定义 **DAG 引擎对 App 域暴露的稳定 Public API**（鼓励开发者/Agent 只通过这些 API 操作图），以减少对内部实现细节（表结构、具体 SQL、内部类）的耦合。

> 重要约定（Lane-first）：**App 侧默认只操作 Lane / Turn / Message（Node）视图**。  
> `DAG::Graph` 仍存在，但其“全图语义”读 API（closure / mermaid / audit-like）必须被视为 **危险操作**，只用于后台/诊断/离线任务，不应出现在用户同步请求路径。

---

## 1) 基本约束

- **写入必须在图锁内**：所有会改变图结构/状态的动作，都必须走 `DAG::Graph#mutate!`（引擎负责 advisory lock + 行锁 + 事务边界 + leaf invariant 修复 + kick）。
- **Active view 语义**：默认 API 只看 Active（`compressed_at IS NULL`）；审计/回放场景才显式使用 `include_compressed: true`。
- **JSON 一律 string keys**：所有持久化到 JSONB 的字段（`metadata/payload/particulars` 等）约定使用 string keys；Public API 返回的 Hash 也使用 string keys。
- **分页一律 keyset**：所有面向产品 UI 的分页 API 禁止 OFFSET；统一使用 `before_* / after_*` cursor。
- **limit 强约束**：所有分页 API 的 `limit` 会被 clamp 到 `<= 1000`（避免误用造成不必要的全量扫描）。
- **错误类型约定**：Public API 的“参数/状态不合法”统一 raise `DAG::ValidationError`（不再用 `ArgumentError`），并提供稳定的 `code` + safe `details` 便于分类捕获与结构化日志；安全带超限 raise `DAG::SafetyLimits::Exceeded`（两者均继承 `DAG::Error`）。

---

## 2) 读 API（Read-only）

### 2.1 Lane-level（App-safe；面向真实产品 UI）

推荐 UI 优先使用 Lane-scoped 的分页原语，避免把不同 Lane 的内容混在一个列表里。

- `DAG::Lane#message_page(limit:, before_message_id: nil, after_message_id: nil, mode: :preview|:full, include_deleted: false)`
  - **用途**：按“消息节点（transcript candidates）”分页，满足“取最近 X 条消息”的 UI 需求。
  - 返回：`{"message_ids"=>[], "before_message_id"=>..., "after_message_id"=>..., "messages"=>[...]}`（string keys）
  - cursor：按 `message_id == dag_nodes.id`（UUIDv7）keyset
  - 实现细节（重要）：引擎会对“扫描候选节点数”做内部 hard cap（安全带），因此当大量候选节点被 transcript 规则过滤时，页可能 **少于 limit**（极端情况下为空）。
- `DAG::Lane#transcript_page(limit_turns:, before_turn_id: nil, after_turn_id: nil, mode: :preview|:full, include_deleted: false)`
  - **用途**：按 turn 分页（ChatGPT-like 一轮交互展示/滚动加载）。
  - 返回：`{"turn_ids"=>[], "before_turn_id"=>..., "after_turn_id"=>..., "transcript"=>[...]}`（string keys）
  - turn 的可见锚点由 `dag_turns.anchor_node_id` 维护；turn 的排序/分页按 `turn_id`（UUIDv7）
- Turn 索引/计数（面向压缩/定位；**不等价于 transcript 可见性**）：
  - `DAG::Lane#anchored_turn_page(limit:, before_seq: nil, after_seq: nil, include_deleted: true|false)`（按 `anchored_seq` keyset）
  - `DAG::Lane#anchored_turn_count(include_deleted: true|false)`
  - `DAG::Lane#anchored_turn_seq_for(turn_id, include_deleted: true|false)`
  - 说明（与实现一致）：
    - `anchored_seq` 一旦分配就不会回填/重算；即使某个 turn 的所有 anchor nodes 都被压缩，turn 仍可能出现在 `anchored_turn_*` 的索引里。
    - `transcript_page` 的 turn 可见性取决于 `dag_turns.anchor_node_id(_including_deleted)`；当可见锚点变为 `NULL`（例如该 turn 的所有 anchor nodes 都被压缩）时，该 turn 会从 `transcript_page` 中消失。
- Turn/节点定位（面向 debug/压缩策略）：
  - `DAG::Lane#turn_node_ids(turn_id, include_compressed: false, include_deleted: true)`

流式/审批队列（Lane-first wrapper；仍为 bounded read）：

- `DAG::Lane#node_event_page_for(node_id, after_event_id: nil, limit: 200, kinds: nil)`
- `DAG::Lane#awaiting_approval_page(limit: 50, after_node_id: nil)`

Executor 组装上下文（bounded window；Lane 入口避免 App 直接持有 Graph）：

- `DAG::Lane#context_for(target_node_id, limit_turns: 50, mode: :preview|:full, include_excluded: false, include_deleted: false)`
- `DAG::Lane#context_for_full(...)`
- `DAG::Lane#context_node_scope_for(...)`（返回 ActiveRecord::Relation；无 topo 顺序保证）
  - 实现细节（重要）：引擎会对 context window 的候选 **nodes/edges** 做内部 hard cap（安全带），超限时 raise `DAG::SafetyLimits::Exceeded`（避免单个 turn 或脏数据导致爆炸扫描）。
  - 可选：通过 ENV 调整（仅引擎内部）：`DAG_MAX_CONTEXT_NODES` / `DAG_MAX_CONTEXT_EDGES`

### 2.2 Turn-level（App-safe；Turn 是“有规则的子图视图”）

- `DAG::Turn#start_message_node_id(include_deleted: false)`（turn anchor：通常为 `user_message`，也可能是 `agent_message/character_message`）
- `DAG::Turn#end_message_node_id(include_deleted: false)`（按 `message_nodes` 投影后的最后一条 message；用于“运行中用 start、结束后用 end”的 UI 表示）
- `DAG::Turn#message_nodes(mode: :preview|:full, include_deleted: false)`（只返回 transcript candidates + projection）

### 2.3 Graph-level（Dangerous / Internal）

Graph 是引擎聚合根（锁/事务边界），但 **全图语义** 的读 API 必须被视为危险操作：

- `DAG::Graph#context_closure_for*`（危险：祖先闭包 + topo sort）
- `DAG::Graph#transcript_closure_for*`（危险：祖先闭包）
- `DAG::Graph#to_mermaid(...)`（危险：可能扫全图）

> 说明：Graph 仍提供若干 bounded window 的读 API（例如 `context_for`），但产品层推荐从 `DAG::Lane` 入口调用，以避免“无意间把 Graph 当作 App 的常用入口”。

---

## 3) 写 API（Mutations / Commands）

### 3.1 统一写入口：`DAG::Graph#mutate!`

```rb
graph.mutate!(turn_id: maybe_turn_id) do |m|
  # 只在这里做写入
end
```

约定：

- **一切创建/连边/改状态/改可见性**，都通过 block 内的 `m`（`DAG::Mutations`）或 node 的 command 方法完成。
- `mutate!` 返回后，引擎会在必要时自动 `kick!` 推进调度。

### 3.2 Mutations（结构性改图）

> 以下方法被视为 Public API（v1）。

- `DAG::Mutations#create_node(...)`（支持 `lane:` / `lane_id:`；若提供 `turn_id` 会强制 lane 与该 turn 一致）
- `DAG::Mutations#create_edge(from_node:, to_node:, edge_type:, metadata: {})`
- `DAG::Mutations#fork_from!(...)`（fork 会创建 branch lane，并把 fork 创建的第一条新 node 作为该 lane 的 root）
- `DAG::Mutations#merge_lanes!(...)`
- `DAG::Mutations#archive_lane!(...)`

### 3.3 Node commands（版本 / 可见性 / 重试）

> 以下方法被视为 Public API（v1）。

- 版本：
  - `DAG::Node#retry!` / `#can_retry?`
  - `DAG::Node#rerun!` / `#can_rerun?`
  - `DAG::Node#adopt_version!`
  - `DAG::Node#edit!(new_input:)` / `#can_edit?`
- 可见性（严格/延迟）：
  - `exclude_from_context!` / `include_in_context!`
  - `soft_delete!` / `restore!`
  - `request_exclude_from_context!` / `request_include_in_context!`
  - `request_soft_delete!` / `request_restore!`
- 审批 / stop：
  - `DAG::Node#approve!`（`awaiting_approval → pending`）
  - `DAG::Node#deny_approval!`（`awaiting_approval → rejected`）
  - `DAG::Node#stop!`（`pending|awaiting_approval|running → stopped`）

---

## 4) 当 Public API 不够用时怎么办？

优先顺序：

1. 先为缺失能力补一个 Public API（带测试与文档），并在 App 域迁移到新 API。
2. 必要时允许破坏性改动：重命名/拆分 API、调整返回结构、调整索引/迁移（允许 `db:reset`）。
3. 只有在紧急 debug/一次性脚本中，才临时直接读写表；且应在 PR 内明确标注并尽快回收。
