# DAG Injectable Policy (per-graph) — Design

## Why

本轮产品层（`Conversation` facade）已经对 fork / swipe(adopt) / regenerate(rerun) / delete 等能力做了较严格的 guard。

但在代码库里仍然存在直接调用 DAG 引擎写 API 的可能（测试、脚本、未来新代码、误用），导致**绕过产品层 policy** 的风险。

目标是在 **不阻塞 DAG 自身运转** 的前提下，为“用户语义操作”提供引擎级的 **defense-in-depth**。

---

## Goals

- 每个 `DAG::Graph` 可注入一个 policy（per-graph），由 `graph.attachable` 提供。
- policy **只 gate 高阶用户语义操作**：fork / rerun / adopt / edit / visibility changes（strict + deferred）。
- 引擎自动化/维护路径默认绕过：runner state transitions、leaf invariant repair、turn anchor maintenance、visibility patch apply 等。

---

## Non-goals

- 不引入 actor/current_user 贯穿引擎 API（由应用层选择注入何种 policy）。  
- 不 gate `create_node/create_edge` 来实现“完全不可绕过”（它们是引擎原语，不正交且容易把图卡死）。  

---

## API & Injection

### 1) Engine interface: `DAG::GraphPolicy`

新增：

- `DAG::GraphPolicy#assert_allowed!(operation:, graph:, subject: nil, details: {})`
- 默认实现 `DAG::GraphPolicy::AllowAll`（无约束）

### 2) Per-graph injection (via attachable)

`DAG::Graph#policy` 的获取规则：

- 若 `attachable.respond_to?(:dag_graph_policy)`，使用 `attachable.dag_graph_policy`（若返回 nil 则回退 AllowAll）
- 否则使用 `AllowAll`

缓存策略与 `DAG::Graph#hooks` 相同（基于 `[attachable_type, attachable_id]` cache key）。

---

## What is gated (user-semantic ops)

policy 只在下列高阶写入口被调用：

- `DAG::Mutations#fork_from!`
- `DAG::Mutations#rerun_replace!`
- `DAG::Mutations#adopt_version!`
- `DAG::Mutations#edit_replace!`
- `DAG::Node` visibility strict：
  - `exclude_from_context!` / `include_in_context!`
  - `soft_delete!` / `restore!`
- `DAG::Node` visibility deferred：
  - `request_exclude_from_context!` / `request_include_in_context!`
  - `request_soft_delete!` / `request_restore!`

这些入口与产品能力直接对应，且具备“用户语义”。

---

## What is explicitly NOT gated (engine must run)

为保证 DAG 不会被 policy 卡死，以下路径默认不受 policy 限制：

- `DAG::Mutations#create_node` / `create_edge` / `merge_lanes!` / `archive_lane!` 等结构原语
- runner/executor 驱动的 node state transitions（pending→running→finished/errored/stopped…）
- leaf invariant repair（`DAG::Graph#validate_leaf_invariant!` 自动修复）
- turn anchor maintenance
- visibility patch apply（deferred patch 的应用）

> 这些路径必须可以让 DAG 在合法状态下持续推进；最极端的限制也只能让 DAG “在合法状态下停止”，不能阻塞运行态的图。

---

## Product policy (Conversation graphs)

为 `Conversation` attachable 的 graph 注入一个产品 policy（实现细节在实现阶段确定），最小约束：

- fork_from：`from_node.body.forkable?` 且 node 未 deleted
- adopt_version：`target.body.swipable?` 且 target 未 deleted
- rerun_replace：`old.body.rerunnable?` 且 node_type 在 allowlist
- edit_replace：`old.body.editable?` 且 node_type 在 allowlist
- visibility：soft_delete 额外要求 `body.deletable?`

产品层仍保留 lane/head/in-flight 等更细的 guard；引擎 policy 作为兜底。

---

## Errors

policy 拒绝时应 raise `DAG::OperationNotAllowedError`（带稳定 `code`），便于产品层捕获并转成 4xx/域错误。

---

## Test plan

新增引擎级测试覆盖：

- policy 能拒绝 fork/rerun/adopt/edit/soft_delete 等操作
- runner state transitions、leaf repair、turn anchor maintenance、patch apply 不受影响

同时跑全量 `CI= bin/rails test` 防回归。

