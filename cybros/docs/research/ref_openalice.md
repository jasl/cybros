# 参考项目调研：OpenAlice（references/OpenAlice）

更新时间：2026-02-24  
调研对象：`references/OpenAlice`  
参考版本：`8add790`（2026-02-24）

## 1) 项目定位与核心形态

OpenAlice 是一个 trade-specific agent（交易助手），但它最值得借鉴的不是交易域，而是它把“可编程 agent 平台”做成了极简、可解释、可恢复的工程形态：

- **File-driven**：Markdown 定义 persona/tasks；JSON 定义配置；JSONL 存会话与 event log
- **Event log**：append-only JSONL + real-time subscriptions + crash recovery
- **多接口**：Web UI / Telegram / HTTP / MCP
- **双 provider**：可在 Claude Code CLI 与 Vercel AI SDK 之间切换（读配置文件，运行时切换）

## 2) Evolution mode：两档权限（“显式自改”）

OpenAlice 明确把“自修改”做成两档模式：

- normal mode：把 agent 限制在特定目录（例如 `data/brain/`）
- evolution mode：放开到全项目（含 Bash），允许修改源代码与系统

对 Cybros 的启发：

- 自改不是“模型想改就改”，而是一个明确的 **信任升级**（trust ladder），并且必须有止损路径（回滚/禁用/重建）。
- 把“允许改哪里”建模为 workspace/mount/policy，而不是 prompt 约定。

## 3) Channels + Scheduling：多形态输出的一致性

OpenAlice 的 cron 与 connector registry（last-interacted channel）体现了一个关键产品点：

- 自动化任务需要“把结果回传到正确的地方”，否则就只剩后台日志
- 多渠道不是“加几个 webhook”，而是需要 session routing 与幂等

对 Cybros：

- DAG/Events 很适合做“可回放任务日志”，但 schedule/channel routing 属于 app 层能力，应当与执行/权限模型统一规划。

## 4) 对 Cybros 的可落地启发（本轮抽取）

- 文件/JSONL 作为 source of truth 有很强的可解释性；Cybros 的 git-backed resources + DAG 审计可以达到同等甚至更强的可回放性。
- Evolution mode 提醒我们：必须把“自改”产品化为显式模式，而不是靠默认 auto-allow 或 prompt 约束。

