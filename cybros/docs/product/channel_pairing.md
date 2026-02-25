# Channel pairing（外部渠道账号绑定，Draft）

动机：当 Cybros 接入 Telegram/Discord 这类 IM 渠道时，“谁发的消息”与“谁点击了审批/回滚按钮”必须可验证，否则：

- permission gate 在 IM 渠道会失效（按钮/命令可能被他人伪造或转发）。
- `/sos revert` 这类救援动作会变成高危后门。
- 多用户/多设备情况下，无法正确路由消息与通知。

本文件定义 **Channel pairing** 的最小产品语义：把外部渠道身份（例如 Telegram user id）绑定到 Cybros 的 Identity/User，并用于授权、路由与审计。

---

## 1) 定义：Pairing 是什么

Pairing = 一条“外部账号 ↔ Cybros 身份”的绑定记录（建议最小字段）：

- `channel`：`telegram` / `discord` / ...
- `external_user_id`：例如 Telegram `from.id`
- `identity_id`（或 `user_id`，取决于你的身份模型）
- `created_at` / `revoked_at`
- `scopes`（可选）：允许哪些能力（例如仅收通知 vs 允许审批）
- `default_space_id`（可选）：用于路由

规范性要求：

- Pairing 可撤销、可轮换、可审计（Event）。
- Pairing 不等于“登录凭证”：它只用于该 channel 的消息/按钮/命令鉴权。

---

## 2) Telegram v1：DM-only（建议）

Phase 1 建议只支持 Telegram 私聊（DM）：

- 群聊/频道里“谁有权 approve/revert”会复杂很多（管理员/多成员/转发）。
- DM-only 可把风险压到最低，并且满足大部分 Pro 用户“随手发个需求”的场景。

---

## 3) 配对流程（建议：WebUI 生成一次性 Pair Code）

推荐的最小流程：

1) 用户在 WebUI 打开 `Channels -> Telegram`，点击 `Generate pairing code`
2) 系统生成一个一次性 `pair_code`：
   - 高熵、短期有效（例如 10 分钟）
   - 仅可使用一次
   - 存储时只存 hash（避免泄露即绑定）
3) 用户在 Telegram DM bot 发送：`/pair <pair_code>`
4) bot 侧验证成功后创建 Pairing，并回复确认信息（包含绑定到的 identity/user）
5) WebUI 显示“已绑定”，并允许 `Revoke` / `Rotate`

失败与止损：

- code 过期/错误：不暴露任何内部信息（只提示重新生成）。
- 多次失败应 rate limit（防爆破）。

---

## 4) IM 命令与按钮的鉴权（规范性要求）

### 4.1 文本命令（例如 `/sos revert`）

规则：

- 任何需要权限的命令必须先通过 Pairing 找到 `identity/user`。
- 再按 Cybros 内部 ACL 校验该用户对目标资源/会话是否有权操作。
- 未配对用户只能得到“如何配对”的引导；不能触发任何读取敏感信息的动作。

### 4.2 Inline keyboard callbacks（审批按钮）

按钮回调（callback query）必须满足：

- 回调 payload 里携带一次性 token（高熵、短期有效、不可预测）。
- token 绑定：
  - `conversation_id` / `turn_id`
  - `action`（approve/reject/revert/...）
  - `external_user_id`（防止转发按钮被他人点击）
- token 必须可防重放（一次性使用；服务端记录 consumed）。

备注：Telegram 的 `callback_data` 长度有限；可以存一个短 token id，把完整 scope 存服务端。

---

## 5) 路由：从外部消息到 Space/Conversation

最小策略（建议）：

- DM 消息默认路由到用户的默认 Space（Phase 1 只有一个默认 Space 时更简单）。
- Conversation 绑定规则：
  - 若用户在 WebUI 为 Telegram 创建了“固定会话”入口，则 DM 进入该会话。
  - 否则每次新消息创建新 Conversation（或用最近活跃会话，需权衡）。

必须记录：

- inbound message id / chat id（用于回放与去重）
- 关联到的 conversation_id/turn_id（审计/排障）

---

## 6) 撤销与恢复（建议）

撤销（Revoke）后：

- bot 不再接受该外部账号的审批/命令（只返回“已解绑，请重新配对”）。
- 既有对话不删除（审计保留）。

恢复方式：

- 重新生成新的 pair_code 再 `/pair` 绑定。

---

## 7) Open questions

- Pairing 的绑定目标用 `identity_id` 还是 `user_id` 更合适？（多 space 情况）
- “只收通知、不允许审批”的只读 pairing 是否值得作为 Phase 1 能力？
- DM 消息默认用“新建会话”还是“复用最近会话”？（可预测 vs 方便）
