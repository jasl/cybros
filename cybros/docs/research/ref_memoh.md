# 参考项目调研：Memoh（references/Memoh）

更新时间：2026-02-24  
调研对象：`references/Memoh`  
参考版本：`00ec692`（2026-02-24）

## 1) 项目定位与核心形态

Memoh 是一个“多 bot、可视化配置、容器隔离”的 agent 系统平台：

- 用户可以创建多个 bot，并通过 Telegram/Discord/Lark(飞书) 等渠道与其交互
- 每个 bot 运行在独立容器中（可执行命令/编辑文件/联网），平台侧提供 GUI 配置 Provider/Model/Memory/Channels/MCP/Skills
- 重点工程在 **Memory layer**：强调“结构化长记忆”（受 Mem0 启发），并支持语义检索注入上下文

对 Cybros：Memoh 的“产品形态”属于 L2/L3（多渠道 + 容器 + GUI），但其 **记忆系统工程** 非常值得借鉴为平台能力。

## 2) Prompts：system prompt 结构化 + 静态/动态分段

Memoh 的 agent 容器内（TypeScript）会生成 system prompt（`agent/src/prompts/system.ts`），特点：

- YAML front matter 作为 headers（language、channels、currentChannel、maxContextLoadTime、time-now）
- 明确把 prompt 分成：
  - **Static section**（稳定 prefix，利于缓存）
  - **Dynamic section**（时间/会话渠道等放末尾）
- 注入 `IDENTITY.md`/`SOUL.md`/`TOOLS.md` 内容（系统文件由平台提供）
- 技能列表与 enabled skills 内容直接插入 prompt（并提示 `use_skill`）
  - 约定附件协议（`<attachments>...</attachments>` block 会被解析并从可见文本中剥离）

补充观察（与“prompt 膨胀/选择困难”直接相关）：

- Memoh 的 skills 机制更偏“产品侧显式启用”：**enabled skills 会把 SKILL 正文直接拼进 system prompt**。这能提高命中率，但当技能数量/正文变大时，会快速挤占上下文并让模型在“太多规则”里选择困难。
- 对照 OpenClaw/Bub：更建议把 system prompt 里放“技能清单 + 位置”，正文按需 `read`/`skills.get`（on-demand），并配合 context cost report 做体积诊断。

对 Cybros 的启发：

- 我们已有 `prompt_injections`（FileSet/RepoDocs/TextStore）；可以直接表达“系统文件注入”
- Memoh 的“静态/动态分段”是为了 prompt caching；若我们要在 Anthropic/类似缓存策略上省钱，可以考虑把“稳定章节”固定为可缓存前缀

## 3) Context Window：按时间窗口加载 + token 上限 + tool message 保护

Memoh 在对话 resolver 中加载上下文时，会：

- 默认加载最近 24h（README 描述；具体实现里有 max_context_load_time）
- 同时受 `max_context_tokens` 限制
- 在 head-trim 之后，会跳过开头孤儿 `tool` message，避免 provider 400（`internal/conversation/flow/resolver.go` 中对 role=tool 的保护）

对 Cybros 的启发：

- 我们的 context 窗口目前是“按 turn 数”裁剪（context_turns），并在 tool loop 中保证工具节点顺序；
- 但如果未来引入“按 tokens 细粒度裁剪 / 只裁剪 tool results”，需要注意 Memoh 提到的“tool message 必须跟在 tool call 之后”的协议约束（避免 orphan）

## 4) Memory：Mem0 风格“结构化长记忆”（关键价值）

Memoh 的 memory 模块非常工程化（`internal/memory/*`），核心链路：

1. **从对话中提取 facts**
   - `internal/memory/prompts.go` 的 `getFactRetrievalMessages`：Personal Information Organizer，输出 `{facts:[...]}`（同语言）
2. **召回候选旧记忆**
   - 根据 facts 做向量/稀疏检索拿 candidates（Qdrant store + embedding 或 BM25 sparse）
