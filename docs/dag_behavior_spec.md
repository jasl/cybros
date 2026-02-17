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

### 1.3 include_compressed（约定）

- **默认行为**：只在 Active 图上工作（Context、Scheduler、Leaf、可视化默认）。
- **include_compressed=true**：用于审计/回放/Debug；允许同时看 Active + Inactive（即“全量图”）。

---

## 2) Nodes（类型、状态机、payload 映射）

### 2.1 节点类型（`dag_nodes.node_type`）

- `user_message`：用户输入
- `agent_message`：LLM/Agent 输出
- `task`：可执行动作（tool/MCP/skill 等）
- `summary`：子图压缩后的替代节点

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

- `started_at`：仅在 `pending → running` 时写入
- `finished_at`：仅在进入 terminal state 时写入（含 skipped/cancelled）

### 2.4 可执行节点（Executable）

仅以下 node_type 会被 Scheduler claim 并由 Runner 执行：

- `task`
- `agent_message`

### 2.5 NodePayload（STI + JSONB I/O）

所有“业务重字段”放入 `dag_node_payloads`，通过 `dag_nodes.payload_id` 一对一关联。

Payload 的列级约定：

- `input`：输入侧（用户消息内容、tool call 参数等）
- `output`：输出侧（LLM 回复、tool result 等，可能很大）
- `output_preview`：输出预览（由 output 派生的小片段，默认用于 Context/Mermaid）

#### 2.5.1 node_type ↔ payload STI 的强一致性

Active 视图内必须保持以下映射一致（不允许 drift）：

- `user_message` → `Messages::UserMessage`
- `agent_message` → `Messages::AgentMessage`
- `task` → `Messages::ToolCall`
- `summary` → `Messages::Summary`

#### 2.5.2 负载字段最小约定

- `user_message`：
  - `payload.input["content"]`：String（必须）
  - `payload.output`：通常为空
- `agent_message`：
  - `payload.output["content"]`：String（常用）
- `task`（ToolCall）：
  - `payload.input["name"]`：String（建议）
  - `payload.input["arguments"]`：JSON（建议）
  - `payload.output["result"]`：JSON/String（常用）
- `summary`：
  - `payload.output["content"]`：String（必须）

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
  "node_type": "user_message|agent_message|task|summary",
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

### 4.4 output_preview 规则（统一、可验证）

`output_preview` 只用于 “小片段可读输出”，必须满足：

- **上限固定**：字符串按固定上限截断（当前实现上限为 `200 chars`）
- **非字符串**：先 JSON 序列化再截断
- 默认优先级（从 output 派生）：
  1) 有 `content` 则取 `content`
  2) 否则有 `result` 则取 `result`
  3) 否则若 output 只有一个 key，取该 key/value
  4) 否则取整段 JSON 的截断字符串

允许 STI 子类覆写派生逻辑，但必须遵守上限与可读性目标。

---

## 5) Leaf invariant（只看 causal；自动修复）

### 5.1 leaf 的定义（Active causal leaf）

一个节点是 leaf，当且仅当：

- 在 Active 图中，它**不存在任何 outgoing blocking edge**（`sequence/dependency`）指向 Active node。
- outgoing `branch` 不影响 leaf 判定。

### 5.2 不变量与修复

规则：每个 leaf 必须满足其一：

- `node_type == agent_message`
- 或者 `state in {pending, running}`（允许执行中的中间态 leaf）

修复策略：

- 若发现 leaf 为 terminal 且不是 `agent_message`，系统自动追加一个 `agent_message(pending)` 子节点，并用 `sequence` 连接。
- 修复必须在图锁+事务内进行，并记录事件 `leaf_invariant_repaired`。

---

## 6) Failure propagation（依赖失败下游自动跳过）

### 6.1 目标

对 dependency 语义：如果父节点进入 terminal 且非 finished，下游依赖它的 pending executable 节点将永远无法被 claim/执行。FailurePropagation 的目标是：

- 防止“永久 pending”的卡死；
- 用显式的 `skipped` 终态表达 “blocked by failed dependencies”。

### 6.2 判定与行为

对任意 Active 节点 `child`：

- `child.state == pending`
- `child.node_type in {task, agent_message}`
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
- 必须记录 `events`（审计/回放）。

### 7.2 fork（新增分支，不改写旧图）

目的：从某个历史节点分出一条新“继续对话/继续任务”的分支。

前置条件：

- `from_node` 为 Active
- `from_node` 为 terminal（避免从执行中 fork）

