# DAG Public API（v1 草案）

本文件定义 **DAG 引擎对 App 域暴露的稳定 Public API**（鼓励开发者/Agent 只通过这些 API 操作图），以减少对内部实现细节（表结构、具体 SQL、内部类）的耦合。

> 目标：API 正交（orthogonal）+ 可组合（composable）+ 可测试（testable）。  
> 约定：若 Public API 不够用，应先 **补齐/重构 Public API**，而不是从 App 域直接 `graph.nodes.create!` / `update_columns` “硬改图”。

## 1) 基本约束

- **写入必须在图锁内**：所有会改变图结构/状态的动作，都必须走 `DAG::Graph#mutate!`（引擎负责 advisory lock + 行锁 + 事务边界 + leaf invariant 修复 + kick）。
- **Active view 语义**：默认 API 只看 Active（`compressed_at IS NULL`）；审计/回放场景才显式使用 `include_compressed: true`。
- **JSON 一律 string keys**：所有持久化到 JSONB 的字段（`metadata/payload/particulars` 等）约定使用 string keys；Public API 返回的 Hash 也使用 string keys（便于直接 JSON 序列化与跨语言一致）。

## 2) 读 API（Read-only）

### Graph-level

- `DAG::Graph#context_for(target_node_id, limit_turns: 50, mode: :preview|:full, include_excluded:, include_deleted:)`（安全默认：bounded window）
- `DAG::Graph#context_for_full(target_node_id, limit_turns: 50, include_excluded:, include_deleted:)`
- `DAG::Graph#context_closure_for(target_node_id, mode: :preview|:full, include_excluded:, include_deleted:)`（危险：祖先闭包 + topo sort）
- `DAG::Graph#context_closure_for_full(target_node_id, include_excluded:, include_deleted:)`
- `DAG::Graph#context_node_scope_for(target_node_id, limit_turns: 50, include_excluded:, include_deleted:)`（返回 ActiveRecord::Relation；无 topo 顺序保证）
- `DAG::Graph#node_event_page_for(node_id, after_event_id: nil, limit: 200, kinds: nil)`（bounded；keyset；用于流式/进度/UI 订阅）
- `DAG::Graph#node_event_scope_for(node_id, kinds: nil)`（返回 ActiveRecord::Relation；无顺序保证）
- `DAG::Graph#awaiting_approval_page(limit: 50, after_node_id: nil, subgraph_id: nil)`（bounded；keyset；用于工具授权队列）
- `DAG::Graph#awaiting_approval_scope(subgraph_id: nil)`（返回 ActiveRecord::Relation；无顺序保证）
- `DAG::Graph#transcript_for(target_node_id, limit_turns: 50, limit: nil, mode: :preview|:full, include_deleted:)`（安全默认：bounded window）
- `DAG::Graph#transcript_for_full(target_node_id, limit_turns: 50, limit: nil, include_deleted:)`
- `DAG::Graph#transcript_closure_for(target_node_id, limit: nil, mode: :preview|:full, include_deleted:)`（危险：祖先闭包）
- `DAG::Graph#transcript_closure_for_full(target_node_id, limit: nil, include_deleted:)`
- `DAG::Graph#transcript_recent_turns(limit_turns:, mode: :preview|:full, include_deleted:)`
- `DAG::Graph#transcript_page(subgraph_id:, limit_turns:, before_turn_id: nil, after_turn_id: nil, mode: :preview|:full, include_deleted:)`
- `DAG::Graph#to_mermaid(include_compressed: false, max_label_chars: 80)`

### Subgraph-level（面向真实产品分页）

对 “ChatGPT-like 聊天记录 / SillyTavern-like 子话题 / Codex-like 多线程” 的 UI，推荐优先使用 subgraph-scoped 的分页原语，避免把不同 subgraph 的 turns 混在一个列表里：

- `DAG::Subgraph#transcript_page(limit_turns:, before_turn_id: nil, after_turn_id: nil, mode: :preview|:full, include_deleted:)`
  - 返回 `{ turn_ids:, before_turn_id:, after_turn_id:, transcript: }`
  - `before_turn_id` / `after_turn_id` 为 keyset cursor（按 `turn_id`），避免 OFFSET
  - 说明：turn 的“代表锚点”由 `dag_turns.anchor_node_id` 维护；turn 的排序/分页只按 `turn_id`（UUIDv7）进行
