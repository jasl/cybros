# 参考项目调研：OpenClaw（references/openclaw）

更新时间：2026-02-24  
调研对象：`references/openclaw`  
参考版本：`9ef0fc2ff`（2026-02-24）

## 1) 项目定位与核心形态

OpenClaw 是一个“always-on 个人 AI 助手”产品形态，特点是：

- 多渠道输入输出（WhatsApp/Telegram/Slack/Discord/iMessage/…）
- 一个本地 Gateway（WebSocket control plane）统筹：会话、工具、事件、自动化
- 工具丰富：浏览器控制、Canvas/A2UI、节点（相机/录屏/通知/位置）、cron、webhooks、skills 平台
- 强调安全默认（DM pairing、owner-only tools、tool allow/deny、session pruning、prompt 注入可控）

它不是纯 SDK，而是一整套“运行在你设备上的个人助手平台”。

对 Cybros 来说：OpenClaw 在 **Prompts/上下文/记忆** 上的工程化非常值得借鉴；而多渠道/节点/浏览器/语音属于运行时与产品层投入。

## 2) System Prompt：章节化、可测试、支持 promptMode

OpenClaw 明确说明 system prompt 是 OpenClaw 自己组装的（不是复用某个通用 coding prompt），并在 docs 中描述结构（见 `docs/concepts/system-prompt.md`）：

- 固定章节：Tooling / Safety / Skills / Workspace / Docs / Sandbox / Date&Time / Reply tags / Heartbeats / Runtime / Reasoning…
- **promptMode**：`full`（主 agent）/ `minimal`（子 agent）/ `none`（只保留 identity line）
- **bootstrap files 注入**：`AGENTS.md`、`SOUL.md`、`TOOLS.md`、`IDENTITY.md`、`USER.md`、`HEARTBEAT.md`、`BOOTSTRAP.md`、`MEMORY.md`/`memory.md`
  - 每文件与总量都有限制（max chars）
  - 子 agent 只注入 `AGENTS.md`/`TOOLS.md`（减少上下文）

实现上其 system prompt builder 是纯函数式组装（`src/agents/system-prompt.ts`），并且对 prompt 稳定性有测试（`src/agents/system-prompt-stability.test.ts` 等）。

对 Cybros 的映射与差距：

- Cybros 已有 prompt injections（FileSet/RepoDocs）与 `runtime.prompt_mode`，可以直接表达 promptMode 与 bootstrap files 注入
- 缺口主要在：
  - “章节化 system prompt builder”作为一等组件（现在更多靠注入碎片）
  - bootstrap 注入的预算/可观测（OpenClaw 提供 `/context list` 这类诊断）
  - prompt 稳定性测试（把 prompt 当作契约）

## 3) Context 管理：Compaction + Pruning（分工非常清晰）

OpenClaw 把上下文治理分成两件事：

1. **Compaction（持久化总结）**
   - 超预算时将旧对话总结成 compact entry，并写入 session JSONL（`docs/concepts/compaction.md`）
   - 支持 `/compact` 手动触发
2. **Session pruning（瞬时裁剪 tool results）**
   - 只在“本次调用”前裁剪旧 tool results，不改磁盘历史（`docs/concepts/session-pruning.md`）
   - 重点服务 Anthropic prompt caching：TTL 过期后降低 cacheWrite 成本
   - 支持 soft-trim（保留 head+tail）与 hard-clear（placeholder）

对 Cybros 的映射：

- Compaction：Cybros 已有 auto_compact summary node（持久化在 DAG），语义上更“图内原生”
- Pruning：Cybros 目前只有 tool result bytesize 截断（约 200KB），缺少“按会话策略裁剪旧 tool results”（建议 P0 补到 PromptAssembly/ContextBudgetManager）

## 4) Memory：Markdown 是 source of truth + vector 搜索 + pre-compaction flush

OpenClaw 的 memory 设计非常完整（见 `docs/concepts/memory.md`）：

