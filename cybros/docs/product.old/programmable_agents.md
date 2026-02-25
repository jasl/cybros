# 可编程 Agent（Programmable Agent，Draft）

本文档定义 Cybros 在产品层对“可编程 Agent”的语义、边界与推荐落点。

这里的“可编程”不是指在主进程里执行任意代码（那属于 Core plugin 的高风险范畴），而是指：

- Agent 能在受控的执行环境（sandbox/runner）里**组合少量确定性原语**（读/写/编辑/执行），完成复杂任务；
- Agent 的“自定义/演进”主要通过 **Agent repo 里的文件（可选 git）**实现，并受沙箱策略与 permission gate 约束；
- 系统提供足够的 insight（观测/回放/版本/回滚）让用户形成“使用 → 修正 → 固化”的迭代闭环。

> 立场：自我演进不是目标，而是“可编程 + 可观测 + 可回滚”之后自然出现的一种工作方式。

相关基础规范：

- Permission gate：`docs/product/behavior_spec.md`
- 版本化与导出（git / GitHub）：`docs/product/versioning_and_sync.md`
- 沙箱能力需求：`docs/product/sandbox_requirements.md`
- MCP servers 策略：`docs/product/mcp_servers.md`
- 插件系统分层：`docs/product/extensions.md`

---

## 1) 我们要的“可编程”到底是什么

### 1.1 定义（产品语义）

可编程 Agent = “对话 + 计划 + 受控执行”的组合体：

- **对话层**：澄清目标/约束/预算（成本、时间、风险）。
- **计划层**：把目标拆成可验证的步骤（plan），并把“验证”当作步骤的一部分。
- **执行层**：用少量原语在沙箱里完成步骤（执行命令、改文件、生成补丁、跑测试、产出工件）。

### 1.2 非目标（必须明确）

- 不追求“任何情况下都自动完成”——当权限/环境/依赖不足时，必须能稳定地进入 `blocked` 并告诉用户**下一步需要什么**。
- 不把“安全”寄托在 persona 或 prompt——安全边界由 policy + permission gate + sandbox 隔离承担。
- 不在 Rails 主进程里运行用户代码；用户代码只能作为沙箱内任务执行（见 `docs/product/versioning_and_sync.md` 与 `docs/product/extensions.md`）。

---

## 2) 最小原语：Read / Write / Edit / Bash（建议）

我们希望把绝大多数“平台能力”收敛为少数确定性原语（Pi-Mono 的经验很有价值）：

- `read`：读文件/列目录/读取资源（只读）
- `write`：写入新文件（副作用）
- `edit`：对既有文件做最小变更（patch/apply）
- `bash`：执行命令（副作用）

### 2.1 重要澄清：工具“名字少”不等于“能力弱”

严格只给模型 4 个工具名并不必然弱，前提是我们把一些高频、正交的能力做成这些原语的 **子动作（sub-actions）**，避免依赖“沙箱里刚好装了某个命令”：

- `read`（建议内建）：
  - `glob`（按模式列文件）
  - `grep/search`（在受控预算内做内容搜索，返回截断后的片段+位置）
  - `web_search`（可选：有配置的搜索后端时才启用；避免用 bash 解析搜索结果页）
  - `web_fetch`（Safe Retrieval；见 `docs/product/safe_retrieval.md`）
  - `memory_search`（受控检索；可由内置 memory 或 internal query API 提供）
- `bash`（建议内建）：
  - 长任务会话（start/poll/send/kill/list），避免把“持续跑的命令”变成一次性超长 timeout（见 `docs/product/sandbox_requirements.md` 2.4）

在产品层这类能力仍然可以保持“少量工具名 + 强 schema + 强预算 + 强审计”，但会显著提升：

- 成功率（减少模型写复杂 shell 的概率）
- 可移植性（不依赖 runner 镜像里预装 `rg/find` 等）
- 止损能力（长任务可 cancel/kill，可分页取日志）

