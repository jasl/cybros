# Extensions（插件系统）方案索引（Draft）

本目录用于承载 `docs/product/extensions.md` 的“可实施细化版”：把插件系统从口号落到可执行的规范与资源格式。

目标：达到 **接近 Discourse（见 `references/discourse`）** 的成熟度，但结合 Cybros “可执行平台”的威胁模型做更严格的默认安全策略。

---

## 0) 本方案的边界（先对齐）

- 本方案讨论的是 **插件系统**（安装包式扩展），不是用户日常编辑的 AgentProfile/Workflow。
- 用户日常可变性仍以 git-backed resources 为主（见 `docs/product/versioning_and_sync.md`），插件主要提供：
  - 模板（可 Copy 到 repo 再改）
  - 能力包（工具/skills/连接器）
  -（后续）UI 扩展与 admin 面板
- 本方案不讨论 Runner 侧的软件分发/依赖管理细节；Runner 侧能力优先以 skills/tooling 形态提供，并由执行子系统 policy + permission gate 约束。

---

## 1) 目录结构

- 总览与分层：`docs/product/extensions/plugin_tiers.md`
- 插件清单/manifest 规范：`docs/product/extensions/plugin_manifest.md`
- 生命周期与运维：`docs/product/extensions/lifecycle.md`
- Capabilities 与权限：`docs/product/extensions/capabilities.md`
- Settings（含 secrets）规范：`docs/product/extensions/settings.md`
- Safe mode（止血/排障）：`docs/product/extensions/safe_mode.md`
- UI 扩展点（outlets/hooks）：`docs/product/extensions/outlets_and_hooks.md`
- 安装/分发/升级：`docs/product/extensions/distribution.md`
- Discourse 对照笔记：`docs/product/extensions/ref_discourse.md`
- 示例 manifests：`docs/product/extensions/examples/*`

---

## 2) Phase 1 需要先“定死”的决策（建议按顺序确认）

这些决策不需要立刻实现，但需要在文档里先统一，否则后续实现会反复推倒：

1) 插件分层是否采用 Tier 0/1/2（三层信任等级）？（建议：是）
2) 插件 manifest 是否采用 `cybros_plugin.yml`（YAML）作为唯一来源？（建议：是）
3) 插件安装 scope 是否仅 `global` 与 `space` 两种？（建议：是；`user` scope 先不做）
4) 插件 settings 是否统一进 global settings（并支持 `space` override）？（建议：Phase 1 先 global）
5) Tier 2（core plugins）是否允许存在？（建议：允许，但默认关闭；强调高风险、需要重启、必须 safe mode）
6) Safe mode 是否要有两级：boot-level + request-level？（建议：是）

---

## 3) 本目录的“资源”是什么

这里的资源主要是：

- 规范文档（Markdown）
- YAML 示例（manifest/settings/resources bundle 的例子）

不会包含任何可执行代码或实现细节；实现应由后续单独的工程任务落地。
