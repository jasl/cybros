# DAG Subagent Patterns（v1）

本文件描述 **在不改变 DAG 拓扑/调度语义** 的前提下，App 域如何用 “多 Conversation/Graph” 组合出 subagent（子代理/子会话）能力。

> v1 约束：DAG 只对 **单图内** 的调度与审计负责；跨图依赖/等待/桥接由 App 的 executor 自行实现（轮询、回调、事件桥接等）。

## 1) 推荐建模：subagent = 独立 Conversation/Graph

**父图**用一个 `task` 节点（或自定义 node_type）表示 “创建/唤起 subagent”，并在该节点的 `metadata` 或 `output` 中保存 child 引用：

- `metadata["subagent"]["child_conversation_id"]`
- `metadata["subagent"]["child_graph_id"]`

完成后，父图的下游 `agent_message`/`character_message` 节点在执行时：

1) 从 context 读取 child 引用  
2) 通过 child graph 的 **bounded read API** 读取子会话的最近记录  
3) 把读取到的内容拼接/总结为父图的最终输出

典型读 API 选择：

- `child_conversation.transcript_recent_turns(limit_turns: N)`（最常用）
- `child_conversation.dag_graph.main_subgraph.transcript_page(limit_turns: N, before_turn_id: ...)`（需要分页/游标时）
- 若要“锚定某个节点做审计”：`child_conversation.transcript_for(target_node_id, limit_turns: N)`

## 2) 父子图之间如何等待/同步？

v1 不提供跨图 edges；推荐由 App executor 定义同步策略：

- **同步等待**：父图 task executor 创建子图并执行到稳定（或等待 child 图 leaf 完成），再返回结果给父图。
- **异步等待**：父图 task executor 仅创建/触发 child 图执行，然后返回一个引用；父图后续节点可轮询 child 图状态，或订阅 child 的 node events/graph events 做回调式推进。

## 3) 事件与回放

子图自身的 streaming/events（`dag_node_events`）与 transcript/context 都是独立的审计面。父图只需要保存 child 引用即可：

- UI 可把 child conversation 当作一个可导航的子线程入口（“打开 subagent 会话”）
- 审计时可分别扫描父/子两张图（`DAG::GraphAudit.scan`）

## 4) 示例测试（产品级场景）

参考场景测试：

- `test/scenarios/dag/subagent_child_conversation_flow_test.rb`

该测试展示：

- 父图 `task` 创建 child Conversation/Graph
- 父图 `agent_message` 用 bounded API 读取子图 transcript 并输出总结
- 父/子两张图的 `GraphAudit.scan` 均为空

