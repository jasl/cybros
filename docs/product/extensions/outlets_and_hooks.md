# UI 扩展点（Outlets/Hooks）与 Plugin API（Draft）

本文件描述 “类似 Discourse 的插件扩展点” 在 Cybros（Turbo/Stimulus）架构下的建议落点。

目标：

- 不鼓励到处 monkey patch
- 提供稳定的 outlet ids 与 hook contracts
- 能在 safe mode 下绕过

注意：本文件讨论的是 Tier 2（Core plugin）能力；Phase 1/2 可不实现，但需要先把“语义边界”定死。

---

## 1) UI Outlets（视图插槽）

定义：

- core 在关键页面预留 outlet（带稳定 id）。
- 插件可以注册一个或多个 outlet renderers（partial/component）。

规范性倾向：

- outlet id 必须稳定；变更需要迁移期与文档。
- outlet renderer 必须能拿到一个“只读上下文”（space/user/resource ids），避免滥用读取敏感数据。
- safe mode 下必须能完全跳过所有 outlet renderer。

示例（概念，不是实现承诺）：

- `spaces.sidebar.after_nav`
- `conversations.show.header.after_agent`
- `agent_profiles.index.after_shared_list`

---

## 2) Server hooks（服务端扩展点）

建议提供“显式 API”覆盖常见需求：

- 注册工具/skills（Tier 1/2）
- 注册 prompt injection source（Tier 0/2）
- 注册资源模板（Tier 0）
- 注册 admin 页面（Tier 2）
- 注册审计事件类型/解释（Tier 2）

不建议：

- 在 controller/model 上做任意 reopen/alias_method_chain（难以审计与维护）

如果必须允许（Tier 2）：

- 必须要求插件声明 `capabilities` 并在文档标注“可能破坏升级兼容性”。

---

## 3) Client hooks（前端扩展点）

在 Turbo/Stimulus 下的建议：

- Phase 1/2：仅 Theme（CSS tokens），不允许 JS 注入。
- Phase 3+：若允许 JS 扩展，建议：
  - 以固定 “plugin entrypoints” 列表加载（按 plugin_id/version）
  - 插件只能在已声明的 outlet DOM 节点内挂载（限制扩展面）
  - safe mode 下禁用所有插件 entrypoints

---

## 4) Open questions

- outlet 的上下文对象是否需要一套“序列化约束”（只给 id/flags，不给全量对象）？
- 是否需要 “Plugin API 兼容层” 来允许 core 演进而不立刻 break 插件？

