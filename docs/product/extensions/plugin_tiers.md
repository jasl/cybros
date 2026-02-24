# 插件分层（Tiers）与信任模型（Draft）

本文件把插件系统按“信任等级”分层（而不是按“有没有代码”），并规定每层允许的能力边界。

核心动机：Cybros 是可执行平台，插件的威胁模型比传统内容网站更接近“自动化/部署平台”。因此必须把大多数扩展收敛到低信任层。

---

## Tier 0：Content Plugin（内容插件）

定义：

- 只包含声明式资源（模板/预设），不包含任何可执行代码。

允许内容：

- AgentProfile / PromptBuilder / Workflow 的模板（只读）
- Tools/MCP/KB 的预设配置（不含 secrets）
- 文档、示例对话、评测用例（可选）

禁止：

- 任意 Ruby/JS 执行
- HTML 注入（避免内容插件变成 XSS 载体）
- 读取/写入用户对话内容

典型交付方式：

- 用户在 UI 里 “Copy to repo” 把模板写入 user/space git repo（产生 commit + 审计），之后的修改属于用户资源，不再属于插件。

---

## Tier 1：Sandbox Plugin（沙箱插件）

定义：

- 包含可执行代码，但只能作为 tools/skills 在 Runner/沙箱中执行（不在 Rails 进程内执行）。

允许内容：

- 技能包（脚本/二进制/容器任务）+ 对应的 tool schema
- 连接器/采集器（仍以“沙箱任务”方式运行）

安全约束（规范性倾向）：

- 依赖 ExecHub/Runner policy（deny-by-default：网络/文件/环境变量等）
- 任何危险调用仍需要产品侧 permission gate + 审计（默认 ConfirmAll）

备注：

- Tier 1 的价值是“扩展执行能力”，但它不提供“服务端任意执行”。

---

## Tier 2：Core Plugin（核心插件）

定义：

- 插件代码在 Rails 进程/前端主 bundle 中运行（类似 Discourse plugins），可以修改服务端行为或注入 UI。

风险与限制：

- **没有真正的安全隔离**：Tier 2 等价于给插件作者与基座同等权限。
- 仅 system admin 可安装；必须明确声明 capabilities；必须有 safe mode 止血路径。
- 建议只允许在“构建/部署阶段”安装并要求重启（避免热加载造成不可预测状态）。

允许（示例）：

- Admin UI 页面
- 新的资源类型/数据模型（极少数场景）
- 高度耦合产品行为的扩展（谨慎）

---

## Theme（主题，弱扩展）

定位：

- 比 Tier 2 更弱的 UI 扩展形态，尽量只影响样式与布局。

Phase 建议：

- Phase 1/2：只允许 CSS variables + DaisyUI theme tokens。
- Phase 3+：如果引入模板 outlets，则主题的能力需要重新评估（可能会与 Tier 2 边界重叠）。

