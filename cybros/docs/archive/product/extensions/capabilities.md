# Capabilities（能力声明）与权限边界（Draft）

capabilities 是插件必须声明的“意图与风险面”。它不是权限本身，但应当：

- 驱动安装/启用时的风险提示
- 驱动策略拒绝（例如不允许 Tier 2 或禁止读取对话）
- 驱动审计与用量归因（按 plugin_id/version）

本文件定义一个 **最小且正交** 的 capabilities taxonomy。

---

## 1) 设计原则

- 能力名必须稳定，避免实现细节泄露（例如不要用具体类名）。
- 能力应按“资源/数据/执行/界面”分组。
- 如果某能力涉及 secrets 或对话内容，必须单独成项（高风险显式化）。

---

## 2) 能力清单（建议）

### 2.1 Resources（模板/资源包）

- `resources:templates`：提供只读模板（可 Copy 到 repo）
- `resources:install_to_repo`：允许一键写入 repo（若 repo 启用 git：应产生 commit 以便回滚；审计 best-effort）

### 2.2 Tools / Skills（执行能力）

- `tools:register`：注册新的 tool schema（不等于允许自动执行）
- `skills:register`：注册新的 skill（对应 Runner 任务）
- `sandbox:execute`：在 Runner 执行任务（Tier 1 默认需要）

### 2.3 Data access（数据读写）

> 这些能力对 Tier 2 高度敏感。Phase 1/2 建议默认禁用。

- `data:read_conversations`：读取 Conversation 内容
- `data:write_conversations`：写入/修改 Conversation（通常不应允许）
- `data:read_resources`：读取资源内容（agents/KB/MCP…）
- `data:write_resources`：写入资源（除 git-backed 流程外）

### 2.4 Secrets（机密）

- `secrets:read`：读取 global settings 中的 secret（必须配合 settings schema；审计必须记录“读取发生”，不记录值）

### 2.5 UI（界面扩展）

- `ui:theme`：提供主题（CSS tokens）
- `ui:outlets`：向 UI outlets 注入内容（Tier 2）
- `ui:admin_pages`：提供 admin 页面（Tier 2）

---

## 3) 与产品侧 permission gate 的关系

capabilities 不能替代 permission gate：

- 插件注册了工具 ≠ 工具默认可执行。
- 工具执行仍需遵守 permission gate（默认需要显式批准）与 Runner policy（deny-by-default；见 `docs/product/behavior_spec.md` 与 `docs/product/sandbox_requirements.md`）。

---

## 4) Open questions

- capabilities 是否需要在 UI 中按“风险等级”聚类（low/medium/high）？
- 是否需要支持 “capability allowlist per Space” 作为 system policy（例如某 Space 禁止任何 sandbox 执行）？
