# Ref: PSM（Persona Selection Model）与“工作流级 persona 切换”

更新时间：2026-02-24

外部参考（非本地 `references/*` 代码）：Anthropic Alignment blog 文章《PSM（Persona Selection Model）》：`https://alignment.anthropic.com/2026/psm/`

本文只记录对产品/工作流设计有用的抽象与启发，不复述原文细节。

---

## 1) 我们从 PSM 里要拿走的“可操作结论”

把它当成一个提醒：

- “助手像一个稳定人格/单一角色”的直觉在工程上很危险；更现实的观点是：模型里存在多种行为模式（persona），推理时会被 prompt、上下文与训练偏置“选出来”。
- 如果 persona 会被上下文强烈影响，那么产品层需要把“当前 persona”变成可见状态，并允许用户纠偏（锁定/切换/撤销），而不是默默漂移。
- persona 不是安全边界：安全必须由执行 policy + permission gate 兜底，而不是靠“更安全的 persona”。

---

## 2) 用工作流实现 PSM-like 行为：推荐方案

我们无法在训练阶段做 persona selection 的偏置，但可以在工作流层显式加入 “Persona Router”：

- 先用一个轻量路由步骤（LLM 分类或规则）选择 `selected_persona_id + confidence`；
- 再用该 persona 生成回答或执行任务（必要时 handoff 到 subagent）；
- 将“是否切换/为什么切换/置信度”写入观测与审计；
- UI 始终显示当前 persona，并允许用户锁定或手动切换。

对应的产品草案规范见：

- `docs/product/persona_switching.md`

---

## 3) 与 Cybros 现有底座的映射

- persona 可以作为 `AgentProfile` 的变体（profile=persona），或作为 system prompt 的一个可替换 section。
- 路由与 handoff 可以落在 `Workflow/Orchestrator`：Presenter/Router 负责选 persona，Specialist 负责执行。
- 重要：persona 切换不应改变 permission gate 与执行侧 policy 的上限（尤其：secrets/host IO/private network）。

