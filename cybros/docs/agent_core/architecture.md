# AgentCore（DAG-first）架构说明

本文档描述 `AgentCore` 在 Cybros 内的落点、分层、依赖方向与与 DAG 的边界。

> 目标：移植旧实验 AgentCore 的“能力”，但 **运行与持久化完全依赖 DAG**（ActiveJob + Solid Queue），不保留旧 PromptRunner/Continuation 的运行架构。

---

## 1) 目录与模块

- 核心模块：`lib/agent_core/**`
- DAG 集成：`lib/agent_core/dag/**`
- DAG 引擎：`lib/dag/**` + `app/models/dag/**`
- NodeBody（app 侧）：`app/models/messages/*.rb`

命名：沿用 `AgentCore`，降低迁移认知成本；但 **执行模型为 DAG-first**。

---

## 2) 分层与依赖方向

```
App (Conversation / UI / Policy wiring)
  └── AgentCore::DAG.runtime_resolver (注入 Runtime)
        ├── provider (SimpleInferenceProvider / 自定义)
        ├── tools_registry / tool_policy
        ├── skills_store / memory_store / injections
        └── budget / compact / observability

DAG engine (Scheduler/Runner/Mutations/Context/Compression)
  └── DAG.executor_registry -> executor.execute(node:, context:, stream:)
        ├── AgentCore::DAG::Executors::AgentMessageExecutor
        └── AgentCore::DAG::Executors::TaskExecutor

AgentCore core (Message/Tool/Policy/MCP/Skills/PromptBuilder/Observability)
  └── 不直接依赖 app；只依赖 Ruby/Rails 运行时与 injected adapter
```

依赖约束：

- `AgentCore::DAG::*` **依赖 DAG**（作为执行与持久化基座）。
- `lib/agent_core/**` 不允许反向依赖 `app/**`（除 `AgentMemoryEntry` 这类明确的 AR 模型边界）。
- app 业务层通过 `runtime_resolver` 注入：tools/policy/skills/memory/injections/instrumenter 等。

---

## 3) DAG-first 执行模型（替代 PromptRunner）

一次 user↔LLM exchange 视为一个 DAG `turn_id`：

- `user_message (finished)` → `agent_message (pending/running/finished)`
- LLM 若产出 `tool_calls`：
  - executor 在同一 `turn_id` 下创建多个 `task` 节点
  - 再创建下一步 `agent_message` 节点（pending）
  - 通过 edges 表达“工具结果进入上下文后再继续”：
    - 默认：`task -> next_agent_message` 为 `sequence`（工具失败/拒绝也能继续）
    - 仅 required approval gate：`dependency`

执行由 DAG 引擎驱动：

- `DAG::Scheduler.claim_executable_nodes` 负责 claim
- `DAG::Runner.run_node!` 负责：
  - 组装 context（preview/full）
  - 创建 `DAG::NodeEventStream`（用于 streaming output_delta）
  - 调用 executor 并落库 payload/content/metadata
  - `FailurePropagation` + leaf invariant 校验

---

## 4) DAG 增强点（本次迁移引入）

为避免“Executor 先取 preview、再取 full”的重复查询：

- `DAG::ExecutorRegistry#context_mode_for(node)`：executor 可声明 `:full` 或 `:preview`。
- `DAG::Runner` 在执行前按需调用 `graph.context_for_full`。

为支持 streaming：

- `DAG::ExecutionResult.finished(..., streamed_output: true)` 表示：
  - 内容由 `NodeEventStream#output_delta` 累积
  - finish 时允许写入 payload，但不允许同时提供 `content`

---

## 5) 可注入 Runtime（App 边界）

见 `docs/agent_core/public_api.md`。
