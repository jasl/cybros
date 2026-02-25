# 参考项目调研：NanoClaw（references/nanoclaw）

更新时间：2026-02-24  
调研对象：`references/nanoclaw`  
参考版本：`5298449`（2026-02-24）

## 1) 项目定位与核心形态

NanoClaw 是一个“个人 Claude 助手”，主打：

- **安全靠隔离（容器）**，而不是应用层 allowlist
- **按群组隔离上下文与文件系统**：每个 group 独立容器与独立 `.claude` sessions 目录
- 通过 Claude Code / Claude Agent SDK 运行（把“harness”当作核心能力来源）
- 支持 scheduled tasks、web access、以及 **Agent Swarms/Teams**（Claude agent teams）

它不是一个通用 SDK，而是一个“代码很小、可让 Claude 自己修改”的个人产品原型。

## 2) 调度/运行时：容器是核心，而不是可选项

NanoClaw 的关键实现点在 `src/container-runner.ts`：

- 主 group（isMain）可挂载整个项目 root；其他 group 只挂载自己的 group 目录
- 每个 group 拥有独立的 `.claude/`（会话、技能、设置），路径：`DATA_DIR/sessions/<group>/.claude`
- 写入 `settings.json` 以开启：
  - `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`（teams/swarms）
  - `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1`（额外目录 CLAUDE.md）
  - `CLAUDE_CODE_DISABLE_AUTO_MEMORY=0`（Claude auto memory）
- skills 从 `container/skills` 同步进每个 group 的 `.claude/skills/`
- 每个 group 也有独立 IPC 目录（防止跨组提权）

对 Cybros 的含义：

- 如果我们要复刻 NanoClaw 这种“可执行命令/可写文件”的个人助手体验，**容器隔离是架构前提**（属于 L3 runtime，不是 AgentCore 里的一个参数）
- Cybros 的 DAG/AgentCore 能很好地表达“回合/工具/审批/审计”，但真正的安全边界需要靠容器/沙箱来实现

## 2.1) “基本工具”到底有哪些（allowedTools + MCP）

NanoClaw 的“工具基座”很大程度来自 Claude Agent SDK / Claude Code preset，而不是 NanoClaw 自己发明工具。

在其容器内的 agent runner（`container/agent-runner/src/index.ts`）里，SDK 被配置为 `permissionMode=bypassPermissions`，并显式给出 `allowedTools`，其中包含（摘核心）：

- **执行**：`Bash`（它之所以敢 bypass 权限，前提是“容器隔离就是安全边界”）
- **文件**：`Read`、`Write`、`Edit`、`Glob`、`Grep`
- **Web**：`WebSearch`、`WebFetch`
- **任务/编排（SDK 内置）**：`Task`、`TaskOutput`、`TaskStop`、`TeamCreate`、`TeamDelete`
- **交互/工程化辅助**：`TodoWrite`、`ToolSearch`、`Skill`、`NotebookEdit`
- **自定义 MCP server（IPC）**：`mcp__nanoclaw__*`

另外，NanoClaw 还把 “收到消息先 ACK 再继续跑” 这种需求做进了自己的 MCP tools：

- `mcp__nanoclaw__send_message`（立即发消息）
- 以及 scheduling 相关的 `mcp__nanoclaw__schedule_task/list_tasks/...`（见 `docs/REQUIREMENTS.md`）

> 对 Cybros 的启发：即便你坚持“核心原语少”，在产品上仍然很难只靠 `Read/Write/Edit/Bash` 四个名字跑通所有体验；NanoClaw/OpenClaw 共同补的“正交能力”基本都是：**搜索（Glob/Grep）**、**Web（Search/Fetch）**、**长任务/会话（Task/Process）**、以及 **渠道 ACK/发送**。

## 3) Prompts、上下文与记忆（Memory）

NanoClaw 的“记忆”主要依赖 Claude Code 的机制：

- 每个 group 有自己的 `groups/*/CLAUDE.md`（类似 workspace memory / instructions）
- `.claude` 目录隔离保证不同 group 的会话与自动记忆不串
- 通过 Claude Code 的 memory feature（auto memory）在 session 之间保留偏好

这种做法的特点：

