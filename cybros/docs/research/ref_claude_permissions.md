# 参考资料：Claude Code Permissions（官方文档）

更新时间：2026-02-25  
来源：https://code.claude.com/docs/en/permissions

> 注：这是一份“产品行为/配置语义”参考，不是 references 代码调研。下面只抽取对 Cybros 设计有直接启发的部分。

## 0) 一句话摘要

Claude Code 把权限从“每次弹窗问用户”扩展成一套 **可配置的 allow/ask/deny 规则系统**，支持 **wildcard patterns** 与 **tool-specific specifiers**（命令/路径/域名/MCP 工具等），并在不同 permission modes 下改变默认行为。

## 1) 它提供了哪些关键能力（抽取）

### 1.1 Permission modes（默认策略的切换）

文档描述了多种模式（例如默认、仅计划、仅 allowlist、绕过权限等），其核心价值是：把“默认问不问”从 UI 行为上升为一种可审计的模式选择。

对 Cybros 的映射：

- 我们已经有 `Manual/Cowork/Evolution` 作为信任阶梯；
- Claude 的 `plan` 更像是“禁止副作用，只允许规划/解释”，与我们当前的 Plan gate（起跑线确认）不是同一件事；
- `bypass` 类模式在 Cybros 里应当非常克制（仅 admin/诊断用途），否则会变成绕过审计的后门。

### 1.2 Permission rules（allow/ask/deny）

规则是三段式：

- `deny`：直接拒绝
- `ask`：必须问
- `allow`：自动通过

并且评估顺序是 `deny → ask → allow`（deny 永远优先）。

对 Cybros 的映射：

- 我们已有 “Allow once / Auto-allow in this conversation / Reject”；
- 缺口在于：缺少“ask/deny/allow 的规则化表达”，尤其是对 `bash` 命令与文件路径的 patterns；
- space-level rules 可以承担“团队基线”；conversation-level rules 承担“临时放行/止损”。

### 1.3 Tool-specific specifiers + Wildcard patterns

文档给出了多类规则形态，最值得吸收的是：

- `Bash(...)`：对命令字符串做 wildcard 匹配（并强调 operator-aware，避免 `cmd && evil` 绕过）
- `Read(...) / Edit(...)`：对路径用 gitignore 风格 patterns（`*` vs `**`，相对/绝对/项目根等）
- `WebFetch(...)`：按 domain 规则治理联网
- `MCP(...)`：按 MCP server / tool 名称做匹配（支持 `*`）
- `Task(...)`：对子 agent/子任务做规则（相当于“子图执行权限”）

对 Cybros 的映射：

- `bash` 的命令 patterns 能显著减少审批噪音，并能在 Cowork 下“对危险命令强制 ask/deny”；
- 文件 path patterns 能把“workspace writes”从粗开关变成可控的 allowlist/denylist；
- domain rules 与我们 Safe Retrieval 的方向一致：尽量不要通过 bash/curl 绕过网络治理；
- MCP 的规则需要放在 Tool Facade 层做（我们不希望把所有 MCP 工具直接暴露给模型）。

### 1.4 Hooks（PreToolUse）

文档提到可以用 hooks 在 tool call 前做额外检查/放行/拒绝（例如更强的 URL 解析、策略判断）。

对 Cybros 的映射：

- 我们可以把它视为 Tool Facade 的一个“可扩展 hook 点”（但必须是 deterministic + 可审计）；
- 更适合做成 Core plugin（高信任）或系统内置 guardrail，而不是用户脚本（避免把权限判断本身变成不可信）。

### 1.5 Working directories / 额外目录授权

文档强调 “授权额外目录” 与执行/编辑权限的关系。

对 Cybros 的映射：

- 对齐我们的 “workspace 挂载/跨 workspace 属于 capability upgrade”；
- 这也是为什么 patterns 必须以 workspace root 为边界，否则规则会在挂载变化时失效或被绕过。

## 2) 对 Cybros 的具体建议（落在产品层）

结合 Cybros 当前设计（Plan gate + Cowork 默认 + deny-by-default sandbox + Tool Facade），最直接可落地的是：

1) 在 `conversation` 与 `space` 两层引入 permission rules（allow/ask/deny），支持 wildcard patterns  
2) 规则评估顺序固定为 `deny → ask → allow`，并且 **ask/deny 必须能覆盖 Cowork 的 auto-run**（止损）  
3) patterns 只支持安全子集（glob-like，不支持正则），并对 bash 做 operator-aware 解析（最小可用即可）  
4) domain 规则与 Safe Retrieval 结合，避免出现 “bash/curl 走私网/绕过审计” 的路径  

产品层规范草案落点建议：

- `docs/product/behavior_spec.md`：补齐规则语义、层级与默认行为（我们应当把它写成规范）
- `docs/product/channels.md`：IM 审批卡片提供“写入规则”的入口（conversation-level，必要时可 promote 到 space）
- `docs/product/diagnostics.md`：显示有效规则与最近变更（否则用户很难理解“为什么突然不问了/突然开始问了”）

## 3) 我们不应直接照抄的点（怀疑视角）

- “bypassPermissions” 这类能力在 self-hosted 场景也很危险，容易被当作省事开关滥用；应当收敛到 admin/诊断，并有明显的 UI 提示与审计。
- bash patterns 不能承担 URL/域名治理（脆弱）；网络治理应优先靠 Safe Retrieval + domain rules + sandbox policy。