- **文件布局**
  - `MEMORY.md`：长期 curated memory（只在主私聊 session 注入，不进群聊）
  - `memory/YYYY-MM-DD.md`：每日日志（append-only）
- **memory tools**
  - `memory_search`：语义检索（返回 snippet + path + 行号；可选 citations）
  - `memory_get`：按路径/行范围安全读取（避免把大文件塞进上下文）
- **自动 memory flush**
  - 接近 compaction 时触发一个 silent turn，提醒把“耐久信息”写入 memory（避免被总结丢失）
- **向量检索实现**
  - 默认内置 SQLite 索引 + embeddings
  - 可切换 QMD backend（BM25+vector+rerank sidecar），并有健壮 fallback
  - 支持 scope（DM-only/deny groups）与 citations 开关（auto/on/off）

对 Cybros 的启发与建议：

- 我们已有 pgvector memory_store，但目前是“自动把 relevant_context 注入 prompt”，不是“工具化检索”
- 建议补齐：
  1) `memory_search`/`memory_store`（必要）+ `memory_get`（可选）作为 AgentCore 内建工具
  2) 支持 citations 与 scope（direct/group/channel）
  3) pre-compaction memory flush（价值很高、覆盖多形态）
- OpenClaw 的“文件为真相”模型也可作为一种可选 memory backend（对某些产品更容易解释与审计）

## 5) Tools/Policy：tool groups、owner-only、profile

### 5.1 “基本工具”到底有哪些（按代码实际注入）

OpenClaw 的工具面不是“只有四工具”，而是：

- 以 Pi 的 coding harness 为基座（`read/write/edit/bash` 的思想）；
- 在 OpenClaw 里把 `bash` 替换/拆成 `exec` + `process`（长任务会话/后台/kill/日志分页）；
- 再叠加一套 OpenClaw 平台工具（channels、browser、sessions、cron…）；
- 最后再通过 tool policy/profile 把工具面裁剪到“可控的子集”。

从 `createOpenClawCodingTools()` 与 `createOpenClawTools()` 看，常见的“基础工具集合”至少包含：

- **文件/改动**：`read`、`write`、`edit`、`apply_patch`
- **执行/长任务**：`exec`、`process`
- **Web**：`web_search`、`web_fetch`
- **记忆（可选，但 OpenClaw 默认内置）**：`memory_search`、`memory_get`
- **渠道/会话/编排（OpenClaw 平台层）**：`message`、`sessions_list`、`sessions_history`、`sessions_send`、`sessions_spawn`、`subagents`、`session_status`、`cron`
- **交互与多模态（平台层）**：`browser`、`canvas`、`image`、`tts`、`nodes`、`gateway`、`agents_list`
- **插件工具**：按 allowlist 注入（plugin tools）

> 对 Cybros 的一个很重要启发：**工具面强大不等于“暴露很多工具给模型”**。OpenClaw 通过 profile/policy 把“平台能力”裁剪成按场景可控的工具子集。

OpenClaw 的 tool policy 在代码中非常清晰（`src/agents/tool-policy.ts`）：

- tool name normalization + aliases（bash→exec 等）
- tool groups（group:fs/memory/web/sessions/…）
- profiles（minimal/coding/messaging/full）
- owner-only tools：非 owner 直接移除/或包一层执行时拒绝

对 Cybros：

- 我们需要一个更丰富的 policy 实现（pattern rules + groups + profiles + owner-only）
- 这类 policy 适合作为 AgentCore 内建 policy（但规则/存储在 app 层可配置）

## 6) 调度与自动化（cron/webhooks）

OpenClaw 本身带 cron、wakeups、webhooks 等自动化能力（见 README 与 docs），并能把结果回传到指定渠道。

对 Cybros：

- DAG/AgentCore 本身是执行底座，但“周期触发”需要 app 层：
  - 自动创建 `user_message`/`task` 节点
  - 幂等（避免重复触发）
  - 并发约束（同 conversation/同 lane 不要重入）
  - 回传消息（channel routing）