- 记忆是“文件/会话状态”而不是“平台统一 RAG”
- 记忆与工具执行都绑定在 Claude Code harness 内（你换 harness，体系就变）

对 Cybros 的启发：

- Cybros 已有 memory_store（pgvector）与 prompt injection（FileSet/RepoDocs），可以表达“CLAUDE.md 注入”
- 但如果我们把 NanoClaw 当作“参考实现”，更值得借鉴的是：
  - **按 group/session 做严格隔离**（tenant + group + conversation 的多级 scope）
  - 把“skills 作为变更单元”而不是把所有功能做进核心（NanoClaw 明确鼓励贡献 skills）

## 4) 特色能力：Agent Swarms/Teams

NanoClaw 通过 Claude 的 agent teams 来做 swarm。这种能力在 Cybros 上可用两条路实现：

1. **“DAG 原生 teams”**：把多个子 agent 作为子图并行跑，再在父图聚合（Cybros 更可审计、更可控）
2. **“依赖外部 harness”**：直接跑 Claude Code teams（更快拿到现成能力，但耦合 Claude）

对平台探索而言，建议优先走（1），而不是把核心能力锁死在某个外部供应商的 teams 机制上。

## 5) 在 Cybros 上实现的可行性评估

### 能做到（但需要明确边界）

- 个人助手的“会话图 + 任务图”表达：DAG 可胜任
- scheduled tasks：可用 Solid Queue + cron enqueue（但需要 app 层补“周期计划”模型）
- group 隔离：Cybros 多租户 + Conversation scope 可以表达

### 需要补的能力

P1（产品/平台层）：

- **Schedule/Automation 子系统**：cron 表达式、启停、幂等、回传消息（类似 OpenClaw/Memoh）
- **Channel 适配**：NanoClaw 主打 WhatsApp I/O（需要集成）

P2/L3（运行时）：

- **容器化执行**：为工具执行提供隔离（workspace mounts、network policy、secrets 传递）

## 6) 对 Cybros 的具体建议

如果把 NanoClaw 作为“个人助手形态”的对标：

1. 在 app 层先做“schedule + channel routing + owner-only 安全策略”
2. tool 执行尽量放到容器（或 MCP sandbox runner）中，避免把主 Rails worker 当作执行沙箱
3. subagent/teams 用 DAG 子图来做（可审计、可回放、可压缩），再考虑是否需要对接 Claude teams 作为加速器

## 7) Skills：用“技能改造代码库”来避免核心膨胀

NanoClaw 对 skills 的定义与“运行时 prompt 技能”不同：它更像一套 **可审计的代码变更包系统**（见 `docs/nanorepo-architecture.md`）：

- **技能 = 自包含变更包**：携带新增文件与“完整的被修改文件”，以便做三方合并（`git merge-file`）。
- **结构化操作**（依赖/compose/env 等）用 manifest 声明，运行时做确定性聚合（避免把这些细节塞进 prompt 或手写 merge）。
- **三层冲突处理**：Git（确定性）→ Claude Code（解决冲突并缓存 rerere）→ Claude+用户决策（语义冲突）。
- **测试强制**：apply/update/uninstall/replay 后都跑测试，确保“干净 merge ≠ 可运行”。

对 Cybros 的启发：当实验方向很多时，skills 也可以是“产品/集成的交付单元”，用它来对冲“核心代码/核心 prompt 越堆越大”的风险。

## 8) Workarounds：Claude harness / streaming 细节会影响可用性

NanoClaw 的文档里有两个很典型的“harness workaround”：

- **保持 stdin 不关闭**：为了支持 agent teams/多轮 streaming，它建议用 `AsyncIterable` prompt（而不是一次性 string prompt），避免 CLI 的单轮模式触发关闭 stdin、导致“teammate check / shutdown prompt injection”之类的异常流程（见 `docs/SDK_DEEP_DIVE.md`）。
- **容器 env 传递兼容性**：为避免某些容器运行时在 `-i` 交互模式下丢失 `-e` 环境变量，NanoClaw 把认证变量写入一个 env 文件并挂载到容器里再 source（见 `docs/SPEC.md` 的 Claude Authentication 部分）。这属于“跨平台/跨 runtime 的稳定性 workaround”。
