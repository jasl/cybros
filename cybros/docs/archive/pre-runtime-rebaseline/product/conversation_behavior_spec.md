# Conversation 行为规范（产品层，App 视角）

本文档描述 **App/产品层** 所依赖的 `Conversation` 行为语义（branch/fork、swipe、delete/restore、exclude/include、stop/cancel），并明确这些行为如何在内部映射到 DAG，但 **不要求** App 直接操纵 DAG 细节。

> DAG 引擎规范见：`docs/dag/behavior_spec.md` 与 `docs/dag/public_api.md`。本文档只约束产品层 API（`Conversation` facade）与 UI/Controller 依赖的可观察行为。

---

## 1) 核心概念与边界

### 1.1 Public entity

- App 的第一实体是 `Conversation`（路由 `/conversations/...`）。
- `Conversation` 对外暴露的“聊天 API”是 **facade**（`Conversation#append_user_message!`、`#append_user_message_and_project!`、`#edit_user_message!`、`#retry_agent_node!`、`#steer_current_turn!`、`#regenerate!`、`#select_swipe!`、`#create_child!`、`#soft_delete_node!` 等）。
- Controller/Channel/View **不得**直接依赖 DAG 的内部结构细节（例如手写 edge 遍历、假设 main lane 等）。
- 引擎层可注入 `DAG::GraphPolicy` 作为 defense-in-depth：即使绕过 facade 直接调用 DAG 的高阶写原语，也能被 policy 兜底拦截（不阻塞 runner/leaf repair 等引擎自动化路径；详见 `docs/dag/public_api.md`）。

### 1.2 Source of truth 与 projection

- **聊天记录（Message）不是新真相表**：UI 的线性对话历史是对 DAG 的 **projection**。
- 线性 projection 的主要入口是 `Conversation` 的 bounded read APIs（例如 `Conversation#message_page` / `#transcript_page` / `#context_for`），`Conversation` 在内部选择正确的 lane + head 并完成投影；App **不得**直接依赖 `DAG::Lane` 或其他引擎类型。

### 1.3 Action policy（产品层动作字典）

- Message projection 还会附带一个 **app-facing action policy dictionary**（当前键名：`action_policy`），作为 Web UI / future API client / native app 的统一动作契约。
- 该字典的第一层分为：
  - `actions`：面向产品动作（例如 `retry` / `regenerate` / `swipe` / `branch` / `edit` / `delete`）
  - `capabilities`：保留给更低层的运行能力（例如 `execute`）
- 每个 action entry 至少包含：
  - `supported`：该 node type 是否支持该动作类别
  - `available`：在当前 conversation/lane/state/topology 下是否可立即发起
  - 可选 `mode` / `reason`
- 重要分层：
  - `NodeBody#retriable?` / `#rerunnable?` / `#forkable?` / `#swipable?` / `#deletable?` / `#editable?` 只表达 **type-level support**
  - `DAG::Node#can_*?` 表达 **low-level mutation guard**
  - `Conversation::NodeActionPolicy` 组合两者并加入产品语义（例如 tail/non-tail regenerate、deferred delete），形成 App/UI 应消费的最终字典
- UI 不应再根据 `state == finished` / `state == errored` / “当前是不是 tail” 自行猜测按钮可见性；应消费 projection 里的 `action_policy`。

---

## 2) Conversation tree（对话树）

### 2.1 Conversation kinds

`Conversation.kind` 取值：

- `root`：拥有 root graph 的根容器（引擎实现细节；App 不直接触达）
- `branch` / `thread` / `checkpoint`：对话树中的子会话（共享 root graph，但绑定到不同 lane）

### 2.2 Root graph 与 lane 绑定

- `root` conversation 拥有 root graph，并通过 `chat_lane` 绑定到 root 的 chat lane（通常是默认 lane）。
- child conversation **不拥有** graph；通过 `root_graph` 委托到 root；通过 `chat_lane` 绑定到 fork 出来的 branch lane。

### 2.3 Fork point（分支点）保护

- 如果一个 node 是某个 child conversation 的 `forked_from_node_id`（fork point），则该 node **不得**被 soft delete（见 5.4）。

