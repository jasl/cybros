# DAG Subagent Patterns

本文件描述 programmable-agent runtime 中的 subagent 语义。

## 1. Boundary

- `conversation` 是人类与 agent 的 transcript / turn 边界。
- 显式人类可见的 conversation branch 仍可存在于产品里，但它不是 programmable-agent runtime 的 subagent 主语义。
- `subagent` 是父 turn 拥有的非交互后台 worker。

这意味着：

- subagent 不能直接写父 placeholder。
- subagent 不能直接追加 transcript message。
- subagent 的结果只能作为 parent-owned join input 被消费。

## 2. Runtime Tools

Cybros 当前提供四个 subagent runtime tools：

- `subagent_spawn`
- `subagent_poll`
- `subagent_run`
- `subagent_wait`

它们的公开 contract 以 `subagent_id` 作为稳定标识，而不是任何 conversation-row identifier。

- `subagent_spawn`：创建后台 subagent thread，并返回 `subagent_id`
- `subagent_poll`：基于 `subagent_id` 返回 bounded status snapshot
- `subagent_run`：`spawn + kick + 初始 snapshot`
- `subagent_wait`：等待 subagent 到达稳定态或超时，并返回 bounded snapshot

当前 snapshot 字段包括：

- `subagent_id`
- `operation`
- `status`
- `counts`
- `leaf`
- `transcript_lines`
- `diagnostic_level`
- `wait_status` / `timed_out` / `timeout_ms` / `elapsed_ms`（仅 wait）

这些 payload 是 parent-consumable runtime status，不是 transcript mutation。

## 3. Internal Storage

当前实现内部仍可借用 `Conversation` / `DAG::Graph` 承载 subagent 执行状态，但那只是 internal storage choice，不是 public runtime contract。

父侧 authority 始终保留在 parent turn：

- placeholder lifecycle
- user-visible status
- final transcript mutation
- approval / denial
- telemetry attribution

## 4. Ownership And Safety

- 禁止 nested spawn：subagent worker 内再次 `subagent_spawn` / `subagent_run` 会 fail-fast
- `subagent_poll.limit_turns` / `subagent_wait.limit_turns` 为 bounded preview，当前最大 50
- `subagent_wait.timeout_ms` 当前范围为 `0..30000`
- `subagent_poll` / `subagent_wait` 只允许读取“本 parent turn 派生的 subagent”
- `subagent_id` 会做 UUID 校验，错误为 fail-fast validation error
- `diagnostic_level = debug` 只增加观察信息，不会放宽 worker 权限边界

## 5. Parent-Side Join

subagent 的结果应通过父侧显式任务聚合，而不是走 lane merge 或 child transcript 直写。

推荐 join 流程：

1. `subagent_run` 启动 delegated worker
2. `subagent_wait` 观察生命周期
3. 父侧收集 structured result / artifacts / optional `assistant_output_candidate`
4. 父侧聚合决定最终输出草稿
5. 只有 parent `before_finalize_output` / `emit_message` 可以替换当前 placeholder

`assistant_output_candidate` 只是 parent-owned draft material，不是独立消息 authority。

## 6. Testing

参考：

- `test/lib/cybros/subagent/tools_test.rb`
- `test/lib/cybros/subagent/run_wait_tools_test.rb`
- `test/scenarios/dag/subagent_tools_profile_enforcement_flow_test.rb`
- `test/models/conversation/turn_execution_subagent_activity_test.rb`