3. **决定动作（ADD/UPDATE/DELETE/NONE）**
   - `getUpdateMemoryMessages`：对比新 facts 与旧 memory，输出更新后的 JSON
4. **应用变更**
   - `Service.Add` 中按 action 执行 `applyAdd/applyUpdate/applyDelete`
5. **压缩/衰减**
   - `getCompactMemoryMessages`：将 memory entries consolidate，支持 time decay（老记忆低优先）

检索能力：

- embedding（text / multimodal）+ Qdrant vector search
- sparse（BM25）+ 语言检测（专门 prompt）
- 多来源结果做 rank fusion（代码中有 `fuseByRankFusion`）

对 Cybros 的映射与差距：

- 我们已有 pgvector memory_store（search/store/forget），但缺少：
  - “从对话中抽取 facts 并写入 memory”的自动链路
  - “ADD/UPDATE/DELETE”的结构化记忆管理（而不是追加）
  - hybrid 检索（BM25 + vector）与时间衰减
- 这类能力非常适合做成 **可插拔 memory backend**（AgentCore::Resources::Memory::Base 的实现），并通过 memory tools 暴露给 agent

建议的渐进落地：

- P0：先提供 memory tools（search/store）+ 简单写入（append-only）
- P1：加入 facts extraction（从 turn 末尾抽取若干 facts 存入 memory）
- P2：引入 mem0 风格 update/delete + compact/time decay（可配置开关，避免误删）
- P2：引入 hybrid（可先用 Postgres full-text / trigram 作为轻量 BM25 替代）

## 5) Subagent：平台侧存 context，容器侧执行受限工具

Memoh 的 subagent 工具（`agent/src/tools/subagent.ts`）提供：

- list/create/delete/query subagents
- 每个 subagent 有独立 messages context（平台 API 存取）
- query 时创建一个受限 action 的 agent（示例：只允许 Web），把结果写回 subagent context

对 Cybros：

- 这和 `docs/dag/subagent_patterns.md` 的“子图=子会话”非常一致；
- 建议把 subagent 做成 app 层能力，并给 AgentCore 提供一个 `subagent` tool 入口（P1）

## 6) 调度：cron schedule

Memoh 支持 cron（README），并在 agent prompt 中用 `schedule` prompt 把“系统触发的计划任务”标记出来（`agent/src/prompts/schedule.ts`）。

对 Cybros：

- Solid Queue 是执行底座，但需要 app 层实现 cron 计划管理；
- 建议把“schedule task”当作一种 `user_message`（带 metadata headers），进入 DAG 正常执行与审计。

## 7) 在 Cybros 上实现的可行性评估

### 能做到（需要明确分层）

- Memory 工程：完全可做成 AgentCore 的 memory backend + tools（P0/P1/P2）
- subagent：可用 DAG 子图实现（P1）
- cron：可用 app 层实现（P1）

### 需要额外运行时/产品投入

- 每 bot 容器隔离（Memoh 依赖 containerd）：属于 L3 runtime
- 多渠道收发与 GUI：属于 L2 app

## 8) 借鉴要点总结

- Memoh 最值得抄的是：**把“记忆管理”当成一条可工程化的链路**（提取→召回→决策→变更→压缩/衰减），而不是只做“向量检索注入”
- prompt 的“静态/动态分段 + headers”对缓存与可观测也很有帮助

## 9) Skills / tool calling / 模型 workaround：实践要点

- **tool message 保护很关键**：当我们做“按 tokens 裁剪 / 工具结果 pruning”时，必须保证 tool_result 不会变成 orphan（没有对应 tool_call 的 tool message 会触发部分 provider 的协议错误）。Memoh 在 resolver 里用“跳过开头孤儿 tool message”的方式兜底，这是一个很实用的防线。
- **技能与工具都要可观测**：Memoh 把技能内容直接注入 prompt，会导致“为什么 budget 不够/模型选择困难”难以定位。建议在 Cybros 侧把“注入了哪些 skills/tools/文件、各占多少 tokens/bytes”写进一次调用的 metadata（并提供诊断视图）。
