# Automations（定时/事件触发运行，Draft）

动机：Pro 用户会希望 Cybros 能“自己跑起来”，例如：

- 每天定时跑一次 repo 健康检查（`bundle audit` / `brakeman` / `bin/rails test`）并把摘要推到 Telegram。
- 每小时拉一次某个页面/接口的变化（只读）并把差异发到 IM。
- 每天生成一份个人工作日志/周报草稿（从 memory/facts/KB 查询，不直接改业务系统）。

这类能力的核心不是“模型更聪明”，而是：

- **可预期**（何时触发、触发了什么、跑了多久、花了多少 tokens）
- **可止损**（并发/重试/超时/失败通知）
- **可审计**（每次 run 都可追踪到 agent/workflow/prompt program 的版本与权限边界）
- **不偷偷扩权**（automation 不是一个绕过 Plan gate / permission gate 的后门）

本文件定义产品层对 Automation 的最小语义与安全默认值；不定义具体实现细节（scheduler/worker 见执行层）。

---

## 1) 定义：Automation 是什么

Automation = 一个可版本化的“触发器 + 运行模板”资源，描述：

- **触发条件**：按时间（schedule）或按事件（event）。
- **运行入口**：选用哪个 `agent_profile` / `workflow`（默认 Cowork）。
- **运行约束**：可用工具子集、budgets、并发策略、最大运行时长。
- **投递策略**：把结果投递到哪里（WebUI inbox / Telegram DM / email 等）。
- **失败策略**：失败是否重试、是否升级为告警、是否降级到救援路径。

规范性倾向：

- Automation 是“用户显式创建并启用”的能力；**默认关闭**（无隐式定时任务）。
- Automation 本质上等价于“预授权的 Cowork run”，因此必须有明确的 policy 与审计记录。

---

## 2) 运行模型：Run / Attempt / Artifact（建议）

建议把每次触发的执行抽象为：

- `AutomationRun`：一次触发的“逻辑 run”（有 `run_id`）。
- `Attempt`：run 的一次尝试（重试会产生新 attempt）。
- `Artifacts`：run 的产物（摘要、diff、链接、附件、日志截断、诊断包引用等）。

Run 的落点（与 DAG 的关系）建议两种模式二选一（Phase 1 选其一即可）：

1) **New conversation per run（推荐，简单且可控）**
   - 每个 run 创建一个新的 Conversation（带 `automation_id` 标签）。
   - 好处：上下文不会无限增长；每个 run 易于归档与比较。
2) **Single conversation, many runs（后续增强）**
   - 一个 Automation 固定绑定一个 Conversation；每次 run 往同一 DAG 追加一个 turn。
   - 好处：连续上下文强；坏处：更容易 context 膨胀与“历史包袱”影响行为。

无论哪种模式，都必须记录：

- `agent_id` + `agent_version`（优先 git commit SHA；否则 `config_version`；system 内置用 `system_version`）
- `workflow_id` + `workflow_version`（同上）
- `prompt_builder_kind/version`（见 `docs/product/observability.md`）
- `enabled_tools` + `budgets` + sandbox policy snapshot

---

## 3) 权限与安全：Automation 不是绕过 gate 的捷径

### 3.1 与 Plan gate 的关系（建议）

- 普通 Cowork：副作用 turn 需要一次性 “Start Cowork run”（见 `docs/product/behavior_spec.md` 6.1.1）。
- Automation：没有在线用户点击，因此 Plan gate 不能按原语义成立。

建议的产品语义：

- **创建/启用 Automation 本身就是一次“长期授权”**，但授权范围必须被严格限定为：
  - 指定的 agent/workflow
  - 指定的工具子集（enabled_tools）
  - 指定的 budgets/超时/并发策略
  - 指定的 sandbox policy（NET/FS/secrets）
- 每次 run 仍然应生成 plan（用于可观测与 debug），但 plan 不需要用户确认。
- 当 run 需要的动作超出授权范围时：
  - **fail-fast**（默认）：立即结束 run，并把“缺少授权”的原因与 remediation 发给用户。

### 3.2 Permission requests 的处理（规范性要求）

Automation run 内不应出现“等待审批”的悬挂状态（用户可能不在线）：

- 若触发了 permission request：
  - 若该动作在 automation 的预授权范围内：自动通过（并落审计）。
  - 否则：拒绝并 fail-fast，产出错误码 `automation_permission_denied`（示例）。

备注：Automation 的预授权范围必须可视化（UI），并支持一键停用。

---

## 4) 触发器类型（Phase 1 建议最小集）

### 4.1 Time-based schedule（优先）

Phase 1 建议只支持可预测的 schedule：

- 每 N 小时（hourly interval）
- 每周某几天某时刻（weekly）

避免 Phase 1 就引入全量 cron 语义（可控性/可解释性差，且实现复杂）。

### 4.2 Event-based trigger（后续）

可能的事件源：

- Webhook（GitHub push / issue / PR）
- 内部事件（agent repo 变更、KB index 完成、tool failure spike）
- IM 消息（特定命令触发一个 automation run）

事件触发必须有严格的 allowlist 与 payload redaction（避免把不可信 payload 直接注入 prompt）。

---

## 5) 并发、重试、幂等（建议）

并发（规范性倾向）：

- 同一 `automation_id` 默认 **不并发**：
  - 若上一次 run 未结束，新触发默认 `skip`（可配置为 `queue` 或 `cancel_previous`）。
- 全局并发设硬上限（防止 DoS 自己）。

重试（建议）：

- 仅对可分类的“临时错误”重试（例如网络抖动、provider 5xx、runner 超时）。
- 重试次数与 backoff 必须有上限；默认 `0`（不重试）。

幂等（建议）：

- 对副作用任务强烈建议设计为幂等（例如写文件用内容哈希、repo 写入检测 no-op）。
- 对“写外部系统”的 tool 必须在 tool 层提供幂等 key（若支持），并在 run 里记录。

---

## 6) 投递与通知（建议）

投递目标（最小集）：

- WebUI inbox（必选，作为“有记录可追踪”的落点）
- Telegram DM（可选，依赖 `docs/product/channel_pairing.md`）

通知策略（建议默认）：

- `on_failure`（只在失败/异常时推送 IM）
- `on_change`（只有结果变化时推送）
- `always`（每次 run 推送）

对 IM：沿用 `ACK / Progress / Final`（见 `docs/product/channels.md`），但要严格限频。

---

## 7) Open questions

- Phase 1 选 “new conversation per run” 还是 “single conversation many runs”？
- Automation 的最小 UI 形态：列表 + 启停 + 最近 runs + 一键查看 artifacts，是否足够？
- 事件触发（webhook）是否应该在 Phase 1 就做最小形态（仅 GitHub push）？
