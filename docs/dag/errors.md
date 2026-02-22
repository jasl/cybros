# DAG Errors（错误体系）

本文档约定 DAG 引擎的错误分层，以及 `ValidationError#code/#details` 的使用规范。

---

## 1) 错误层级（Hierarchy）

- `DAG::Error < StandardError`：DAG 域内错误的统一捕获入口
- `DAG::ValidationError < DAG::Error`：**参数/业务状态/合法性校验失败**
  - 典型场景：cursor 互斥、分页参数非法、节点/车道不属于该图、非法状态转换等
- `DAG::SafetyLimits::Exceeded < DAG::Error`：安全带超限（nodes/edges 扫描上限、context window 上限等）
  - 注意：这不是“业务校验失败”，不属于 `ValidationError`

> 约定：DAG Public API 内显式抛出的“参数/状态不合法”统一使用 `DAG::ValidationError`，不再用 `ArgumentError`。

---

## 2) `ValidationError#code`（稳定分类码）

`DAG::ValidationError` 提供：

- `#code`：稳定分类码（String）
- `#details`：结构化补充信息（Hash）

约定：

- DAG 生产代码内显式 raise 的 `ValidationError` **必须提供 `code`**
- `code` 被视为 Public API：**一旦落地就应保持稳定**（后续可改 message，但不要改 code）
- 命名规范：小写点分层，带域前缀
  - 例如：`dag.lane.cursor_turn_id_is_unknown_or_not_visible`
  - 例如：`dag.mutations.idempotency_key_collision_with_mismatched_state`

---

## 3) `ValidationError#details`（可用户可见）

与 AgentCore 一致：`details` 只放可安全暴露、体积受控、JSON 友好的字段（避免 secrets 与大对象）。
