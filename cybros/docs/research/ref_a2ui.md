# 参考项目调研：A2UI（Agent-to-User Interface）（references/A2UI）

更新时间：2026-02-24  
调研对象：`references/A2UI`  
参考版本：`407848c`（2026-02-20）

## 1) 项目定位与核心形态

A2UI 提供一个 “agent → UI” 的声明式 JSON 格式与多端 renderer 思路，核心主张是：

- **安全像数据**：agent 不输出可执行代码；客户端只渲染“组件目录（catalog）”里的白名单组件
- **表达像代码**：可组合、可更新、可交互（事件/数据绑定）
- **LLM 友好**：用扁平组件列表 + ID 引用，便于增量更新与渐进式渲染

## 2) 对 Cybros 的启发：把 UI 当作“协议”，而不是“prompt 技巧”

如果 Cybros 要做 agent-driven UI，A2UI 的思路可以直接映射为：

- DAG 节点输出支持一种结构化 payload（A2UI JSON）
- WebUI renderer 负责把 payload 映射为本地组件（白名单）
- 事件回传以“结构化 user_message/interaction event”进入 DAG（而不是把 DOM 事件塞回 prompt）

## 3) 风险与建议（怀疑点）

- A2UI 很容易把 Phase 1 重心拖到“组件系统/渲染器/事件绑定”，影响任务闭环落地速度。
- 需要防 UI 层面的 social engineering：即使是白名单组件，也可能被组合成误导性审批界面。

建议：

- Phase 1 先把“审批卡/日志/工件/diff”这些刚需结构化 UI 做好；
- A2UI 作为 Phase 2+ 可插拔协议引入，并且：
  - 默认严格白名单 + 属性校验
  - 与权限模型强绑定（例如审批 UI 永远由 core 渲染，禁止由 A2UI 伪造）

