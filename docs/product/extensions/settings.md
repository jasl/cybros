# 插件 Settings（含 Secrets）规范（Draft）

插件必须能以统一方式声明与管理设置，避免“不可运维的黑盒”。

本文件定义：

- 插件 settings schema 的声明格式
- settings 的作用域（system/space/user）
- secrets 的存储与审计原则

---

## 1) 设计原则

- settings 必须是数据（可验证、可迁移、可审计），而不是可执行代码。
- secrets 不允许出现在插件包内；只能由 admin 在系统设置里填写，并加密存储。
- settings 的作用域必须显式（默认 system），避免“看似只影响我，实际影响全局”的事故。

---

## 2) schema 声明（建议：manifest 内或独立文件）

建议允许两种位置（其一即可）：

- `cybros_plugin.yml` 内的 `settings:` 字段
- 独立 `settings.yml` 并在 manifest 中引用

示例：

```yaml
settings:
  - key: "solved_enabled"
    type: "bool"
    scope: "system"
    default: false
    description: "Enable solved workflow"

  - key: "github_token"
    type: "string"
    scope: "system"
    secret: true
    description: "GitHub token used by the plugin"
```

类型集合（建议最小）：

- `bool` / `int` / `float` / `string` / `enum` / `json`

约束（规范性倾向）：

- 对 `json` 必须有 max bytes 限制与结构校验（避免滥用当 KV store）。
- 对 `int/float` 禁止 silent coercion（遵守仓库的 coercion 原则）。

---

## 3) settings 的存储与覆盖规则（建议）

Phase 1 建议最小落点：

- 只支持 `system` scope（满足 self-hosted 运维）。

Phase 2+ 可扩展：

- `space` override：Space admin 可以覆盖部分 settings（必须明确哪些可覆盖）。
- `user` override：只用于纯 UI/体验型设置（避免影响安全边界）。

覆盖优先级（建议）：

`user`（若允许） > `space`（若允许） > `system` > manifest default

---

## 4) secrets（机密）规则（必须明确）

- secrets 只能由 system admin 设置/轮换。
- secrets 的读取必须：
  - 插件声明 `secrets:read` capability
  - core 落审计事件（plugin_id/version + secret key name + timestamp + actor）
- secrets 的值不得进入日志、不得进入事件详情、不得进入 LLM prompt。

---

## 5) Open questions

- 是否需要对 secrets 引入 “break-glass” 流程（强审计 + 临时授权）？
- settings 修改是否需要提供 diff 与回滚（建议：至少 system settings 有审计与历史）？

