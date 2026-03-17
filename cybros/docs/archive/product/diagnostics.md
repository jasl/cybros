# Diagnostics（可观测 + 可排障 + 可导出，Draft）

动机：当我们引入 Cowork、可编程 Agent、prompt programs、git-backed 资源后，“能跑”不够，必须让 Pro 用户能：

- 快速判断“现在用的是哪一版 agent/workflow/prompt program”
- 快速定位“为什么它突然变怪/变慢/工具调用崩坏”
- 在不泄露隐私/不交出 secrets 的前提下，把问题打包给自己或他人排查
- 在 IM 渠道里也能自救（`/sos`，见 `docs/product/channels.md`）

本文件定义产品层的 Diagnostics 目标与最小功能面。

---

## 1) 诊断面板（Conversation-level，建议）

每个 Conversation 建议提供一个“诊断面板”（WebUI），展示 **不依赖对话内容** 的关键元数据：

- **配置版本**：
  - `agent_id` + `agent_version`（优先 git commit SHA；否则 `config_version`；system 内置用 `system_version`）
  - `workflow_id` + `workflow_version`（同上）
  - `prompt_builder_kind` / `prompt_builder_version`（同上；见 `docs/product/observability.md`）
- **权限/模式**：
  - 当前模式（Manual/Cowork/Evolution）
  - enabled_tools（实际可见工具子集）
  - budgets（token/timeout/output/context/tool budgets）
  - sandbox policy snapshot（NET/FS/secrets）
  - permission rules（space-level + conversation-level；含 allow/ask/deny 的有效列表与最近变更，见 `docs/product/behavior_spec.md` 6.1.2）
- **执行摘要**：
  - 最近 N 次 tool call：成功/失败、稳定错误码、耗时、重试次数
  - 关键 gate 事件：Plan gate 是否通过、permission requests 通过/拒绝
- **成本与性能**：
  - tokens（input/output/cache）
  - latency 分解（LLM vs tools vs prompt builder）

规范性要求：

- Diagnostics 不应要求用户复制日志；应该“点开即看”。
- 任何“版本/权限/预算”的信息都必须可追溯到事件与存储记录（避免 UI 自己算错）。

---

## 2) Context cost report（建议）

对“自我演进/可编程 prompt building”来说，最常见的退化是：context 膨胀与注入失控。

建议提供一个 Context cost report（不含敏感内容）：

- 总 context tokens（以及上限）
- 分解：system/developer/persona/history/tool results/KB excerpts/memory/facts
- 最大的若干 section（按 tokens 排序）
-（可选）本次 prompt builder 的 `debug.section_breakdown`（见 `docs/product/prompt_programs.md`）

目标：让用户能回答“是 memory 检索太多？还是 KB 引用太大？还是 workflow 写坏了？”。

---

## 3) Diagnostic bundle（导出诊断包，规范性倾向）

对应 `docs/product/security_concerns.md` 6) 的建议，提供一个“用户自助 Diagnostic bundle 导出”能力：

默认包含（建议）：

- Cybros 版本号、核心配置摘要（不含 secrets）
- 目标 Conversation / Runs 的元数据与事件（Events）
- 工具调用摘要（tool name + result code + latency + retries）
- agent/workflow/prompt builder 的版本信息（优先 git commit SHAs；否则 `config_version`）
- 关键错误的稳定 error codes + safe details

可选项（用户显式勾选才包含）：

- Conversation transcript（对话文本）
- 附件（按大小上限）
- tool outputs（默认仅摘要；全文需额外确认）

红线（规范性要求）：

- 永不导出 secrets（即使用户勾选 transcript，也必须做 redaction/扫描）。
- bundle 必须有体积上限与截断策略（避免导出一个巨型 zip 把自己卡死）。

---

## 4) “安全模式”与快速自救入口（建议）

Diagnostics 必须和救援机制联动：

- WebUI：Conversation header 常驻 `Rescue` 按钮（见 `docs/product/channels.md` 5）。
- IM：`/sos` 命令永远由系统拦截（不进 LLM），并提供：
  - switch builtin agent
  - disable prompt_program
  - revert last agent repo change（git 若可用）
  - stop running tasks

---

## 5) Open questions

- Diagnostic bundle 的默认格式：zip(JSON+txt) 还是单一 JSON？是否需要一个“可导入回放”的格式？
- tool outputs 的 redaction 规则如何做得足够安全但仍可排障？
- Context cost report 是否需要支持“对比上一次”（diff），以定位某次变更导致的膨胀？
