# 插件 Manifest（`cybros_plugin.yml`）规范（Draft）

本文件定义插件包的“唯一事实来源”：`cybros_plugin.yml`。

目标：

- 让插件可安装、可审计、可升级/回滚
- 让 core 能在加载前做兼容性检查（避免升级即崩）
- 让风险可见（capabilities）并可被策略约束

说明：本文件是规范草案，字段可演进，但 **必须版本化**（`plugin_api`）。

---

## 1) 文件位置与约定

- 插件根目录必须包含 `cybros_plugin.yml`。
- 插件 id 作为全局唯一标识（建议 slug 风格：`discourse-solved` / `cybros-git`）。

---

## 2) 最小字段（MVP）

```yaml
id: cybros-example
name: "Cybros Example"
version: "0.1.0"
tier: content # content | sandbox | core | theme

required:
  cybros: ">=0.1.0 <0.2.0"
  plugin_api: ">=0.1.0 <0.2.0"

about: "Short description"
authors:
  - name: "Your Name"
    email: "you@example.com"
url: "https://example.com"

scopes:
  install: ["system", "space"] # 哪些 scope 允许安装
  default_install_scope: "space" # 可选：UI 默认值

capabilities:
  - "resources:templates"

resources:
  templates:
    - type: agent_profile
      id: "coding-main"
      path: "resources/agents/main.yml"
      delivery: "copy_to_repo" # copy_to_repo | read_only（注意：这不是 Resource 的 visibility=scoped/public）
```

约束（规范性倾向）：

- `version` 使用 SemVer。
- `required.cybros` 与 `required.plugin_api` 必须同时存在（双约束）。
- `tier` 决定插件可包含的目录与加载方式（见 `docs/product/extensions/plugin_tiers.md`）。

---

## 3) capabilities（能力声明）

capabilities 的作用：

- 在安装/启用时向 admin 明示风险与权限边界
- 让 core 可以拒绝加载不被允许的能力（例如 policy 不允许 core plugins）
- 在审计/可观测性中用 plugin_id/version 归因

capabilities 的规范与建议清单见：`docs/product/extensions/capabilities.md`。

---

## 4) settings（插件设置声明）

插件可以声明 settings schema，但 **不能携带 secrets 的值**。

settings 规范见：`docs/product/extensions/settings.md`。

---

## 5) 允许的目录（按 tier）

建议约束（便于实现与审阅）：

- Tier 0（content）：只能使用 `resources/` + `cybros_plugin.yml`
- Tier 1（sandbox）：允许 `skills/`（以及其引用的容器镜像/脚本），但仍必须通过 Runner 执行
- Tier 2（core）：允许 `server/`、`client/`、`migrations/` 等（高风险）

---

## 6) Open questions

- 是否允许插件声明依赖其它插件（`depends_on`）？如果允许，依赖解析与循环检测如何处理？
- 插件的签名/校验（supply chain）何时引入？最小形态是 hash pin 还是 GPG/签名证书？