行为：

1) 创建 `new_node`（按入参 node_type/state/payload）
2) 创建 causal `sequence`: `from_node → new_node`
3) 创建 lineage `branch`: `from_node → new_node`，`metadata["branch_kinds"] = ["fork"]`

### 7.3 replace（版本替换：retry/regenerate/edit 的共同骨架）

replace 的共同语义：在 Active 图中以 `new_node` 替换 `old_node`，并将旧版本归档到 Inactive 图。

共同步骤（old → new）：

1) 创建 `new_node`（同 node_type；payload/input 复制或覆盖；output 清空或保留按操作定义）
2) 复制 old 的 **incoming blocking edges** 到 new（from 不变，to=new）
3) 创建 lineage `branch`：`old → new`，`branch_kinds=["retry|regenerate|edit"]`
4) 归档 old（以及需要归档的下游子图/边界，见各操作定义）
5) 记录事件 `node_replaced`（kind、old_id/new_id、归档范围）

Active 版本确定规则：

- **未归档（`compressed_at IS NULL`）的版本即为当前 Active 版本**。

### 7.4 retry（失败节点重试：接管 pending 下游）

目的：对失败的 executable 节点重试，同时接管其尚未执行的下游主路径。

前置条件：

- `old.node_type in {task, agent_message}`（仅可执行节点可 retry）
- `old.state in {errored, rejected, cancelled}`
- `old` 为 Active
- old 的 **Active causal descendants（不含 old）必须全部为 pending**  
  （即：下游允许存在，但必须全部未执行；禁止出现 running/terminal，以避免改写已执行语义）

行为差异点：

- new 节点：
  - `state = pending`
  - `retry_of_id = old.id`
  - `metadata["attempt"]` 自增（若缺省则从 1 起）
  - `payload.input` 复制自 `old.payload.input_for_retry`
- outgoing：
  - old 的 **outgoing blocking edges** 会被 new 接管（重新创建为 `new → child`）
  - old 的 incident edges 会被归档（从 Active 图移除）

### 7.5 regenerate（LLM 回复重新生成：leaf 版本替换）

目的：对已完成的 agent_message 重新生成（swipe 多版本）。

前置条件：

- `old.node_type == agent_message`
- `old.state == finished`
- `old` 为 **leaf agent_message**（无 outgoing blocking edges）

行为差异点：

- new 节点：
  - `state = pending`
  - `payload.input` 复制自 `old.payload.input_for_retry`
- 不接管 outgoing（因为 leaf）
- old 归档

### 7.6 edit（用户编辑历史输入：归档下游并重生）

目的：用户编辑过去的 user_message 内容，旧下游全部失效，需归档并重新生成新下游。

前置条件（2A 稳定性）：

- `old.node_type == user_message`
- `old.state == finished`
- old 的 Active causal descendants（不含 old）中 **不得存在 pending/running**
  - 允许存在已完成的下游（将被归档）

行为差异点：

- new 节点：
  - `state = finished`（用户输入立即生效）
  - `finished_at = now`
  - `payload.input = old.payload.input_for_retry deep_merge new_input`
- 归档范围：
  - 归档 old **以及其 entire Active causal descendant closure**（包含 old 自身）
- 不接管 outgoing（下游将由 leaf invariant 重新长出新的 `agent_message(pending)`）

### 7.7 多版本（swipe）表达

- regenerate/edit/retry 都通过 replace 产生多版本。
- 历史版本表现为 Inactive nodes/edges；Active 图永远只有一个“当前版本”。
- UI 若要提供 swipe/版本浏览，应：
  - 以 `events.event_type=node_replaced` 的链条或 Inactive `branch` 边回溯版本关系；
  - 以 `created_at` 或 `id(uuidv7)` 排序呈现版本序列。

---

## 8) Compression（summary）

### 8.1 与 replace 的区别

- replace：替换一个节点（或归档下游）以形成新版本，语义是“改写主路径”。
- compression：替换一个**已完成子图**为 summary，语义是“上下文经济（context economy）”，不改变因果结构的外部可达性（通过重连边界边保持）。

### 8.2 约束（必须）

- 被压缩的节点必须全部 `finished` 且为 Active
- summary 节点 **不得成为 leaf**（必须存在至少一条 outgoing blocking edge 指向外部 Active node）

### 8.3 summary payload 约定

- summary 的文本内容写入：
  - `payload.output["content"] = summary_content`
  - 同步 `output_preview`（截断规则同第 4.4）