> 这与 OpenClaw/NanoClaw 的经验一致：它们都在 “Read/Write/Edit/Bash” 之外补了搜索、Web、长任务/会话、以及渠道 ACK/发送等正交能力，但会通过 profiles/policy 做裁剪，而不是无限暴露给模型（见 `docs/research/ref_openclaw.md` 与 `docs/research/ref_nanoclaw.md`）。

好处：

- tool calling 更稳定（工具少、语义清晰、可测试）。
- 权限模型更清晰（Read 默认放行；Cowork 下对“标准沙箱动作”默认自动；能力升级仍 ask）。
- 更容易把高级能力（skills、UI、A2A）分解成“在这些原语之上”的组合，而不是不断膨胀核心工具面。

实现注记（对齐现有设计）：

- Cybros 仍然允许更丰富的 MCP/tools/skills，但建议把它们**编译/归一**到上述原语或少数稳定工具组中，避免“同类工具重叠”导致模型选择困难（见 `docs/research/ref_opencode.md` 与 `docs/research/ref_codex.md`）。
- foundation 执行面可以通过 internal MCP server 实现（例如集成 DesktopCommanderMCP），但不应把第三方 MCP 的 guardrails 当作安全边界；隔离仍由 sandbox profile + 挂载策略承担（见 `docs/product/mcp_servers.md`）。

---

## 3) 工作区与 repo 映射（关键：把边界说清）

你提出“把用户使用的 Agents 定义（git repo）映射进沙箱”是可行的，但必须先把“workspace 的类型”讲清楚，否则会把安全边界与可回滚语义搅在一起。

### 3.1 建议的 Workspace 类型（最小集）

建议把执行侧 workspace 明确分成至少两类：

1) **Project workspace**：用户想让 Agent 操作的项目/代码仓库（coding/automation 的主要对象）。
2) **Agent repo workspace（可选 git）**：承载该 Programmable Agent 的 Agents/Workflows/PromptBuilder 等“用户可变资源”的 Agent repo（见 `docs/product/versioning_and_sync.md`）。

可选增强：

3) **Scratch workspace**：临时输出/中间产物（默认可丢弃、可重建）。

### 3.2 映射与挂载策略（安全默认值）

规范性倾向：

- **单次 run 默认只挂载一个 workspace**（避免“项目代码”在执行时顺手修改系统配置 repo，扩大误伤面）。
- 若确实需要跨 workspace（例如从 Project 生成补丁再写入 Agent repo），必须显式声明并走审批（能力升级）。
- Agent repo workspace：
  - 读/写/执行与正常 vibe coding 一致：由沙箱策略与所选模式（Manual/Cowork/Evolution）决定是否需要 ask。
  - 若 repo 是 git，变更可 commit/diff/revert；若不是 git，则系统仍需可用但缺少历史/回滚能力（应在 UI 中显式提示）。

这样就能实现你想要的“映射进沙箱”，同时不牺牲可解释性与止损（diff/revert；若启用 git）。

---

## 4) 沙箱环境：只保证“基础壳”，其余显式声明（建议）

你强调“不保证任何 shell 和基础编程环境外的能力”是合理的：它迫使产品与用户明确依赖，而不是靠“碰巧装了某个工具”。

建议口径：

- 系统只承诺一个**最小可用**环境（shell + 文件操作 + git + patch/apply 的能力）。
- 语言运行时与工具链（Node/Python/Ruby/Go/Chrome/…）都不做隐式承诺：
  - 要么由 sandbox image/profile 显式提供（可配置资源）。
  - 要么由 skills/插件在沙箱内安装（可审计、可重建）。

关键是：把“可运行性”变成可声明、可复现、可诊断的配置，而不是经验主义。

---

## 5) 信任阶梯：从“谨慎”到“自改”的可解释升级

可编程 Agent 最容易失控的地方在于：为了省交互，用户会打开 `Auto-allow executes/writes`，然后模型在一个长任务里积累足够的破坏力。

因此建议把“信任”显式做成阶梯（trust ladder），并让升级在 UI 与审计中可见：

### 5.1 Cowork（默认）

