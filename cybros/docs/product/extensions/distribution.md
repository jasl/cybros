# 安装/分发/升级（Sources & Packaging）规范（Draft）

本文件定义插件的分发与安装来源（source），以满足 self-hosted 的现实：

- 需要离线/内网部署
- 需要可回滚
- 需要可审计

---

## 1) Sources（安装来源）

建议支持三种 source（至少支持一种即可起步）：

1) **Local directory**：本地目录（开发体验最佳；类似 Discourse `plugins/<id>`）
2) **Git repository**：git clone 到 persistent volume（可 pin commit；易升级/回滚）
3) **Archive**：zip/tar 包（离线分发；适合 air-gapped）

规范性倾向：

- 安装记录必须保存 “source + pin”（path / repo url + commit / archive hash），否则无法可靠回滚。

---

## 2) 升级与回滚策略

- Tier 0/1：尽量支持运行时升级（不重启），失败则自动降级为 disabled + 告警。
- Tier 2：建议仅在构建/部署阶段升级，并要求重启；支持 pin 回滚到旧版本再重启恢复。

---

## 3) 存储位置（建议）

建议把插件源码放在 persistent volume 下（便于容器升级不丢失）：

- global install scope：`storage/cybros/plugins/global/<plugin_id>/...`
- space install scope：`storage/cybros/plugins/spaces/<space_id>/<plugin_id>/...`

备注：

- 这只是建议目录约定，实际实现可以调整；关键是“可持久化 + 可审计 + 可回滚”。

---

## 4) Open questions

- 是否需要插件签名校验？如果需要，最小形态是 “hash pin + allowlist” 还是 “签名证书链”？
- 对 Tier 2 插件是否需要强制 “官方/可信列表” 才允许启用？