- `DAG::Subgraph#turns`（ActiveRecord 关联：返回该 subgraph 的 `DAG::Turn` records；包含未 anchor 的 turns）
- `DAG::Subgraph#anchored_turn_page(limit:, before_seq: nil, after_seq: nil, include_deleted: true|false)`（bounded；按 `anchored_seq` keyset）
- `DAG::Subgraph#anchored_turn_count(include_deleted: true|false)`（`include_deleted: true` 为 O(1) 读取 `next_anchored_seq`）
- `DAG::Subgraph#anchored_turn_seq_for(turn_id, include_deleted: true|false)`
- `DAG::Subgraph#turn_node_ids(turn_id, include_compressed: false, include_deleted: true)`

Subagent（子代理/子会话）模式（v1）：

- 参考：`docs/dag_subagent_patterns.md`（推荐用多 Conversation/Graph 在 App 域组合，而不是在 DAG 层引入跨图调度语义）

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

- `DAG::Mutations#create_node(...)`
- `DAG::Mutations#create_edge(from_node:, to_node:, edge_type:, metadata: {})`
- `DAG::Mutations#fork_from!(...)`
- `DAG::Mutations#merge_subgraphs!(...)`
- `DAG::Mutations#archive_subgraph!(...)`

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
  - `DAG::Node#deny_approval!`（`awaiting_approval → rejected`，默认 `metadata["reason"]="approval_denied"`）
  - `DAG::Node#stop!`（`pending|awaiting_approval|running → stopped`）

### 3.4 Executor interface（流式/增量输出）

执行器（executor）是 App 域注入的能力，但其接口也被视为 v1 Public API 的一部分：

- `DAG.executor_registry.execute(node:, context:, stream:)`
  - `context`：来自 `graph.context_for(node.id)` 的 bounded 上下文
  - `stream`：`DAG::NodeEventStream`，用于写入 `dag_node_events`（流式输出/进度/log）

完成模式（严格二选一）：

- **非流式**：executor 返回 `DAG::ExecutionResult.finished(payload: ...)` 或 `finished(content: ...)`
- **流式**：executor 通过 `stream.output_delta(...)` 写入增量输出，并返回 `DAG::ExecutionResult.finished_streamed(...)`
  - 约束：`finished_streamed` 不允许同时携带 `payload` 或 `content`（避免语义漂移）
- **停止**（可选）：executor 返回 `DAG::ExecutionResult.stopped(reason: ...)`（Runner 会落库为 `stopped`；若有 streaming output 会物化 partial output）

node events retention（规范性约定）：

- `output_delta` 只保证 “执行中可订阅/可分页”；当 node 进入终态后，`output_delta` 可能被清理并写入单条 `output_compacted`（payload 含 `chunks/bytes/sha256`），UI 应改读 `NodeBody.output/output_preview` 作为最终输出来源。

## 4) 审计 / 诊断 API

- `DAG::GraphAudit.scan(graph:)`：只诊断，不修复（默认 types）
- `DAG::GraphAudit.repair!(graph:)`：只做极小范围自动修复（例如 stale running reclaim / leaf repair / stale patch 清理）

## 5) 明确的非 Public API（尽量不要直接用）

以下属于内部实现细节，App 域不应直接依赖（否则会导致未来重构困难）：

- 直接 `graph.nodes.create! / graph.edges.create!`（除非在引擎内部/测试中明确需要）
- 直接 `update_all / update_columns` 修改节点状态（应走 Runner/FailurePropagation/commands）
- 直接依赖某个 SQL/索引形态（应依赖 Public query 方法）

## 6) 当 Public API 不够用时怎么办？

优先顺序：

1. 先为缺失能力补一个 Public API（带测试与文档），并在 App 域迁移到新 API。
2. 必要时允许破坏性改动：重命名/拆分 API、调整返回结构、调整索引/迁移（允许 `db:reset`）。
3. 只有在紧急 debug/一次性脚本中，才临时直接读写表；且应在 PR 内明确标注并尽快回收。