面向 Pro 用户的默认模式：在 **标准沙箱动作** 范围内，允许 agent “无人值守连续执行”以完成端到端目标（包含自验收），但不允许能力悄悄升级。

规范性倾向：

- **Plan gate 默认开启**：当一个 turn 将产生任何副作用（Execute/Write/Edit）时，必须先出 plan 并获得一次性 “Start Cowork run” 确认（见 `docs/product/behavior_spec.md` 6.1.1）。
- 默认自动放行：当前 workspace（project 或 agent repo）内的 `Execute/Write/Edit`（见 `docs/product/behavior_spec.md` 6.1）。
- 仍然必须 ask：任何能力升级（secrets/host IO/private network/unrestricted network/跨 workspace 挂载等）。

### 5.2 Manual（可切换）

手动模式用于高风险任务或新用户保守使用：

- `Execute/Write` 每次 ask（与传统“审批驱动”桌面 agent 体验一致）。
- 适合：你在调试 policy、担心 workspace 被破坏、或在做安全演示。

### 5.3 Evolution（自修改模式，显式开启）

Evolution 用于“允许系统自改/自演进”的场景：允许修改“可编程 Agent 自身”的资源与代码（例如 Agent repo、skills 包、workflow），但仍然必须：
  - 限定 workspace 与挂载范围；
  - 有明确的预算（最大步骤/时间/产物大小）；
  - 有可回滚/可禁用的止血路径（git revert / 禁用 workflow / safe mode）。

> 这不是为了“更强”，而是为了把不可避免的 trade-off 做成可解释、可撤销的产品语义。

### 5.4 Prompt building off-load（可选，高风险能力）

你提出“把一部分能力（尤其 prompt building）off-load 到沙箱执行，使其天然可编辑/可同步 GitHub”的路径是可行的，但应当被当成 **Evolution 范畴的高风险能力**：

- 它会把“提示词组装逻辑”从声明式 DSL 变成可执行程序，可靠性与可诊断性要求更高；
- 必须对输出做严格 validation，并提供 fallback（否则一旦写坏就会“整个系统无法对话”）。

规范草案见：`docs/product/prompt_programs.md`。

### 5.5 Channels / Bots（可选增强）

你提到的“收到消息后立刻回复收到，再继续运行”属于 **渠道/工作流层**（而不是 persona 或 prompt building）：

- 在 IM（Telegram/Discord 等）里，长任务应当默认发送 `ack/progress/final` 三段式消息；
- ack 文案与 bot 口吻应当可配置（Pro 用户常见需求）。

规范草案见：`docs/product/channels.md`。

---

## 6) 可观测性：必须能“解释我为什么这么跑”

可编程 Agent 若没有足够的 insight，很快会变成黑盒，用户只能通过“更长的 prompt”修 bug，最终失控。

最低要求（规范性倾向）：

- 每个 run 的：workspace、命令、权限摘要、资源限制、耗时、exit code、stdout/stderr 截断信息都要可见。
- 关键产物应当可下载/可重放（补丁、测试报告、生成文件）。
- 需要“上下文成本账单”（system prompt / injected files / tool schemas / tool results / skills）与 pruning/compaction 记录（对齐 OpenClaw/OpenCode 的诊断能力）。

---

## 7) Open questions

- “基础壳”的最小集合到底包含什么？（只保证 `bash+git` 还是也保证 `python3`？）
- Agent repo 与 Project workspace 的跨挂载是否真的需要？如果需要，默认策略是什么？
- Cowork 的 plan gate 触发阈值怎么定义得更可预期？（例如：首次副作用动作、还是任何涉及文件写入/命令执行都必须出 plan；以及 plan 是否需要“差异触发二次确认”）
- Prompt programs（沙箱 prompt building）是否只允许 `NET=NONE`？KB/Memory 的访问是通过输入 bundle（推荐）还是允许受控 RPC（更复杂）？
- skills/插件/可编程 Agent repo 三者的分工边界：哪些应当是“分发单元”，哪些只是“本地资源”？
