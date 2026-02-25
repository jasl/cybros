# 参考项目调研：OpenManus（references/OpenManus）

更新时间：2026-02-24  
调研对象：`references/OpenManus`  
参考版本：`52a13f2`（2026-01-04）

## 1) 项目定位与核心形态

OpenManus 是一个面向“通用 agent（自动化/调研/浏览器）”的开源实现，包含：

- CLI 形态的交互入口
- MCP 运行模式（`run_mcp.py` 等）
- 多 agent flow 的实验入口（`run_flow.py`）
- browser automation 的可选依赖（Playwright）

## 2) 对 Cybros 的启发（有限）

OpenManus 的价值更多在于“验证某类场景能跑起来”的 PoC；对 Cybros 产品层更有价值的部分是提醒我们：

- 自动化/调研场景很容易导致工具与上下文膨胀，需要早做治理（profile/pruning/cost report）
- 多 agent flow 若没有清晰的编排/权限/审计，很难在 Pro 用户场景长期稳定使用

因此它更适合作为“场景样本库”而不是“架构对照”。

