# 插件生命周期（install/enable/upgrade/rollback）规范（Draft）

本文件定义插件的生命周期操作与状态机，目标是“像 Discourse 一样可运维”，并为后续实现提供稳定语义。

---

## 1) 状态机（建议）

对每个 install scope（global 或某个 space）都应独立记录一份状态：

- `uninstalled`
- `installed_disabled`
- `enabled`
- `disabled`（已安装但禁用；与 `installed_disabled` 可合并）
- `broken`（加载失败/兼容性不满足/升级失败，自动降级到 disabled + 告警）

备注：

- Tier 2（Core plugin）可能需要 “installed_requires_restart” 这类中间态，但可以实现时再引入。

---

## 2) 操作语义（规范性倾向）

### install

- 从 source 获取插件内容（local/git/archive）。
- 解析 `cybros_plugin.yml`。
- 校验 `required.cybros` 与 `required.plugin_api`；不满足则拒绝。
- 记录审计事件（scope、source、plugin_id、version、actor）。
- 默认状态：`installed_disabled`（让 admin 明确启用）。

### enable

- 再次校验兼容性与依赖（若实现 `depends_on`）。
- 按 tier 执行启用动作：
  - Tier 0：使模板在 UI 可见。
  - Tier 1：注册 tools/skills（但不改变默认 permission gate）。
  - Tier 2：启用 hooks/outlets；若需要重启则进入 “requires_restart”。
- 记录审计事件。

### disable

- 反向撤销启用动作（尽量不破坏数据）。
- 记录审计事件。

### upgrade

- 获取新版本（source 更新）。
- 兼容性校验，失败则拒绝或进入 `broken`（按策略）。
- Tier 0/1：尽量支持无重启升级；Tier 2：建议要求重启。
- 记录审计事件（from_version → to_version）。

### rollback

- 回滚到某个历史版本（需要 source 支持 pinned commit 或 archive）。
- 记录审计事件。

---

## 3) 失败策略（必须明确）

规范性要求：

- 插件升级失败不能把系统留在半启用状态。
- 插件加载失败必须有止血路径：
  - boot-level safe mode（跳过加载）
  - UI/admin 中一键 disable

---

## 4) 与 git-backed resources 的关系（避免冲突）

- 插件升级不会自动改写用户 repo。
- 若支持 “install-to-repo”，必须以显式操作触发；若目标 repo 启用 git，应产生 commit 以便回滚；升级需要“合并策略”而不是隐式覆盖。

---

## 5) Open questions

- Tier 2 插件的 migrations 是否允许？如果允许，rollback 怎么保证（是否必须可逆）？
- enable/disable 是否需要做到 request-level（用户级 safe mode）还是只做全局？
