# DAG 引擎审计报告（Milestone 1，2026-02-18）

本报告在“宣布完成 Milestone 1 之前”的窗口期内完成，允许为正确性/可靠性/可观测性做破坏性调整；目标是用**场景测试**与**不变量审计**来验证引擎可支撑多类 LLM 应用（Chatbot / 编程 Agent / Roleplay 群聊），并在“改图/隐藏节点”后仍保持图正确。

---

## 1) 审计范围与结论摘要

范围（本次覆盖）：

- DAG 引擎核心：Scheduler / Runner / FailurePropagation / Context / Transcript / Mutations / Compression / 可视化（Mermaid）
- 改图能力：fork / retry / regenerate / edit / visibility patches（exclude/delete 的 request/apply）
- “应用接入”层面：以测试用例模拟 Chatbot、编程 Agent 的并行工具链、SillyTavern/多角色群聊与复杂改图组合

结论（当前实现与测试的落点）：

- `dag_nodes.node_type` 语义增强，新增 `system_message`、`developer_message`、`character_message`，并把 `character_message` 纳入 executable 集合（与 `agent_message` 同级）。
- Transcript 可靠性增强：当下游消息因依赖失败传播被标记为 `skipped`（或其它终态）时，仍能以“安全预览占位”的形式出现在 transcript，避免 UI 只剩用户输入的空白状态。
- 类型系统松绑：移除 `DAG::Node` 对 node_type 的硬编码 enum/允许列表，并把“可执行/转写/安全预览”等语义下沉到 NodeBody；对 conversation graphs，未知 node_type 通过 `dag_node_body_namespace` 的约定映射默认严格失败。
- 进一步下沉类型语义：引入 NodeBody semantic hooks（turn anchor / transcript candidates / leaf terminal / 默认 leaf repair / content 落点 / mermaid snippet），并删除 `DAG::Node` 的 node_type 常量，使 DAG 核心几乎不需要显式分支判断 node_type。
- Audit 能力补强：`DAG::GraphAudit` 新增 `misconfigured_graph`，用于提前暴露 `dag_node_body_namespace` 与 NodeBody hooks 的结构性配置错误（无自动修复，仅诊断）。
- 结构正确性进一步加固：DB 层补齐 graph-scoped 自引用外键（`retry_of_id` / `compressed_by_id`）与压缩字段一致性约束；GraphAudit 新增 cycle/toposort 与 node_type↔NodeBody drift/unknown 检查（均无自动修复，仅诊断）。
- 覆盖率链路修复：修复 Rails 并行测试下 SimpleCov 汇总为 0% 的问题，并设置整体覆盖率门槛 `minimum_coverage = 85`。
- 新增场景级测试集，作为未来正式接入时的示例与回归保障；每个场景都以 `DAG::GraphAudit.scan(graph: graph)` 断言图不变量成立。

---

## 2) 不变量清单（本次确认/加固）

### 2.1 Active 视图结构性要求

- Active edge 的端点必须都是 Active node（归档节点时归档 incident edges）。
- Query 层必须做 active endpoint filtering：把 “active edge 指向 inactive node” 视为不存在（防御性硬化）。

### 2.2 DB 层枚举约束（可靠性例外）

- `dag_nodes.state`：仅允许固定状态集合。
- `dag_edges.edge_type`：仅允许固定边类型集合。
- `dag_nodes.node_type`：不做 DB 枚举约束（允许业务扩展）；对 conversation graphs，严格性由 `attachable.dag_node_body_namespace` + 约定映射（`node_type.camelize` constantize）保证。

同时，为降低跨图引用导致的脏数据故障面、把明显结构错误挡在 DB 层：

- graph-scoped foreign keys（composite FK）：
  - `dag_edges (graph_id, from_node_id/to_node_id)` → `dag_nodes (graph_id, id)`
  - `dag_node_visibility_patches (graph_id, node_id)` → `dag_nodes (graph_id, id)`
  - `dag_nodes (graph_id, retry_of_id)` → `dag_nodes (graph_id, id)`（禁止跨图 retry lineage 引用）
  - `dag_nodes (graph_id, compressed_by_id)` → `dag_nodes (graph_id, id)`（禁止跨图压缩归档引用）
- 压缩字段一致性（check constraint）：`compressed_at` 与 `compressed_by_id` 必须同为 NULL 或同为 NOT NULL（禁止半边写入导致 Active/Inactive 视图与 lineage 不一致）。

### 2.3 Acyclic（无环）

- 新建 edge 必须在图锁内用 recursive CTE 防止引入环。
- GraphAudit 额外提供 active 图 cycle 检测（用于捕获绕过写入期校验的脏边）。

### 2.4 Leaf invariant（只看 Active causal）

- leaf 只由 outgoing blocking edges（`sequence/dependency`）决定。
- 对 conversation graphs：leaf 必须满足：
  - `node_type in {agent_message, character_message}`，或
  - `state in {pending, running}`
- 修复：对 terminal 且不满足 leaf-valid 的 leaf，追加 `agent_message(pending)` 子节点并以 `sequence` 连接（本次保持默认不变）。

