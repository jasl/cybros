# Channels / Bots（多渠道输入输出，Draft）

动机：当 Cybros 不仅有 WebUI，还要接入 Telegram/Discord 等 IM 渠道时，产品语义会立刻变复杂：

- IM 渠道天然是异步的：长任务如果不先 ACK，用户会以为 bot 掉线。
- 同一条输入可能需要多段输出：`ack` → `progress` → `final`。
- 渠道有自己的约束：消息长度、markdown 语法、编辑/撤回能力、速率限制。
- Pro 用户常见定制需求：**bot 的回复口吻与文案**、以及“收到消息后立刻回复收到，再继续运行”的工作流。

本文档定义产品层的渠道语义与建议落点（不定义具体接入实现）。

---

## 1) 定义：Channel 是什么

Channel = 一个外部输入/输出表面（surface），例如：

- WebUI（同步交互 + 本地状态丰富）
- Telegram bot（异步消息 + 限制多）
- Discord（频道/线程语义）

规范性倾向：

- Channel 不改变权限边界：permission gate 与 sandbox policy 一致（见 `docs/product/behavior_spec.md`）。
- Channel 决定 **消息投递语义** 与 **呈现约束**，并且这些约束必须对 workflow 可见（避免“在 WebUI 正常但在 Telegram 崩坏”）。

---

## 2) 关键语义：ACK / Progress / Final

对异步渠道（IM）建议默认采用三段式：

1) **ACK（立即回执）**
   - 目标：让用户知道“收到并开始处理”，并提供 stop/cancel 的提示（若支持）。
2) **Progress（可选）**
   - 目标：长任务在关键阶段更新（例如：已开始运行测试、已生成补丁、正在下载依赖）。
   - 约束：必须限频，避免刷屏与触发渠道风控。
3) **Final（最终结果）**
   - 目标：给出可操作的结果（链接/补丁/工件/摘要），必要时拆分多条。

对 WebUI：

- ACK 可以被 UI 状态（typing / running badge / stream）替代，但仍建议在后台任务触发时产生日志节点（可观测）。

---

## 3) 可配置资源：ChannelProfile（建议）

为满足“定制 Telegram bot 回复内容”的需求，建议把渠道呈现相关配置做成可版本化资源：

- `ChannelProfile`（scope=user；Phase 2+ 可选扩展到 `scope=space`）：
  - `ack_template`（默认文案）
  - `progress_template`
  - `final_template`
  - `format`（plain/markdown/telegram_markdown_v2/…）
  - `max_message_chars`（渠道限制）
  - `rate_limit`（progress 限频）

模板应当是“弱表达式”的（例如 Mustache/Handlebars），避免任意代码：

- 支持少量变量：`{{conversation_id}}`、`{{turn_id}}`、`{{task_title}}`、`{{eta}}`、`{{cancel_hint}}`
- 禁止执行逻辑/网络请求（保持可预测）

版本化与写入：

- 存放在 Agent repo（见 `docs/product/versioning_and_sync.md`）
- 修改必须经过 schema validation
- Agent 触发写入属于正常 workspace 写入：是否需要审批/是否自动放行取决于沙箱策略与当前模式（Manual/Cowork/Evolution；见 `docs/product/behavior_spec.md`）

---

## 4) 工作流落点：ACK 是 workflow 的阶段，而不是 prompt trick

“收到消息后立刻回复收到，再继续运行”建议落点：

- Channel adapter 收到 inbound message 后：
  1) 立即创建 turn（user_message node）
  2) 立即发送 ACK（基于 ChannelProfile + workflow 配置）
  3) 把后续执行放到后台 worker（Cowork 默认无人值守执行）
  4) 执行过程中按需发送 progress
  5) 完成后发送 final

规范性要求：

- ACK/Progress/Final 必须与 DAG/Events 关联（可审计、可回放、可重试）。
- ACK 不能被模型“假装发送”：必须由系统发送并返回外部 message id。

### 4.1 Plan gate 与审批（IM 渠道，建议）

在 Telegram 这类 IM 渠道里，Cowork 的 Plan gate 与 permission requests 仍然必须成立（见 `docs/product/behavior_spec.md` 6.1）。但渠道缺少“系统弹窗”，因此需要把审批交互建模为**系统消息 + 可验证的用户操作**：

- Plan gate：系统发送 plan 摘要 + 一个明确的 `Start Cowork run` 按钮（或命令），用户确认后才进入后台执行。
- Permission requests（写入/执行/能力升级等）：系统发送审批卡片（文本摘要 + 按钮），按钮回调必须携带一次性 token 并绑定 conversation/turn（防止跨会话/重放）。
- 按钮能力不足时，允许退化为命令式确认（例如 `/approve <token>`），但仍必须做到：
  - token 高熵、短期有效、一次性
  - scope 绑定（conversation_id/turn_id/kind）
  - 操作人校验（Telegram user id ↔ Cybros identity；见 `docs/product/channel_pairing.md`）