### 2.4 Fork（branch/thread/checkpoint）创建约束

`Conversation#create_child!` 作为产品层的 fork API，除了 DAG 层的基本可行性约束（例如 node 必须终态）之外，还必须满足：

- fork 节点必须属于当前 `Conversation#chat_lane`（避免跨 lane 误 fork）
- fork 节点不得为 soft-deleted
- fork 节点类型必须满足 `NodeBody#forkable? == true`
  - 当前产品层只对 assistant message 暴露 branch；user message 不提供 branch
- 当从 assistant branch 且未显式提供 `user_content` 时，child conversation 的第一条消息应是该 assistant 的 snapshot，不得自动插入空 user turn，也不得立刻自动生成一条新 assistant reply

---

## 3) Swipe（regenerate 的多版本）

### 3.1 表示方式

Swipe 由同一 `version_set_id` 下的多个版本表示（DAG 多版本语义）：

- regenerate 会创建一个新版本（旧版本变为 inactive）
- swipe 选择会“采纳（adopt）”某个版本为当前 active 版本

产品层不依赖自定义 swipe metadata；版本序列以 DAG 的版本集合为准。

### 3.1.1 可 swipe 类型（swipable?）

为避免对非“可替换输出”的节点提供 swipe，产品层只允许对满足 `NodeBody#swipable? == true` 的节点执行 swipe（默认保守；通常仅 `agent_message`/其子类覆盖为 true）。

### 3.2 Transcript / Context 行为

- **Transcript**：天然只展示 active 图上的当前版本（同一 `version_set_id` 仅一个 active 版本）。
  - 旧版本作为 inactive 节点保留用于审计/浏览。
- **Context**：同理，context/page 也只会遍历 active 图的当前版本。

### 3.3 Regenerate 规则

- **Tail agent regenerate**：在同一 conversation/lane 内创建新变体并默认选中。
- **Non-tail regenerate**：自动创建 child conversation（branch），child 的第一条消息是被选中的 assistant snapshot；不在 child 上立刻自动 rerun（避免改写历史，也避免无输入的即时重放）。
- `retry` 与 `regenerate` 是两个不同的产品动作：
  - `retry`：面向 `errored` / `stopped` 的失败恢复
  - `regenerate`：面向已完成 assistant version 的重新生成（可能是 in-place，也可能是 branch）

### 3.4 Latest user edit

- 只有当前 conversation/lane 中**最后一条可见 user message** 可以触发 `edit`。
- edit 的产品语义是：保留审计历史、替换这条 user 输入，并基于新输入重新生成它后面的 assistant continuation。
- 历史 user message 不暴露 edit；user message 也不暴露 branch。
- edit 后仍应复用正常的 app-layer pre-turn 保护（例如 oversize guard / compact_context），而不是绕过这些输入策略。

---

## 4) Exclude / Include（上下文可见性）

- `exclude` 仅影响 prompt/context，不应强制从 transcript/timeline 消失。
- `include` 恢复上下文可见性。
- 对不可立即变更可见性的节点（例如非终态或图非 idle）允许使用 deferred patch（见 DAG 文档的 visibility patches），但产品层应尽量保证 UI 语义一致（必要时通过 stop/等待 idle 后应用）。

---

## 5) Soft delete / Restore（隐藏 + 回滚安全）

### 5.1 Soft delete 的目标

soft delete 代表“用户从产品视角删除/隐藏某条内容”，其语义包含：

- 从 timeline/projection 中隐藏
- 从 context 中排除

### 5.1.1 可删除类型（deletable?）

为避免删除带外部副作用的节点，产品层只允许删除满足 `NodeBody#deletable? == true` 的节点类型：

- `user_message` / `agent_message` / `character_message`：允许删除（消息类节点）
- `task`：默认不允许删除（可能有外部副作用；应保留审计链路）
- `system_message` / `developer_message` / `summary`：默认不允许删除（更接近“配置/压缩产物/审计节点”）

### 5.2 Restore

restore 反向操作，恢复可见性（timeline + context）。

### 5.3 “Stop generating” 与运行中安全

用户删除时可能存在进行中的生成/执行。产品层必须提供“stop generating”级别的安全语义：

