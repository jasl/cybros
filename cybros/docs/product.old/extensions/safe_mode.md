# Safe mode（止血/排障）规范（Draft）

插件系统必须提供 safe mode，否则当插件导致页面崩坏或 boot 失败时，运维成本会失控。

本文件定义 safe mode 的最小语义（向 Discourse 的可运维性对齐）。

---

## 1) 两级 safe mode（建议）

### 1.1 Boot-level safe mode（实例级）

目的：

- 当 Tier 2 插件导致启动失败时，仍能把系统拉起来进入 admin 界面禁用插件。

建议形态：

- 环境变量：`CYBROS_SAFE_MODE=1`

建议行为：

- 不加载任何 Tier 2（core）插件代码
- 可选：不加载任何 Tier 1（sandbox）注册（保守）
- 仅保留内置功能 + Tier 0 模板（也可全部禁用，取决于“恢复优先”还是“功能优先”）

### 1.2 Request-level safe mode（请求级）

目的：

- 当某个用户界面因为主题/前端扩展崩坏时，可在不重启的情况下绕过扩展进行排障。

建议形态：

- query param：`?safe_mode=1`（或 cookie）

建议行为：

- 禁用主题与任何前端扩展注入（CSS/JS/outlets）
- UI 显示 “safe mode” 横幅（避免用户误以为功能缺失）

---

## 2) 审计与可见性

规范性倾向：

- boot-level safe mode 的启用应在启动日志中醒目提示，并落一条 system event（如果系统能启动到可写 DB）。
- request-level safe mode 只影响当前请求/用户，不需要系统审计，但需要 UI 可见提示。

---

## 3) Open questions

- request-level safe mode 是否需要支持“仅禁用 themes”“禁用所有 UI outlets”等细粒度选项？
- safe mode 下是否仍允许执行 sandbox tools？（默认建议：允许，但仍走 permission gate）

