# Deferred Security Concerns（记录用）

本文档用于记录“产品逻辑上已识别、但当前不打算在 Phase 1 顶下来的”安全隐患与建议止损路径。

原则：

- 能记录就先记录，避免“后面才发现但回头代价巨大”。
- 不要求立即实现；但应当对每一条给出**推荐缓解**与**最坏情况**描述，便于后续排期与沟通预期。

---

## 1) Execute 不可回滚（Cowork 默认自动执行）

风险：

- `Execute` 可能造成不可逆后果（删文件、破坏 workspace、跑危险命令、污染依赖、资源消耗攻击）。
- 默认 Cowork 下，标准沙箱动作的 `Execute/Write` 默认自动，会把“误操作/提示注入”的风险从“可选”变成“基线”，必须靠隔离与止损兜底（见 `docs/product/behavior_spec.md` 与 `docs/product/programmable_agents.md`）。

推荐缓解（后续）：

- 默认启用 Cowork 的 **Plan gate**：先出 plan、再开跑（降低误触发概率，但不能替代隔离与止损）。
- 默认 `untrusted` profile + 强隔离（microVM/VM）+ 资源限制（CPU/mem/disk/time/output）。
- workspace 支持快照/重建（即使不能完全回滚，也能快速恢复到可用状态）。
- auto-allow 可选自动过期（时间窗/次数窗），并提供紧急 stop/kill。

最坏情况：

- 用户工作区被破坏，需要手动恢复；若沙箱隔离不足，可能损害宿主机（无法彻底封死）。

---

## 2) Read internet 默认放行 = 数据外传通道

风险：

- 即使 `Read` 只是“抓网页”，LLM 仍可能把敏感片段编码进 URL/query 发往外网。

推荐缓解：

- 引入 Safe Retrieval 契约（仅 HTTP(S)、无自定义 headers/body、SSRF 防护、响应大小与类型上限、可选敏感片段检测、审计不落内容）。
- 关键：把 “Read internet” 从“任意网络能力”收敛为 “read-oriented egress”。

参考规范：

- `docs/product/safe_retrieval.md`

---

## 3) Git repo 安全与一致性（路径穿越 / symlink / 并发）

风险：

- 路径穿越与符号链接可能导致写入 repo 目录之外（若实现不当）。
- 并发 git 操作可能导致 repo 损坏或出现不可预期 HEAD/dirty state。
- 允许高级用户使用 `git worktree`/分支时，服务端如果不固定工作分支与工作树语义，可能出现写错位置或写入失败。

推荐缓解：

- 对 repo 写入做 repo-level 粗锁；并对相对路径做严格规范化与拒绝 symlink escape。
- 服务端固定自己工作的 branch/目录（例如只写 `main` 工作树），并对 dirty state 给出可行动错误。

最坏情况：

- repo 损坏，用户需用 git 手工修复或从历史备份恢复。

---

## 4) Public share link（匿名只读）仍可能扩大泄露面

风险：

- share token 泄露即泄露内容；分享页被爬虫/转发导致不可控传播。

推荐缓解：

- 高熵 token + 一键撤销 +（可选）失效期。
- 分享页与交互页隔离（已写入术语表）；分享页不允许执行/写入。
- 默认不记录访问日志或只做聚合计数（隐私权衡）。

---

## 5) Prompt cache

风险：

- cache 落盘敏感信息；或因 key 维度不充分导致跨语义命中带来泄露。

推荐缓解：

- 默认关闭或对 “secrets/附件/KB 引用/工具结果” 一律不缓存。
- 强 redaction + TTL + 不可枚举 + key 维度包含上下文摘要。

---

## 6) Strict scope（admin 不越权读 user-scope）带来的排障成本

风险：

- 管理员无法直接查看用户内容，排障依赖用户提供信息。

推荐缓解：

- **用户自助 Diagnostic Bundle**（导出诊断包）：
  - 默认仅包含元数据：版本号、error codes、events、turn_ids、tool/task 执行摘要、配置版本（git commit SHAs 或 `config_version`）、日志截断摘要等。
  - 默认不包含 Conversation 内容；如用户需要，可显式勾选“包含对话文本/附件”（可选项）。
  - 全程做 redaction：不导出 secrets。
  - 详见 `docs/product/diagnostics.md`。

说明：

- 诊断包不等于“默认导出聊天记录”；只有用户显式选择包含对话内容时才是 transcript export。
