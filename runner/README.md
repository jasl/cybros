# Runner（执行面）开发说明

本目录用于承载 Cybros 执行面（Runner）的代码与联调材料。

设计背景与总体方案见：
- `docs/execution/execution_subsystem_design.md`

## 为什么 Runner 需要在仓库内

- Runner 与 Cybros（ExecHub）开发节奏可能不同步，但在同仓库内便于协议联调与回归测试。
- 将来 Runner 可以独立发布（单二进制/安装包/独立仓库），但协议应保持兼容（见设计文档第 15.4 节）。

## 目录约定（建议）

- `runner/mini/`：Mini Runner（开发/回归用，默认只覆盖 Trusted/Host 的最小能力集合）
- `runner/daemon/`：产品级 Runner（目标：支持 Untrusted/microVM、强制网络出口等）
- `runner/protocol/`：协议契约（OpenAPI/JSON schema）与 contract tests（可选）

## 安全提示

- Mini Runner 仅用于开发联调，默认不应启用 Untrusted/microVM，也不应作为生产执行面。
- 任何“强隔离/强网络限制”的能力必须在产品级 Runner 中实现与验证。

