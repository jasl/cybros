# 参考：Discourse 插件系统要点（Notes）

本文件用于记录我们希望向 Discourse 学习的插件系统要点，并给出本仓库的参考入口（`references/discourse`）。

目的不是复制 Discourse 的实现，而是对齐“成熟度”：

- 元数据与兼容性
- 生命周期与运维（safe mode）
- settings 与 admin UI
- UI outlets/hooks

---

## 1) 代码参考入口（本仓库内）

- 插件目录：`references/discourse/plugins/`
- 插件元数据解析：`references/discourse/lib/plugin/metadata.rb`
- 插件实例与注册 API：`references/discourse/lib/plugin/instance.rb`
- Discourse 插件文档索引：`references/discourse/docs/PLUGINS.md`
- 一个典型插件示例：`references/discourse/plugins/discourse-solved/plugin.rb`

---

## 2) 我们要对齐的能力清单（对照项）

建议把以下项作为“是否接近 Discourse”的检查表：

- 插件必须有元数据（id/name/version/authors/url/about）
- 插件必须声明 required core/plugin api 版本，不满足拒绝加载
- 插件启用/禁用可运维（且能 safe mode 止血）
- 插件 settings 有统一 schema，能通过 admin UI 配置（且可审计）
- 插件可以注册资源模板与 UI 扩展点（outlets），并能在 safe mode 下绕过

---

## 3) Cybros 需要比 Discourse 更严格的点

- 执行能力（Runner/工具/网络/文件）带来更大风险面，因此 Tier 1/2 的默认策略必须更保守（deny-by-default + permission gate）。
- Conversation 强隐私：插件系统不能绕过隐私边界（尤其是 Tier 2 插件要把风险写清楚）。