## 7) 在 Cybros 上实现的可行性评估

### Prompts/Context/Memory（强借鉴价值，且可做成平台能力）

- ✅ promptMode + bootstrap injection：我们已有 prompt injections 的基础，补“章节化 builder”即可
- ✅ compaction：我们已有（DAG summary）
- 🟡 session pruning：需要补（P0）
- 🟡 memory tools + flush：需要补（P0）

### Channels/Nodes/Browser（属于产品/运行时形态）

- 🔴 多渠道接入（Telegram/WhatsApp/…）：需要渠道适配层与 message routing
- 🔴 nodes/canvas/voice：需要 OS/设备 runtime
- 🟡 浏览器控制：可以通过 Playwright MCP/自建 service 做（但仍是运行时）

## 8) Skills / MCP / tool calling：如何避免 prompt 膨胀与选择困难

OpenClaw 在“工具与技能容易膨胀”这个问题上，给了两条非常直接的工程解法：

1) **Skills 只注入清单，不注入正文（按需 read）**

- system prompt 的 Skills 段只包含 `<available_skills>` 列表（name/description/path），并明确要求模型用 `read` 按需加载对应 `SKILL.md`（见 `docs/concepts/system-prompt.md` 的 Skills 段）。
- 这样可以把“技能库规模”与“基础 prompt 体积”解耦：技能越多，默认上下文不会线性变大。

2) **把“上下文成本账”做成可用命令**

- `docs/concepts/context.md` 提供 `/context list` 与 `/context detail`：能按“注入文件 / 工具 schema / skills 列表 / system prompt 本体”拆解体积（并指出最大贡献项）。
- 这类可观测性非常关键：当工具或 Skills 扩张导致模型选择困难时，能够快速定位“到底是谁占了 budget”。

对 Cybros 的建议（可直接落地）：

- 把 `skills` 的 prompt 约束为“只注入元信息 + 位置”，正文始终通过 `read`/`skills.get` 按需加载（避免 enabled skills 全量注入）。
- 给 PromptAssembly 增加一个“context cost report”（类似 `/context detail`），至少能按：system prompt、injected files、tool schemas、tool results、skills list 做 breakdown，方便调参。

## 9) 模型 workaround：把“不稳定”当作第一等工程约束

OpenClaw 的可借鉴点不在“某个神奇提示词”，而在“承认模型/Provider 会不稳定，并把 fallback/修复路径做进运行时”：

- **Auth profile rotation + model fallback**：先在同 provider 内轮换 auth profile，再按配置切换到 fallback models（见 `docs/concepts/model-failover.md`）。其中把“invalid-request/格式错误（含 tool call id 校验失败）”也视为可 failover 的错误类型，有助于在 tool calling 不稳定时自动自愈。
- **strict schema + typed tooling**：OpenClaw 使用 TypeBox/typed schema 体系来约束 tool inputs（避免“模型胡填字段”导致工具失败），并通过 tool policy/profile 降低模型决策复杂度。

对 Cybros 的建议：

- 把“tool calling 不稳定”的常见失败形态（缺 call_id、tool args 非 JSON、tool 输出过大导致 400、orphan tool message）沉淀为 **Runner 级 retry/repair/fallback 策略**（详见后续跨项目总结）。
- 在 provider adapter 层支持“可配置 fallback model 列表”，并把“因工具协议失败而切换模型”的事件写入可观测（node metadata + spans）。

## 10) 对 Cybros 的具体建议（最小增量覆盖最大收益）

1. 把 OpenClaw 的 3 个能力沉淀为“平台能力包”（P0）：
   - tool policy profiles（groups + owner-only + allow/deny/confirm）
   - memory tools + citations + pre-compaction flush
   - session pruning（工具结果软/硬裁剪）
2. 自动化/渠道放到 app 层实现（P1），不要塞进 AgentCore
3. 如果要做“OpenClaw-like 产品实验”，优先做 Web UI + Telegram（最小渠道），再扩展到其他渠道与 nodes
