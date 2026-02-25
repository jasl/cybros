# 参考项目调研：Pi-Mono / Pi Coding Agent（references/pi-mono）

更新时间：2026-02-24  
调研对象：`references/pi-mono`（重点：`packages/coding-agent`）  
参考版本：`380236a0`（2026-02-23）

## 1) 项目定位与核心形态

Pi（Pi Coding Agent）是一个“最小 terminal coding harness”，核心主张是：

- 默认只给模型四个工具：`read` / `write` / `edit` / `bash`
- 不把计划模式、subagent、复杂编排写死进核心；而是鼓励用 **Skills / Extensions / Prompt Templates / Themes** 扩展
- 既可交互使用，也支持 JSON 输出、RPC 集成与 SDK 嵌入

对 Cybros：Pi 的价值不在于“又一个 agent”，而在于它把“可编程 agent 的最小原语 + 可扩展包系统 + 运行模式”做成了非常清晰的产品语义。

## 2) 会话与上下文：JSONL tree + branching + compaction

Pi 的 sessions 以 JSONL 存储，并显式支持 tree/branching：

- `/tree` 在单文件内跳转到历史节点继续（in-place branching）
- `/fork` 从当前分支切出新的 session 文件
- compaction 支持手动与自动；完整历史保留在 JSONL（压缩只影响“继续工作所需上下文”）

对 Cybros：

- DAG 天然能表达 branch/compaction（比“JSONL tree”更一般），但 Pi 的 UI 操作（tree/fork/label）很值得借鉴为“Pro 用户可控分支”体验。

## 3) Customization：按需扩展，而不是 prompt 膨胀

Pi 把可变性拆成几类正交组件：

- **Context files**：启动时加载 `AGENTS.md` / `CLAUDE.md`（向上查找 + 合并）
- **Prompt templates**：可复用的 prompt 片段（更偏“文本层”）
- **Skills**：可复用工作流（通常伴随脚本/模板），用于把重复程序外移出 prompt
- **Extensions**：可提供自定义 UI、命令、甚至替换编辑器（更偏“产品扩展点”）
- **Themes**：UI 主题（体验层）

对 Cybros：

- “工具与技能膨胀”是普遍问题；Pi 的拆分方式可以直接映射为：
  - git-backed resources（模板/技能/工作流）
  - 插件系统（分发与生命周期）
  - prompt injection（context files）

## 4) 对 Cybros 的可落地启发（本轮抽取）

- **少工具更稳**：优先把平台能力收敛为少量原语（读/写/编辑/执行），把其它能力编译为 skills/工具组（见 `docs/product/programmable_agents.md`）。
- **“运行模式”是产品语义**：交互/JSON/RPC/SDK 对应不同集成形态；Cybros 可以把这些形态映射到“UI/客户端适配层”，而不是把它们写进引擎层。
- **分支与压缩要可操作**：DAG 有能力，但需要 UI 把它变成用户可用的“树视图/回溯/分叉/标签/导出”。

