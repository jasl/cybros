# 参考项目调研：CLI 工具包（references/lobster / references/mcporter / references/gogcli）

更新时间：2026-02-25  
调研对象：`references/lobster`、`references/mcporter`、`references/gogcli`

本文件不是“单一产品对标”，而是抽取一个在多个项目里反复出现、且对 Cybros 很关键的思路：

> **把能力做成 JSON-first 的 CLI/工具包交付**，再由平台/runner 托管与治理，而不是把所有能力写进 core。

---

## 1) Lobster：typed workflow shell + approvals/resume（可减少 agent 反复规划）

Lobster 的定位是 “workflow shell”，核心点：

- **Typed pipelines（JSON-first）**：管道处理对象/数组，而不是文本 pipe。
- **Approval gate**：内置 `approve` 步骤，可在 pipeline/workflow 中插入人工闸门。
- **可组合宏**：把常用工作流封装成“一条命令”，减少 LLM 反复规划与上下文膨胀。
- **Local-first**：强调本地执行与可恢复性（workflow files + steps）。
- **不拥有 auth**：刻意不引入新的 OAuth/token 面（避免 CLI 自己变成高危权限汇聚点）。

对 Cybros 的启发：

- 把“计划/审批/执行”固化为可复用的 workflow（CLI 或 skills），可以显著降低 Cowork 的 token 与不确定性。
- Lobster 的 `approve` 能力可以与 Cybros 的 permission gate/plan gate 对齐：平台负责最终审批语义，CLI 负责把“需要人工确认的阶段”结构化表达出来。

---

## 2) MCPorter：MCP 的 runtime + CLI + codegen（把 MCP 当成可组合基础设施）

MCPorter 解决的问题不是“提供某个具体能力”，而是：

- **发现/合并配置**：自动导入多种客户端的 MCP 配置并做连接池复用。
- **统一调用**：用一致的 CLI/TS API 调用任意 MCP server（HTTP/stdio）。
- **类型化**：可把 MCP 工具 schema 生成成 TS 类型/客户端，减少手写 plumbing。
- **生命周期**：引入 daemon/keep-alive，保持 stateful MCP server 的可用性。

对 Cybros 的启发：

- 这类“桥接/治理工具”说明：MCP server 的价值不仅是 tool surface，更是**运行时托管**（配置导入、连接复用、keep-alive、日志与诊断）。
- Cybros 若支持 external MCP server，必须把“托管与治理”做成平台能力（参见 `docs/product/mcp_servers.md` 的 Tool Facade / budgets / 审计）。

---

## 3) gogcli：domain CLI（Google）+ least-privilege + command allowlist（把高危 SaaS 能力做成可控工具）

gogcli 的产品化特点：

- **JSON-first 输出**：适合脚本/agent 调用（可解析、可测试）。
- **多账号（Google 账号）**：同一工具包支持多个登录身份。
- **least-privilege auth**：可用 `--readonly`、scope 控制来减少授权面。
- **command allowlist**：允许限制 top-level commands，适配“沙箱/agent runs”。
- **credential storage**：把凭据管理当作产品能力（keyring / encrypted file）。

对 Cybros 的启发：

- 对外部 SaaS 的连接器/自动化，最容易失控的是“授权与可滥用面”；command allowlist + least-privilege 是很强的止损工具。
- 这类能力更适合 Tier 1 sandbox plugin（skills/CLI），而不是 core 默认内置：默认关闭、显式启用、强审计与预算。

---

## 4) 跨项目抽象：把 CLI 当作“能力交付单元”，但必须被平台托管

将 CLI 引入 Cybros 的推荐落点（产品层）：

1) **CLI 作为 Tier 1 sandbox plugin 的交付形态**（脚本/二进制/容器任务）。  
2) **平台提供受控调用面**（而不是让 LLM 直接 `bash` 调用）：schema 校验、budgets、error codes、审计归因。  
3) **优先 MCP 化**：当 CLI 本质上是“工具集合”，优先封装为 stdio MCP server，再进入 Tool Facade。  
4) **命名归一**：即便 CLI/运行时侧喜欢用 `server.tool` 这类点号语法，暴露给模型的 tool name 仍应遵守 tool calling 命名约束（例如不支持 `.`），由 Tool Facade 做 aliases。

对应的产品层规范建议：

- Tier 1 插件分层与边界：`docs/product/extensions.md` 3.2 + 3.2.1
- MCP 托管与 Tool Facade：`docs/product/mcp_servers.md`
- Prompt-program 的 JSON 协议（可复用为 CLI 协议）：`docs/product/prompt_programs.md` 7

风险提示（怀疑点）：

- CLI 仍然是代码供应链：需要版本锁定、可禁用、可回滚、审计归因（plugin_id/version）。
- “JSON-first”是硬约束：stdout 混日志、交互式 prompt、非确定输出都会直接破坏 agent 的可靠性与可诊断性。
