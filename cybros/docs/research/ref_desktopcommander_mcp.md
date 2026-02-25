# 参考项目调研：Desktop Commander MCP（references/DesktopCommanderMCP）

更新时间：2026-02-24  
调研对象：`references/DesktopCommanderMCP`  
参考版本：`5a4806f`（2026-02-24）

## 1) 项目定位与核心形态

Desktop Commander MCP 是一个面向桌面/本机的 MCP 服务器，提供：

- 文件系统操作（含搜索、替换、ripgrep）
- 终端命令执行与长进程管理（list/kill/session）
- 一些“增强型文档能力”（Excel/PDF 等）
- 全量 tool call 审计日志（自动记录）
- 支持 Docker 部署以获得更强隔离与持久化工作环境

它的核心产品点是：把“本机能力”封装成一个可被 Claude/ChatGPT 等通过 MCP 调用的工具面，并且把“隔离与审计”作为卖点。

## 2) 对 Cybros 的启发（本轮抽取）

- MCP 服务器可以成为 Cybros 的“执行面扩展”：很多能力不必进 core，只要能被 policy/gate 控制即可。
- 长进程/后台任务与审计很关键：coding/automation 任务经常需要 dev server、数据库、下载等长时动作。
- Docker 形态说明：即使是桌面工具，也需要一条“强隔离 + 可重建”的路径，避免把宿主机变成沙箱。

## 3) 风险与建议（怀疑点）

- Desktop 级能力天然高危（文件/进程/网络/凭据）；对 Cybros 来说应当属于高信任 profile（trusted/host），不应作为默认能力。
- 项目的 `SECURITY.md` 明确指出：目录限制/命令阻断等并非 hardened boundary，存在被 symlink/terminal command 等绕过的已知限制；因此 **不能把它当作安全边界**，只能把它当作“方便的执行面实现”，真正的隔离必须依赖 Docker/沙箱挂载边界。
- Excel/PDF 这类“领域能力”更像 skills/插件，而不是平台必备。

建议：

- 把“桌面 MCP”视为 Tier 1 sandbox plugin 或外部 MCP server（由用户显式安装/启用），并与 permission gate 强绑定；
- 对能力做分组与预算（fs/exec/net/process），并把“危险升级”显式化。
