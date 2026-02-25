# 产品层（Product Layer）文档索引

本文档集用于记录 Cybros 在 **DAG 引擎** 与 **AgentCore** 之上的“产品层”决策与行为规范。

目标：

- 把“我们现在认为对的东西”写清楚（可审阅、可推翻）。
- 把“我们还不确定的地方”显式标出来（开放问题清单）。
- 保持与引擎层一致的风格：**有边界、有原则、有安全默认值**。

---

## 0) 产品层的范围（What / Not What）

产品层包含但不限于：

- 身份/权限：Users、Roles、ACL / Share。
- 资源管理：MCP、知识库（KB）、Agents、Hosts/Sandboxes、Workspaces、Skills 等。
- 编排与交互：多 Agent 编排、UI/UX 交互模型、默认工作流。
- 系统设置：LLM Provider / Models、默认 sandbox、配额/限制等。
- 可观测性：用量统计（tokens/请求数）、延迟、审计事件、用户看板。

产品层不试图解决（由底层负责或另行设计）：

- DAG 引擎行为规范：见 `docs/dag/*`
- AgentCore 的 tool/MCP/skills 协议与运行时注入：见 `docs/agent_core/*`
- 执行与沙箱基础设施（ExecHub + Runner）：见 `docs/execution/*`

---

## 1) 当前设想（需要持续质疑）

服务特征（当前讨论基线）：

- Self-hosted，**单租户**（single-tenant）。
- 推荐容器部署；开发/高级用户可 bare metal。
- 部署建议与 Agent 运行环境隔离（但不强制）。
- 多用户。
- 需要最小形态的共享：引入 **Space（工作区）** 作为隔离/协作边界（Phase 1 锁定只有 1 个默认 Space；不实现 Space 管理/切换 UI）。
  - 个人对话（Conversation）属于隐私，默认且长期保持私有（owner-only；不通过“共享”改变）。
  - MCP、知识库、Agents、主机与沙箱等资源默认私有；Phase 1/2 不做“在 Space 内共享并协作编辑”能力，主要通过导出/分享（例如 GitHub repo URL）实现协作。
- 系统全局管理可共享内部数据：例如 prompt cache（见隐私/安全注意）。
- 存在全局资源：LLM Provider、LLM Models、全局共享/内置 Agent。
- 系统级设置全局共享：LLM API、各种次数/体积/频率限制、是否提供默认沙箱等。
- 用户允许少量个性化设置。
- 每用户有独立用量统计与看板；系统也有聚合统计；LLM 用量可细分到具体模型。
- 单租户落点选择：**不实现实例内多租户**；资源作用域采用 `scope=global|space|user`（UI 可显示为 “System/Space/Personal”）。未来若要 SaaS 化，推荐通过 supervisor 部署多实例，并通过内部管理 API 远程管理实例。

这些设想的“风险点/矛盾点/未定义点”会在各子文档的 **Open questions** 中持续维护。

---

## 2) 文档目录

- Terminology / Glossary（draft）：`docs/product/terminology.md`
- Persona switching（draft）：`docs/product/persona_switching.md`
- Programmable agents（draft）：`docs/product/programmable_agents.md`
- Prompt programs（draft）：`docs/product/prompt_programs.md`
- MCP servers（draft）：`docs/product/mcp_servers.md`
- Channels / Bots（draft）：`docs/product/channels.md`
- Agent UI / App mode（draft）：`docs/product/agent_ui.md`
- Channel pairing（draft）：`docs/product/channel_pairing.md`
- Sandbox requirements（draft）：`docs/product/sandbox_requirements.md`
- Safe Retrieval（draft）：`docs/product/safe_retrieval.md`
- Deferred Security Concerns：`docs/product/security_concerns.md`
- Diagnostics（draft）：`docs/product/diagnostics.md`
- Behavior spec（draft）：`docs/product/behavior_spec.md`
- Phase 1 review（draft）：`docs/product/phase_1_review.md`
- Phase 1 implementation plan（draft）：`docs/product/phase_1_implementation_plan.md`
- Phase 1 MVP audit（2026-02-24）：`docs/product/audit_phase_1_mvp_2026-02-24.md`
- Versioning + sync（draft）：`docs/product/versioning_and_sync.md`
- Tenancy + isolation：`docs/product/tenancy_and_isolation.md`
- Automations（draft）：`docs/product/automations.md`
- Extensions / plugin system：`docs/product/extensions.md`
- Extensions specs + resources（draft）：`docs/product/extensions/README.md`
- Agents + orchestration：`docs/product/agents.md`
- Observability + usage accounting：`docs/product/observability.md`

---

## 3) 设计原则（Draft）

- **基座不可变（Upstream-first）**：Cybros 主程序不鼓励/不支持用户私改；扩展通过插件与可配置资源完成。
- **安全默认值（Deny-by-default）**：默认最小权限、最小可见性、最小网络/执行能力；放权要可审计、可撤销。
- **可回滚**：用户对 Agent / Prompt / 编排的修改必须可审计、可 diff、可回滚（例如 git/版本记录）。
- **边界清晰**：产品层不越过 DAG/AgentCore 的 Public API 边界；缺能力则先补 Public API + tests/doc。

---

## 4) Quick demo：Agent 自改闭环（MVP）

目标：演示 “在沙箱里修改 Agent repo → 立刻生效 →（若启用 git）可回滚”，并验证“改坏了要 fail-fast + 提示回滚/切换内置 agent”。

步骤：

1. 启动并登录（dev：`admin@example.com` / `Passw0rd`）。
2. 基于 system 内置模板创建一个 Programmable Agent（生成一个 Agent repo；默认建议初始化为 git）。
3. 新建 Conversation，选择该 Programmable Agent。
4. 对 Agent 说：把 `context_turns` 改成 80（或禁用 `repo_docs` 等）。
5. Agent 在沙箱中编辑 Agent repo 的配置文件；权限交互与 vibe coding 一致（Manual/Cowork）。
6. 变更立刻生效；若启用 git，UI 可查看历史并一键 revert；若改坏，则 fail-fast 并提示回滚/切换内置 agent。