-（可选增强）审批卡片可提供“写入 permission rule”的动作（减少重复审批）：
  - `Allow once`（仅本次）
  - `Always allow this <command/path/domain> in this conversation`（conversation-level wildcard rules）
  - `Promote to Space policy`（写入 space-level policy rules；需额外权限与审计）

约束（安全默认值）：

- IM 渠道不应允许“隐式 auto-allow”；任何 `Auto-allow ... in this conversation` 都必须是用户显式点击/输入产生，并且要有清晰提示与一键关闭。

---

## 5) Rescue / SOS：IM 渠道的“救援艇”入口（建议）

边界情况：用户自定义 agent/workflow/prompt program 可能“接口仍然合法”，但行为已经跑偏（输出很怪、工具选择异常、风格失控）。在 IM 渠道中这类问题尤其难排查，因为 UI 能力弱、回滚入口不明显。

因此建议为所有 IM 渠道提供一个“永远可用”的救援入口：**Rescue command**（例如 `/sos`）。

规范性倾向：

- Rescue command 必须由系统在 channel adapter 层拦截（不进入 LLM prompt，不走 persona router）。
- 推荐采用 Telegram 风格的“显式命令 + 参数”，而不是单个关键词（更少误触发、也更适合脚本化）：
  - `/sos`：显示可用的救援动作与当前状态摘要
  - `/sos status`：输出当前 conversation 的 agent/workflow/prompt builder 版本（git commit SHA 或 `config_version`）与最近一次变更
  - `/sos switch builtin`：切换到系统内置 agent 接管后续对话（不改用户 repo）
  - `/sos disable prompt_program`：对当前 conversation 禁用 prompt program（回到 DSL）
  - `/sos revert`：回滚最近一次 Agent repo 变更（git 若可用；默认建议只回滚“最近一次”，避免一次命令回滚太多）
  - `/sos stop`：终止当前 conversation 的后台执行/长任务会话（如果存在）
- 触发后由系统进入一个 **Rescue handler**（system-bundled，稳定、不可被用户修改），并向用户输出一组“可恢复动作”（按钮/指令）：
  - `Switch to built-in agent`：下一 turn 改用系统内置 agent 接管（不等同于修改用户配置文件）。
  - `Disable prompt program`：对当前 conversation/agent 禁用 prompt program（回到 DSL）。
  - `Rollback last change` / `Rollback to last known good`：回滚用户定义 agent/workflow/prompt program 的上一个可用版本（git 若可用；需要用户显式触发与角色校验；`/sos revert` 可视为一次手动授权）。
  - `Stop running tasks`：终止当前 conversation 的后台执行/长任务会话（如果存在）。
  - `Open WebUI`：返回一个链接，让用户在 WebUI 完成更复杂的 diff/回滚/切换。
- Rescue handler **不能绕过**权限与 scope：只能对“当前用户有权操作”的资源生效；所有动作建议落审计事件（不落敏感内容）。
- `/sos revert` 属于“用户显式请求回滚”，可以被视为一次手动授权（不需要再弹二次确认）：
  - 但建议对高风险动作仍提供可选二次确认（例如 inline keyboard 确认按钮），并支持 dry-run（先发 diff 摘要再确认）。

对 WebUI（建议一致性）：

- 在 conversation header 提供一个常驻 `Rescue` 按钮，执行同一套 Rescue handler（不依赖当前 agent 的 prompt builder）。

实现提示（Telegram-first）：

- 参考 SDK：`references/telegram-bot-ruby`（仅作实现参考；产品语义仍以本文件为准）。
- Telegram v1 建议只支持私聊（DM），不支持群聊/频道（避免“谁有权 /sos revert”变复杂）。
- Progress 可优先用 “编辑同一条消息” 实现（editMessageText），减少刷屏。
- Inline keyboard 适合承载“确认回滚/切换/停止”的按钮，降低误操作。

---

## 6) Open questions

- Telegram/Discord 是否支持“编辑同一条消息”来做 progress（减少刷屏）？若支持，是否作为默认？
- ChannelProfile 的模板变量集合需要包含哪些字段才够用？（任务名、文件链接、工件链接、错误码…）
- 多渠道同时绑定同一 Conversation 时，默认回传到哪个渠道？（last-interacted channel vs 固定 channel vs per workflow）
