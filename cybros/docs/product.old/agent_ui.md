# Agent UI / App mode（Agent 驱动 UI，Draft）

动机：当我们把产品默认设为 Cowork（无人值守连续执行），单纯聊天会很快遇到瓶颈：

- 权限审批需要结构化 UI（否则容易误解/误点）
- 问卷/表单/数据收集用纯文本效率很低
- 仪表板/可视化/进度与工件管理需要比“长文本输出”更可读
- 进一步的野心：提供一个 **App mode**，让 Agent 引导用户完成一个过去得写 APP 才能完成的流程（例如一个简单的星座占卜小应用）

本文档定义“Agent 生成 UI”的产品语义与安全边界，参考 A2UI 的核心理念：**安全像数据，表达像代码**。

阶段性结论（已确定）：

- 先把 Cowork（默认无人值守）与 Evolution（自改）能力闭环做稳，再开始投入 Agent UI / App mode。
- Agent UI 的第一阶段目标：**结构化表单/问卷 + 只读仪表板**；mini-app 放到后面。
- 真正实现时建议对齐 A2UI（而不是自造一套不兼容协议），但 A2UI 本身较新，需要实际评估其表达力与渲染成本。

---

## 1) 边界：哪些 UI 绝不能由 Agent 生成

规范性要求（必须写死）：

- **权限审批 UI 必须由 core 渲染**（permission gate / approve/reject/auto-allow 等）。
- Agent 生成的 UI 必须被明显标记为 “Agent UI”，且不得伪装成系统对话框。
- Agent UI 不得直接触发危险能力升级（例如开启 secrets / unrestricted network / host IO）。

原因：避免 UI spoofing（社会工程），这在“可点击 UI”里比纯文本更危险。

---

## 2) 最小可用能力：结构化表单 + 只读仪表板

Phase 1/2 的最小组件目录（建议）：

- 表单：文本输入、选择器（enum）、开关、数字输入、日期/时间
- 只读展示：表格（table）、键值列表（kv）、步骤列表（steps）、状态徽章（status）
- 可视化（可选起步）：简单图表（line/bar/pie）或把图渲染成图片附件（更稳）

交互模型：

- Agent 发送一个 `ui_payload`（声明式 JSON）
- 客户端用白名单组件渲染
- 用户交互被回传为结构化事件（成为一个 `user_message` 的 payload）

---

## 3) A2UI 路线（建议）：把 UI 当作协议

建议在产品层把“Agent UI”抽象成一个协议层，并在实现时 **优先对齐 A2UI**（必要时先做 A2UI 的子集）：

- 组件必须来自 catalog（白名单）
- 属性必须校验（schema）
- 事件必须有明确类型（submit/click/change），并绑定到某个 `ui_context_id`
- 支持增量更新（同一 UI 的 patch/update），便于渐进式渲染

落点建议：

- DAG 节点输出携带 `ui_payload`（不会进入 LLM prompt）
- UI renderer 与业务逻辑解耦：renderer 只负责渲染与回传事件

---

## 4) App mode：两条实现路径（建议并存，但要分阶段）

### 4.1 In-chat declarative UI（A2UI）

适合：

- 表单、审批前问卷、仪表板、轻量交互

优点：

- 安全边界清晰（白名单组件）
- 不需要在沙箱跑一个前端应用

限制：

- 不适合复杂交互/游戏（组件目录会膨胀）

### 4.2 Mini-app in sandbox（嵌入式 web app）

适合：

- 你提到的“星座占卜游戏”这种更像小应用的交互

形态（建议）：

- Agent 在 project/scratch workspace 生成一个静态 web app（HTML/CSS/JS）
- Runner 启动一个只绑定在 workspace 的本地预览服务
- WebUI 以受限 iframe/embed 方式展示（与主站隔离 origin、禁用危险权限）

关键约束：

- 必须清晰区分 “系统 UI” 与 “沙箱应用 UI”
- mini-app 的网络能力与文件能力必须受 sandbox policy 约束（默认 NET=NONE）

---

## 5) Open questions

- A2UI 对齐策略：我们是直接实现 A2UI v0.x 的 renderer，还是先实现 “A2UI 子集 + 明确迁移策略”？
- UI payload 的版本与兼容策略怎么定？（catalog 变更如何迁移）
- 可视化优先走“原生图表组件”还是“图片附件渲染”？（前者更交互，后者更稳）
