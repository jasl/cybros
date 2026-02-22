# Mini Runner（开发/回归用）

Mini Runner 的目标是：在 ExecHub（Cybros Monolith 内部模块）尚未完全成熟、或缺少 microVM/复杂网络能力的环境下，仍然能推进主流程开发与联调。

## 设计边界

- 仅覆盖最小能力集：enroll/poll/lease、执行命令、上传日志/工件、workspace 锁。
- 默认只支持 `Trusted` 或 `Host`（开发机）场景。
- 不提供 Untrusted/microVM 的强隔离能力（该能力只在产品级 Runner 实现）。

## 运行与联调

待 ExecHub API 具体落地后，本目录会补充：
- 配置格式（EXECHUB_URL、enroll token、证书等）
- 启动命令
- 本地开发（compose/bare-metal）联调步骤

协议语义与端点草案请先参考设计文档第 15 节。