### 2.5 Scheduler / Runner / FailurePropagation

- 强不变量：只有 `NodeBody.executable? == true` 的节点才允许处于 `pending/running`；因此 Scheduler/FailurePropagation 不再需要维护 `node_type IN (...)` 的可执行列表。
- edge gating：
  - `sequence`：parent terminal 即可 unblock
  - `dependency`：parent 必须 `finished` 才 unblock
- FailurePropagation：对 dependency 上游 terminal 但非 finished 的情况，把下游 pending 节点标记为 `skipped` 并写入 `metadata["reason"]="blocked_by_failed_dependencies"` 等信息，避免永久 pending 卡死（由于不变量，下游 pending 节点均为可执行节点）。

### 2.6 Context / Transcript（视图层投影）

- `system_message` / `developer_message`：默认进入 context，默认不进入 transcript；内容写入 `payload.input["content"]`。
- `agent_message` / `character_message`：默认进入 context，默认进入 transcript；内容写入 `payload.output["content"]`。
- Transcript 终态可见性强化：当 `agent_message/character_message` 进入 `errored/rejected/cancelled/skipped` 等终态且具备 `metadata["reason"]`/`metadata["error"]` 时，必须允许进入 transcript，并用安全预览占位（避免 UI 空白）。

---

## 3) 发现的问题与修复

### 3.1 SimpleCov 并行测试覆盖率为 0%

现象：

- `bin/rails test` 并行进程运行时，SimpleCov 汇总显示 `0.0%`（master 进程不跑测试、子进程未正确汇总）。

修复：

- 在 `test/test_helper.rb` 启用 `SimpleCov.enable_for_subprocesses true`，并设置 `minimum_coverage 85` 作为 CI gate。

### 3.2 node_type 扩展性与严格性位置不合理

风险：

- `DAG::Node` 内硬编码 node_type enum/允许列表会让业务扩展必须修改引擎核心，导致演进成本高且容易漏改（尤其是 Scheduler/FailurePropagation 的可执行集合）。
- node_type 不做 DB check constraint 时，必须有明确的代码层“严格失败”策略，否则 typo/脏写会导致 Scheduler/Context/Leaf/FailurePropagation 出现不可解释行为。

修复：

- 移除 `DAG::Node` 对 node_type 的 enum/允许列表约束；同时移除 GraphPolicy 体系并合并到 `DAG::Graph`（不再有 `graph.policy` 兼容层）。
- 对 conversation graphs：新增 `attachable.dag_node_body_namespace` 扩展点，按约定映射 `node_type` → `#{namespace}::#{node_type.camelize}`（未知类型默认失败）。
- 新增强不变量：只有可执行 NodeBody 才允许处于 `pending/running`，从而 Scheduler/FailurePropagation 可以移除 `node_type IN (...)` 过滤，避免维护可执行类型列表与类加载问题。

### 3.3 工具失败导致下游消息被 skipped 后 UI 空白

现象：

- FailurePropagation 会把 pending 下游 executable 标记为 `skipped`，若该下游是“消息节点”（agent/character），且没有 `output_preview["content"]`，则 transcript 可能过滤掉它，导致用户只看到自己的输入。

修复：

- Transcript include 规则扩展到 `character_message`，并允许终态且具备 `metadata["reason"]`/`metadata["error"]` 的消息节点进入 transcript。
- Transcript preview override：当 `output_preview["content"]` 为空时，可从 `metadata["transcript_preview"]` 或基于终态 reason/error 生成安全占位文本。

---

## 4) 场景测试索引（接入示例 + 回归保障）

目录：`test/scenarios/dag/`

- `chatbot_flow_test.rb`：GPT 网页版风格（system→developer→user→agent）；验证 context/transcript 默认行为与 leaf repair。
- `agent_tool_calls_flow_test.rb`：编程 Agent 风格（planning→并行 tasks→join 消息）；验证调度顺序、tool result 注入、planning 消息默认隐藏、失败传播导致 skipped 占位可见。
- `roleplay_group_chat_flow_test.rb`：多角色群聊（同 turn 多条 `character_message` 并行执行、其中一个 regenerate）；验证 turn 聚合视图与按节点锚定视图的差异。
- `graph_surgery_and_visibility_flow_test.rb`：visibility patch defer/apply + compress + edit + retry/regenerate 的交叉回归；验证“改图/隐藏节点”组合操作后 GraphAudit 仍为空。

---

## 5) 剩余风险与后续建议

- **Turn 建模与群聊**：当前 `transcript_recent_turns` 以 `user_message` 作为 turn anchor；若要支持“无用户回合的纯角色互聊”，建议引入显式 turn 记录或允许以 `turn_id` 本身作为 anchor（避免必须造占位 user/system 节点）。
- **CTE 性能与索引**：Context/Leaf/Acyclicity 都依赖 recursive CTE；后续可基于真实数据量做 profiling，并按查询形态补齐索引与物化策略。
- **全局 prompt 机制**：`system_message/developer_message` 目前作为 node_type 存在；若产品侧需要“全局 prompt + per-branch override”，建议明确注入点与冲突合并规则，并用专门场景测试固化。
