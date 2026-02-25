# 沙箱（ExecHub/Runner）能力需求（Product 侧，Draft）

本文档不定义“沙箱怎么实现”（容器 / microVM / 物理机等），只从产品层列出 **Cybros 需要沙箱提供什么能力**，用于与单独演进的执行子系统对齐。

> 约定：凡涉及执行与文件系统副作用，都假设发生在沙箱内的 workspace；产品层通过 permission gate 控制“何时允许”。

---

## 1) 必须支持的最小能力（Phase 1）

### 1.1 进程执行（Execute）

- 在指定 `workspace` 内运行命令（argv + cwd + env allowlist）。
- 支持超时、取消/kill、资源上限（至少：CPU 时间 / wall time / 内存 / 磁盘配额）。
- 返回结构化结果：`exit_code`、`stdout/stderr`（可截断）、`elapsed_ms`、`timed_out`、`killed`。
- 并发控制：per-user / per-space / instance 级并发上限（用于止损）。

### 1.2 文件系统（Read/Write）

- workspace 必须是“可被限制的边界”（路径穿越与 symlink escape 不能越界）。
- 支持最小挂载模型：
  - repo/workspace 挂载（读写）
  - 只读工具链/依赖挂载（可选）
  - 明确区分 “workspace 内读写” 与 “宿主读写”（后者视为危险能力，默认不授予）
- 提供基础文件操作（读/写/列目录/删除/创建目录），并能在审计中记录路径摘要（不落内容）。

### 1.3 网络（Read internet 与危险网络）

- 必须支持把网络能力分层：
  - **Safe Retrieval（Read internet）**：满足 `docs/product/safe_retrieval.md` 的硬契约（HTTP(S)、无 caller 自定义 headers/body、SSRF/DNS rebind 防护、响应大小/类型上限、审计不落内容）。
  - **Unrestricted/Private network**：属于危险能力（私网访问、任意端口/协议、宿主网络直出等），必须可被 policy 显式授予，并走审批与审计。

### 1.4 Secrets 与环境变量

- secrets 注入必须是显式、可审计、可撤销的（默认不注入）。
- 支持最小注入形态：
  - 按 task 注入（一次性）
  - 按 conversation 注入（需额外审批；可选）
- secrets 值不得出现在 runner 日志/事件/LLM prompt 中（执行侧必须提供 redaction/屏蔽策略的落点）。

### 1.5 审计与可观测性（不落内容）

- 每次执行/网络访问必须能附带关联字段：`user_id` / `space_id` / `conversation_id` / `turn_id` / `task_id`。
- 需要可聚合的稳定错误码（用于 UI 与统计），且 details 必须 safe（不回显 secrets/敏感参数）。

### 1.6 环境承诺（最小保证）

产品层建议口径：

- 沙箱只保证“可执行 + 可读写 + 可审计”的最小能力；不隐式承诺语言工具链齐全（Node/Python/Ruby/…）。
- 需要额外工具链时，应当通过 sandbox image/profile 或 skills/插件显式提供（可复现、可诊断）。

更完整的产品语义见：`docs/product/programmable_agents.md`。

---

## 2) 推荐能力（止损与体验）

### 2.1 Workspace 生命周期

- workspace 可重建（坏了能“一键重置”）。
- （可选）支持快照/还原：用于提升 “Execute 不可回滚” 的恢复效率（见 `docs/product/security_concerns.md`）。

### 2.2 产物与日志

- 支持产物上传/下载（文件列表 + size caps），用于让用户拿到输出（如补丁、报告、构建产物）。
- stdout/stderr 需要截断策略与最大字节数（防止日志爆炸）。

### 2.3 依赖缓存与污染隔离

- 允许可控缓存（镜像层/包缓存）以提升速度，但必须提供隔离策略避免跨用户污染（工程实现由执行子系统决定）。

### 2.4 长任务会话（建议）

coding/automation 任务经常需要 dev server、watcher、数据库连接等长进程；仅靠“拉长 timeout”会导致可取消性与诊断体验很差。

建议沙箱提供会话能力（或等价抽象）：

- `start`：启动长任务并返回 `session_id`（或 `process_id`），同时返回首段输出与状态。
- `poll/stream`：可增量获取 stdout/stderr（截断 + bytes cap），并返回退出码/运行状态。
- `send`：向运行中的进程发送 stdin（可选；例如 REPL/ssh/db cli）。
- `list/kill`：列出/终止会话（受 scope 与权限约束）。

审计要求（产品层）：

- 会话的创建/终止必须可审计（不落内容）；输出仍遵守截断策略。

---

## 3) 与产品层规范的对齐点（必须一致）

- Permission gate 默认策略见：`docs/product/behavior_spec.md`（Read 默认放行；默认 Cowork 下对标准沙箱动作的 Execute/Write 默认自动；能力升级仍需 ask；Agent repo 写入不单独区分为 GitOps 审批域）。
- “Read internet” 的唯一实现口径见：`docs/product/safe_retrieval.md`（不能退化成任意网络请求工具）。
- 风险登记见：`docs/product/security_concerns.md`（Execute 不可回滚、repo 安全、prompt cache 等）。
