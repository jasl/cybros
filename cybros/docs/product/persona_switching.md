# Persona switching（工作流级别，Draft）

动机：你提到的 PSM（Persona Selection Model）把“助手行为”理解为模型在多种 persona 之间做选择与条件化；我们无法在训练阶段直接支持，但可以在**工作流层**把 persona 选择显式化、可配置化、可观测化，并把安全边界留在产品/执行 policy 中（而不是交给 persona）。

本文件定义：

- persona 的产品语义（它是什么 / 不是什么）
- 基于用户输入的 persona 选择（路由）工作流
- UI 与审计/观测要求
- 主要隐患与止损策略

---

## 1) Persona 的语义（建议）

### 1.1 Persona 是什么

在 Cybros 里，persona 建议被建模为一种“可切换的 **对话行为配置**”，通常由以下几类要素组成：

- **风格与姿态**：语气、偏好、解释深度、是否更偏“问诊式澄清/直接执行/教学式输出”等。
- **任务策略**：更偏规划/更偏迭代/更偏检索；以及对确定性/可验证性的默认偏好。
- **工具与资源选择倾向**：默认更常用哪些 tools/skills/MCP（注意：这不是权限授予）。
- **模型偏好**：例如 `prefer_models`、以及特定 persona 选择更强/更快/更便宜模型的策略。

建议把 persona 作为 `AgentProfile` 的一个维度（例如 profile 本身就是 persona），或把 persona 作为可组合的 prompt section（“Persona section”）注入到 system prompt 中。

### 1.2 Persona 不是权限

persona **不**应当改变以下安全边界：

- permission gate 的默认策略（见 `docs/product/behavior_spec.md`；persona 不应影响 Cowork/Manual/Evolution 状态与任何 auto-allow 开关）
- 执行侧 policy 的上限（host IO、secrets、私网/unrestricted network 等危险能力仍需显式授予）
- Safe Retrieval 契约（Read internet 只能走 safe retrieval）
- 不应触发“无人值守/自改”等信任阶梯升级（Cowork/Evolution 必须是用户显式动作，见 `docs/product/programmable_agents.md`）

换句话说：persona 可以改变“怎么做”，但不能改变“允许做什么”。

---

## 2) Persona Router：基于用户输入的切换工作流（推荐）

### 2.1 最小工作流（单步路由）

在每个 turn 开始时，先运行一个轻量 “Persona Router” 阶段：

输入（建议最小）：

- 最新用户消息
- 当前 persona（若有）
-（可选）最近 N turns 的摘要/标签（避免上下文膨胀）

输出（结构化，建议字段）：

- `selected_persona_id`
- `confidence`（0..1）
- `reason`（短字符串，给人看）
- `sticky_for_turns`（可选：建议保持多少 turns，避免来回抖动）
- `required_tool_groups`（可选：router 认为需要的工具组；仅用于提示与 UI 预告）

路由规则（建议）：

- **显式指令优先**：用户说“切换到 X”时直接切。
- **高置信自动切**：`confidence >= threshold` 且不会造成“明显的能力表象升级”（见 2.3）时自动切。
- **低置信不切**：保持当前 persona，仅把 router 输出记入观测，避免“随机变脸”。

### 2.2 实现方式（两种都可）

1) **LLM 路由**（推荐，需 strict schema）：
   - 用一个更小/更便宜的模型做分类与路由（不使用工具）。
   - 输出必须通过 schema validation；失败时 fallback 到当前 persona。

2) **规则路由**（MVP 或 safety-first）：
   - 关键词/正则/频道来源（例如 IM bot）/URL 类型等规则判断。
   - 规则可被 LLM 建议，但写入规则集必须走 Write permission gate（git-backed）。

### 2.3 “能力表象升级”与 UI 提示（建议）

即使 persona 不授予权限，切换 persona 仍可能改变工具可见性与模型行为，导致用户感知到“它突然更想执行/更想联网/更像另一个人”。

建议在以下情况对用户做显式提示（不一定要 ask，但要可见）：

- persona 切换导致可见工具组从 “无执行” → “有执行”
- persona 切换导致默认启用更多 MCP/skills（尤其是网络相关）
- persona 切换导致模型从“便宜/快” → “昂贵/慢”或相反（成本/质量预期变化）

提示的目标是：**可解释**，而不是“安全审批”。

---

## 3) 状态模型与落点（建议）

### 3.1 Conversation-level state

建议把 “当前 persona” 作为 conversation 的运行时状态（metadata），而不是写回资源配置：

- persona 的选择是“本会话状态”，默认不产生 git commit。
- 只有当用户显式要求“把自动路由策略/默认 persona 写成配置”时，才会变成 git-backed 写入（走 Write ask）。

### 3.2 DAG 记录（可观测/可审计）

建议在 DAG/Events 中记录：

- 每次 persona 路由的输出（至少 `selected_persona_id/confidence/reason`）
- 是否发生 persona 切换（from/to）
- 切换原因（user requested / auto / manual override）

这为后续评估 “路由是否靠谱” 提供数据基础。

---

## 4) 与 Subagent/Teams 的关系（可选增强）

persona 切换有两种产品形态：

1) **同一会话内切 persona**：适合连续对话体验，状态简单。
2) **Handoff 到 subagent**：当某 persona 代表一种“专家执行器”（例如 coding、ops、research）时，可把它作为子图执行：
   - 主线（Presenter/Router）负责选择 persona + 约束
   - 子图（Specialist persona）负责执行与产出
   - 产出以摘要/结果回到主线，避免上下文爆炸

建议先做 (1)，再按需要把 (2) 产品化。

---

## 5) 主要隐患与止损

- **抖动/不一致**：persona 在相近输入上反复切换 → 引入 stickiness/hysteresis，并允许用户 “锁定 persona”。
- **提示注入诱导切换**：攻击者诱导切到更“听话/更敢执行”的 persona → router 对来源/上下文做约束；同时权限仍由 gate 控制。
- **把安全寄托在 persona**：试图通过 persona 来“更安全” → 反模式；安全必须由 policy + gate 承担。
- **记忆污染**：不同 persona 写入同一长期记忆导致风格/偏好混乱 → memory entry 打 `persona_id` tag，检索时按需过滤（可选）。

---

## 6) Open questions

- persona 的最小集合怎么定？（3-5 个够用 vs 过多导致选择困难）
- persona 选择是否应当受 “用户显式偏好/禁用项” 约束？（例如用户禁用某 persona）
- persona 与 `prefer_models`、token budget、工具预算之间的优先级如何定义？
