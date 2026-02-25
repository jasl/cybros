# 参考项目调研：Bub（references/bub）

更新时间：2026-02-24  
调研对象：`references/bub`  
参考版本：`216998e`（2026-02-24）

## 1) 项目定位与核心形态

Bub 是一个 coding agent CLI，主打“可预测、可审计、可恢复”的工程化工作流。它把很多“agent 不可靠”的问题归因于两件事：

- 命令/工具边界不清晰（误触发、不可复现）
- 上下文不可控（越聊越大、难以恢复）

因此 Bub 的设计围绕：

1. **严格命令边界**：只有行首 `,` 才被当作命令
2. **append-only tape**：会话写入 JSONL tape（可回放/可搜索）
3. **anchor/handoff**：显式阶段切换与总结（缩短活跃上下文）
4. **工具/技能的渐进式提示**：系统 prompt 先给 compact view，必要时展开细节

## 2) Agent Loop：同一套路由同时作用于用户输入与 assistant 输出

核心拓扑（见 `docs/architecture.md`）：

```
input -> InputRouter -> AgentLoop -> ModelRunner -> InputRouter(assistant output) -> ...
```

关键点：

- 用户输入：若是 `,cmd` 且执行成功，直接返回；失败则封装成结构化 `<command ...>` block 送回模型继续推理
- 模型输出：同样要走 `route_assistant`（同样的命令解析/执行规则）
- 循环停止：plain text final、显式 quit、或 max_steps

对 Cybros 的映射：

- Bub 的“tape + router + bounded model loop”本质上是 DAG 的一个线性特例；
- Cybros 的 DAG 更强（能并行、能分支、能压缩、能审批），但 Bub 的“显式边界”值得借鉴到工具 policy 与 UX 上。

## 3) Prompts：runtime_contract + 渐进式 tool view + skills

`src/bub/core/model_runner.py` 的 `_render_system_prompt` 组装了：

- base system prompt（可配置）
- workspace system prompt（读取工作区 `AGENTS.md`）
- `runtime_contract`：
  - 强制用 tool calls 做动作
  - 不要自己输出 `<command>` blocks（runtime 生成）
  - 建议用 `tape.handoff` 缩短上下文
- `<tool_view>`：工具列表的 compact rows
- `<tool_details>`：当 `$name` hint 匹配时，展开对应工具详情（渐进式）
- skills：同样支持 `$skill_name` hint 触发加载技能正文

这是一种非常实用的“上下文成本控制”技巧：把工具与技能的细节当作“按需加载资源”，而不是每轮都塞满 prompt。

同时，Bub 也把“技能作者指南”做成内置 skill（`skills/skill-creator/SKILL.md`），明确提出：

- SKILL.md 只保留必要的可执行流程，**避免把长参考资料塞进正文**（把大内容放到 `references/` 等辅助文件）
- 建议把 SKILL.md 控制在 **500 行以内**，并写清楚“触发条件/输入/步骤/验证/效率计划”（本质上也是在治理 prompt 膨胀）

对 Cybros 的启发：

- 我们现在会把 tools schema 直接传给 provider（tool calling），其成本往往被忽略；
- 若工具很多、schema 很重（尤其 MCP 工具），应考虑：
  - profile 化：只暴露一小撮必要工具
  - 或提供一个“工具发现/描述”的 meta-tool，让 LLM 先看 compact view，再决定要不要加载详情

## 4) Context/Memory：append-only tape + search + handoff

Bub 的“会话记忆”几乎完全依赖 tape：

- tape 是 workspace-level JSONL（可检索：`,tape.search`）
- `,handoff` 写 anchor（可带 summary/next_steps），并可作为阶段边界
- `tape.reset` 清活跃上下文（可先 archive）

对 Cybros：

- DAG 本身就是“可审计事件流 + 可回放 transcript”，并支持 summary compression；
- Bub 的 anchor/handoff 可以映射为：
  - DAG 的 `summary` 节点（或一个“handoff” node_type），并把它作为下游上下文的起点

## 5) 渠道与调度

Bub 支持 Telegram/Discord 适配，且明确“每 chat session 隔离”（`telegram:<chat_id>`、`discord:<channel_id>`）。它的调度系统相对轻量，不像 OpenClaw/Memoh 那样是平台级。

对 Cybros：

- 频道适配属于 app 层；DAG 的 `lane/transcript` 可作为 session 隔离载体

## 6) 在 Cybros 上实现的可行性评估

### 能做到（现有底座覆盖）

- tape/append-only：DAG nodes/events 天然提供
- anchor/handoff：DAG summary/压缩机制天然提供
- tool loop/失败回退：AgentCore tool loop 已提供

### 建议补的能力（借鉴 Bub 的“可控上下文”）

P0：

- **Tool policy profile**：减少默认暴露的工具集合
- **Context pruning**：对旧 tool results 做裁剪（Bub 用 handoff 缩短；我们可同时支持 pruning）

P1：

- **渐进式工具视图**（可选）：当工具数量与 schema 过大时，提供“compact tool view + tool.describe”策略

## 7) 借鉴要点总结

- “严格边界”能显著降低 agent 误操作：把危险行为变成显式命令/显式审批
- “渐进式工具提示”是控制上下文成本的有效工程手段
- “handoff = 可回放的阶段总结”与 DAG summary 非常契合
- “同一套路由同时作用于用户输入与 assistant 输出”是典型 harness workaround：用确定性的解析/执行层兜住模型的指令跟随不稳定性
