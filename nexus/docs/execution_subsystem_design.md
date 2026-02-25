# Cybros Execution Subsystem（Mothership + Nexus）设计方案（v0.6）

> **本文件已拆分为 [`docs/design/`](design/README.md) 下的 7 个主题文件，此处仅保留索引。**

## 目标

为 Cybros 提供"在本地/远程主机的隔离环境中执行操作（编辑修改文件、运行命令、收集信息）"的基础设施。

控制面（Mothership，Rails 8.1）部署在云端；执行面（Nexus，Go 单二进制）位于用户主机，通过 Pull 模式与控制面通信。

## 版本历史

- **v0.6** (2026-02-22)：平台要求定稿，Nexus 采用 Go，microVM 基线策略定稿，网络策略四档 preset，DirectiveSpec.capabilities.net JSON Schema V1 冻结，Secrets 边界拆分

## 目录索引

| 文件 | 对应章节 | 主题 |
|------|----------|------|
| [00_overview.md](design/00_overview.md) | §0-2 | 范围、原则、平台要求、语言策略、运行时制品、需求清单、威胁模型 |
| [01_architecture.md](design/01_architecture.md) | §3-4 | 总体架构、Monolith 组织、数据模型（Territory/Facility/Directive/Policy） |
| [02_security_profiles.md](design/02_security_profiles.md) | §5-6 | 执行 Profile（Untrusted/Trusted/Host/darwin-automation）、Nexus 注册与 mTLS |
| [03_network_filesystem.md](design/03_network_filesystem.md) | §7-8 | 网络 Egress 策略、allowlist、代理实现、审计、文件系统与 IO 控制 |
| [04_protocol_reliability.md](design/04_protocol_reliability.md) | §9-10 | DirectiveSpec 协议、可靠性清单（NAT/Lease/日志/凭据/Secrets） |
| [05_deployment_roadmap.md](design/05_deployment_roadmap.md) | §11-14 | 部署形态、安装分发、AgentCore 集成、路线图（Phase 0-6） |
| [06_operations.md](design/06_operations.md) | §15-22 | API 草案、调度与资源、UX 规则、Monorepo 组织、主机能力标注、Provisioning、监控、踩坑清单 |
| [07_reference_analysis.md](design/07_reference_analysis.md) | 附录 | 10 个开源 Agent 项目 + Claude.app 对比分析 |

## 协议 Schema

- [conduits_api_openapi.yaml](protocol/conduits_api_openapi.yaml) — Conduits API OpenAPI 规范
- [directivespec_capabilities_net.schema.v1.json](protocol/directivespec_capabilities_net.schema.v1.json) — 网络能力 JSON Schema（V1，已冻结）

## 实现计划

- [implementation_plan.md](implementation_plan.md) — 实施计划与阶段交付物
