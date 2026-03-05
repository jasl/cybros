# Conversation 行为规范（产品层，App 视角）

本文档描述 **App/产品层** 所依赖的 `Conversation` 行为语义（branch/fork、swipe、delete/restore、exclude/include、stop/cancel），并明确这些行为如何在内部映射到 DAG，但 **不要求** App 直接操纵 DAG 细节。

> DAG 引擎规范见：`docs/dag/behavior_spec.md` 与 `docs/dag/public_api.md`。本文档只约束产品层 API（`Conversation` facade）与 UI/Controller 依赖的可观察行为。

---

## 1) 核心概念与边界

### 1.1 Public entity

- App 的第一实体是 `Conversation`（路由 `/conversations/...`）。
- `Conversation` 对外暴露的“聊天 API”是 **facade**（`Conversation#append_user_message!`、`#regenerate!`、`#select_swipe!`、`#create_child!`、`#soft_delete_node!` 等）。
- Controller/Channel/View **不得**直接依赖 DAG 的内部结构细节（例如手写 edge 遍历、假设 main lane 等）。

### 1.2 Source of truth 与 projection

- **聊天记录（Message）不是新真相表**：UI 的线性对话历史是对 DAG 的 **projection**。
- 线性 projection 的主要入口是 `DAG::Lane#message_page`（以及 transcript/context 相关 API），`Conversation` 负责选择正确的 lane + head。

---

## 2) Conversation tree（对话树）

### 2.1 Conversation kinds

`Conversation.kind` 取值：

- `root`：拥有 `dag_graph` 的根容器
- `branch` / `thread` / `checkpoint`：对话树中的子会话（共享 root graph，但绑定到不同 lane）

### 2.2 Root graph 与 lane 绑定

- `root` conversation 拥有 `dag_graph`，并通过 `chat_lane` 绑定到 graph 的 main lane。
- child conversation **不拥有** graph；通过 `root_graph` 委托到 root；通过 `chat_lane` 绑定到 fork 出来的 branch lane。

### 2.3 Fork point（分支点）保护

- 如果一个 node 是某个 child conversation 的 `forked_from_node_id`（fork point），则该 node **不得**被 soft delete（见 5.4）。

### 2.4 Fork（branch/thread/checkpoint）创建约束

`Conversation#create_child!` 作为产品层的 fork API，除了 DAG 层的基本可行性约束（例如 node 必须终态）之外，还必须满足：

- fork 节点必须属于当前 `Conversation#chat_lane`（避免跨 lane 误 fork）
- fork 节点不得为 soft-deleted
- fork 节点类型必须满足 `NodeBody#forkable? == true`（默认保守，只有“消息类节点”覆盖为 true）

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
- **Non-tail regenerate**：自动创建 child conversation（branch），并在 child 上执行 regenerate（避免改写历史）。

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

- UI/Controller 路径必须优先走 `Conversation#chat_lane` + `DAG::Lane` 的 bounded APIs（如 `message_page`），避免无意间触发全图闭包/全图扫描。
- 200+ turns + 多分支情况下，产品层在任何用户请求路径上不得调用“危险 API”（例如全量 mermaid/closure）作为默认行为。
