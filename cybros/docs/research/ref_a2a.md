# 参考项目调研：A2A（Agent2Agent Protocol）（references/A2A）

更新时间：2026-02-24  
调研对象：`references/A2A`  
参考版本：`629190a`（2026-02-18）

## 1) 项目定位与核心形态

A2A 是一个面向“agent 与 agent 之间互操作”的开放协议，目标是让不同框架、不同厂商、不同服务器上的 agent 以 agent 的粒度协作，而不是退化成“工具调用”。

从 README 可见的关键点：

- JSON-RPC 2.0 over HTTP(S)
- Agent discovery（Agent Cards）
- 支持同步/流式（SSE）/异步 push 通知
- 支持富数据交换（文本、文件、结构化 JSON）
- 强调安全、认证与可观测（enterprise-ready 的姿态）

## 2) 对 Cybros 的启发：A2A 更像“远端 Specialist 接入层”

对 Cybros 来说，A2A 的合理定位更像：

- 一类可配置 Resource（A2A server endpoint + auth）
- 一组工具组（discover / start_task / stream / get_result / cancel）
- 用来承载“外部 Specialist / Remote agent”与“跨系统协作”

建议：

- Phase 1 只保留边界与资源模型，不做完整生态集成；
- 与 MCP 的关系保持清晰：MCP 扩展工具，A2A 扩展“可委派 agent”。

