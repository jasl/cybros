# 参考项目调研：Claude Desktop App（references/Claude）

更新时间：2026-02-25  
调研对象：`references/Claude`（解包后的桌面应用快照；非 git 仓库）  
参考版本：Claude `1.1.4010`（macOS app bundle）

## 0) 先澄清：Claude.app 与 DesktopCommanderMCP 的关系（基于本地快照能确认的部分）

在本快照里 **没有找到** `DesktopCommanderMCP / desktop-commander / wonderwhy-er` 等字样或内置代码痕迹。

更合理的解释是：

- Claude.app 提供了 **通用 MCP 运行时 + 扩展包机制（DXT/MCPB）**；
- DesktopCommanderMCP 作为 **外部 MCP server / 扩展**被安装后，由 Claude 的 MCP runtime 启动与托管；
- Cowork/本地执行体验的“底座能力”并不等价于“内置 DesktopCommanderMCP”，而是来自 Claude 自己的 VM/runner + tool gating 体系。

> 这对 Cybros 的意义：我们更应该学习“平台如何托管 MCP servers（升级/审计/隔离/日志/兼容性选择）”，而不是把某个第三方 MCP 当作内置组件。

## 1) Desktop Extensions：Claude 明确支持 DXT / MCPB / Skill 文件

从 `Info.plist` 可见 Claude 注册的 document types：

- `dxt`、`mcpb`：Desktop Extension
- `skill`：Skill File

这意味着它把“可安装能力”作为产品一等公民（至少在文件/扩展分发形态上）。

## 2) MCP Runtime：Claude 如何托管 MCP servers（关键）

### 2.1 运行方式：UtilityProcess + 内置 Node Host

在 `app.asar` 内可见一个 node host 脚本（路径形如）：

- `.vite/build/mcp-runtime/nodeHost.js`

其职责是：

- 作为 UtilityProcess 入口，动态加载 MCP server 的 entrypoint（Node ESM import）。
- 把 MCP server 的 **stdin/stdout/stderr** 通过 `process.parentPort` 变成可被主进程消费的消息流：
  - stdout/stderr：按 chunk 转发给主进程（nodeHost 本身不解析 JSON-RPC）
  - stdin：主进程以消息形式送入，nodeHost 把它 push 到一个 Readable stream

这与“把 MCP server 当成子进程 + stdio JSON-RPC”相比，更像一个 **受控的、可观测的、可超时/可 kill 的托管层**。

### 2.2 JSON-RPC 的中心化校验：`tools/list` / `tools/call`（可吸收）

在主进程 bundle（`index.js`）里能看到对 MCP JSON-RPC 的 schema 定义/校验（Zod），包含这些 method：

- `tools/list`
- `tools/call`
- `notifications/tools/list_changed`

对 Cybros 的启发：

- MCP client/runtime 不应只是“透传 JSON-RPC”，而应当把它当成一个**可执行策略的协议边界**：
  - 入参 schema validation（禁止 silent coercion）
  - method allowlist / profile 裁剪
  - budgets（最大输出字节数、超时、并发）
  - 审计归因（server/tool/profile）

这正是 `docs/product/mcp_servers.md` 中提出的 MCP Proxy / Tool Facade 落点。

## 3) Cowork / 本地执行：从快照里能看到的实现信号（只抽象结论）

从 bundle 内字符串与逻辑可见：

- 有 “本地 agent mode sessions” 的概念（sessionKey、/sessions 路径）
- 有 VM bundle 下载/热更新（以及针对不同虚拟化后端的兼容处理）
- 有“项目内配置文件”的扫描与提示：
  - `.claude/settings.json` / `.claude/settings.local.json`
  - 其中存在 `permissions.allow`（至少包含对 `Bash` 工具的 allow 逻辑）
  - 这与“trusted folders / allowlist directory”的产品语义一致：把放权落成可解释的配置与 UI 提示

这与我们在 Cybros 里要实现的产品语义高度一致：**权限 gate + 强隔离执行环境 + 可观测与可止损**。

## 4) 对 Cybros 的启发（本轮抽取）

- “集成 DesktopCommanderMCP”在产品层更应被表达为：**支持/托管外部 MCP server（DXT/MCPB）**，并把其能力纳入 profile/policy/审计，而不是把它当作内置可信组件。
- 基于快照里能确认的两点（内置 Node host + JSON-RPC method schema 校验），我们建议把 **MCP runtime** 当作平台一等能力来设计，至少包含：
  - 生命周期（启动/关闭/自动重连/超时与 kill）
  - 协议边界治理（schema validation + method allowlist + budgets + 审计归因）
  - （可选增强）runtime resolution：同一类 server 的多种运行方式（内置 runtime vs 系统 runtime vs exec）作为实现细节，不暴露给模型
  - （可选增强）Tool Facade：对 `tools/list`/`tools/call` 做虚拟化/裁剪/归一（这在 `docs/product/mcp_servers.md` 已抽象）

对应的产品层规范建议见：

- `docs/product/mcp_servers.md`（internal/external MCP server 边界 + DesktopCommanderMCP 定位）
- `docs/product/behavior_spec.md`（capability upgrade / auto-allow / plan gate）
- `docs/product/programmable_agents.md`（Cowork/Evolution 的信任阶梯）