- 若目标 node 处于 `pending|awaiting_approval|running`，产品层应先 stop，使其进入 `stopped` 终态（或在无法立即 stop 时保证最终会停下并被隐藏）。

### 5.4 Rollback boundary（触发节点 / 下游节点）

产品层的回滚规则（当前约束）：

- **只有当删除的是当前 chat head 本身，或当前 chat head 的 trigger 节点（即 head 的 sequence parent）时**，才需要对下游 work 做 stop/cancel（否则会“误伤”当前正在生成的最新回复）。
- 当触发回滚时，产品层应：
  - stop 下游 `pending|awaiting_approval|running` work（以 head 为起点的 causal descendants）
  - cancel 与这些 work 对应的 `ConversationRun`（若存在）

### 5.5 Fork point 保护（再次强调）

若 node 为 fork point，则 soft delete **必须拒绝**（返回 422/域错误），避免破坏对话树引用语义。

---

## 6) 性能与安全带（产品层约束）

- UI/Controller 路径必须优先走 `Conversation` 的 bounded read APIs（如 `message_page` / `transcript_page`），避免无意间触发全图闭包/全图扫描；App 不应直接拿到 `DAG::Lane` 并调用其方法。
- 200+ turns + 多分支情况下，产品层在任何用户请求路径上不得调用“危险 API”（例如全量 mermaid/closure）作为默认行为。

---

## 7) Input policies / retry / composer rail

### 7.1 Policy resolution 是 App 层真相源

- `Conversation#resolved_input_policy(app_override:, action:, interrupted_output_policy_override:)` 是运行时的唯一 policy resolver。
- precedence 固定为：
  - app/channel override
  - `conversation.metadata["input_policy"]`
  - agent/profile default
  - global default
- 只有 `retry` 与 `steer_current_turn` 允许动作级 `interrupted_output_policy_override`，且其优先级高于所有静态默认值。
- Controller/View/JS 不应自行 merge policy hash，也不应直接依赖 profile YAML 作为运行时真相源。

### 7.2 User input append 统一走 Conversation facade

- 所有用户输入入口都应走 `Conversation#append_user_message!`（或 `#append_user_message_and_project!`）。
- append 路径在 App 层统一处理：
  - user-message coalescing
  - `queue` / `interrupt_new_turn`
  - 单条 oversize guard
  - 多消息历史 overflow 的 transient `compact_context`
- `append_user_message_and_project!` 额外返回：
  - 新建/更新消息 projection
  - 对应 `node_ids`
  - `composer_state`

### 7.3 Retry / steer 的产品语义

- `Conversation#retry_agent_node!` 支持 **不限次人工 retry**；自动 retry 仍由 engine/runtime 的独立恢复策略控制。
- manual retry 不再向产品层暴露 `retry_limit_reached`。
- `Conversation#steer_current_turn!` 是显式 same-turn user-version replacement API，不是普通 append 的别名。
- 当 steer policy 不允许同 turn 替换时，产品层可以按 policy 回退到 `interrupt_new_turn`；但如果当前没有 active run，则 `steer_current_turn!` 必须拒绝，而不是悄悄 append 一个新 turn。

### 7.4 Oversize 与 transcript 可见性

- 单条 soft oversize：插入已完成的 `task(compress_input)`，由压缩结果进入后续 assistant turn。
- 单条 hard oversize：保留原始 `user_message`，并追加 transcript-visible 的 `product_message`；此路径不创建 assistant node/run，也不暴露 assistant actions。
- 多消息/历史 overflow：插入 transient `task(compact_context)`，仅作为 app-layer pre-turn compaction 机制，不替代 engine-layer `auto_compact`，也不创建 durable `summary`。

### 7.5 Composer rail 是独立的 conversation state surface

- `Conversation#composer_state` 是 web composer status rail 的后端真相源。
- rail 承载：
  - queue availability / queued count
  - steer availability / reason
  - candidate next-input preview
- queue / steer / candidate preview 属于 composer/conversation state，不属于 assistant bubble `run_state`。
- UI 应消费 `composer_state`，而不是根据消息列表或运行中 bubble 自行猜测 queue/steer 状态。
