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

- `child_conversation.dag_graph.main_lane.transcript_recent_turns(limit_turns: N)`（最常用）
- `child_conversation.dag_graph.main_lane.transcript_page(limit_turns: N, before_turn_id: ...)`（需要分页/游标时）
- 若要“锚定某个节点做审计”：`child_conversation.dag_graph.transcript_for(target_node_id, limit_turns: N)`

## 1.1) Native tools（P1 已落地）

为了把上述“跨图”模式变成模型可调用的原语，Cybros 提供两个 native tools：

- `subagent_spawn`：创建 child `Conversation/Graph`，写入 metadata 契约，并在 child 图中生成最小可执行 turn（`developer_message` finished + `user_message` finished + `agent_message` pending + `sequence` edges）。
- `subagent_poll`：基于 child id 返回子会话状态（`running/pending/awaiting_approval/idle/missing`）、main lane leaf、以及 bounded transcript 预览（默认 10 turns，最大 50）。

child conversation metadata 契约（写入 `conversations.metadata`）：

```json
{
  "agent": {
    "key": "subagent:<name>",
    "policy_profile": "full|minimal|memory_only|skills_only",
    "context_turns": 50
  },
  "subagent": {
    "name": "<name>",
    "parent_conversation_id": "<uuid>",
    "parent_graph_id": "<uuid>",
    "spawned_from_node_id": "<uuid>"
  }
}
```

运行时 profile 生效（关键）：

- `AgentCore::DAG.runtime_resolver` 会读取 `conversation.metadata["agent"]`，并用 `Policy::Profiled` 包裹 base policy，使 `policy_profile/context_turns` 立刻影响该会话的工具可见性与授权判定。

安全约束（当前默认）：

- 禁止 nested spawn：当 `execution_context.attributes[:agent][:key]` 为 `subagent` 或以 `subagent:` 开头时，`subagent_spawn` 直接返回错误。
- bounded 输出（避免 tool 输出膨胀）：
  - `subagent_poll.limit_turns` 默认 10、最大 50；当显式传入非整数/越界值时返回校验错误（不做 silent coercion）。
  - `transcript_lines` 为预览用途；单行会做 bytes 截断（当前约 1000 bytes）。
- `subagent_poll` 目前按 `child_conversation_id` 直接读取会话，不校验其是否为“本会话 spawn 的 child”；如需更强隔离，可在工具层增加 parent 校验或通过 tool policy 限制可见性。
- profiles 是“额外收敛层”：tool 可见性与授权结果取决于 `policy_profile` 与 app 注入的 base policy 的 **交集**（runtime 默认仍可保持 deny-by-default）。
- `context_turns` 仅接受 1..1000；非法值会在 runtime_resolver 中降级为默认值（不会抛出到执行路径）。

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
