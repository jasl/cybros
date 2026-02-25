# 扩展与插件系统（Draft）

本文档定义 Cybros 的 “不可变基座 + 可扩展” 策略，并把插件系统设计到 **接近 Discourse（见 `references/discourse`）的成熟度**：

- 有明确的插件类型与能力边界
- 有安装/启用/禁用/升级/回滚的生命周期
- 有兼容性声明与稳定的扩展 API
- 有默认安全策略、审计与故障隔离（至少是“可快速禁用/恢复”）

本文档是产品层的规范草案；不承诺本阶段全部落地（落地节奏见最后的 Phase 切片）。

细化规范与资源格式见：`docs/product/extensions/README.md`。

---

## 0) 目标与非目标

目标（必须同时成立）：

- **Upstream-first**：用户不直接改主程序；通过升级获得功能与安全修复。
- **可扩展**：系统可以被“安装包”式扩展，而不是靠 fork/patch。
- **正交**：插件与 Space/User/Resource scope 模型不打架（见 `docs/product/tenancy_and_isolation.md`）。
- **可运维**：出现问题能快速定位与止血（禁用插件 / safe mode / 审计）。

非目标（刻意不做）：

- 不把插件系统当成“用户自定义 Agents 的主要入口”。用户自定义主要走 git-backed 资源（见 `docs/product/versioning_and_sync.md`）。
- 不承诺“第三方插件是安全的”。插件 = 代码/内容供应链问题，必须把信任边界说清楚。
- 不在本文件讨论 Runner 侧的软件分发/依赖管理细节（例如预装策略、镜像治理）。Runner 侧能力优先通过 skills/tooling 提供，由执行子系统 policy + permission gate 约束。

---

## 1) 术语与边界（先统一语言）

- **Extension（扩展）**：任何可变能力（Agents/Workflows/Tools/MCP/KB connectors/UI presets…）。
- **Plugin（插件）**：一个可安装的“扩展包”，用于注册一组 extensions（模板、连接器、工具、UI 等）。
- **Theme（主题）**：比插件更弱的 UI 扩展形态（偏样式/布局），尽量不改变服务端行为（类似 Discourse themes 的定位）。
- **Resource scope（global/space/user）**：资源的归属边界（见 `docs/product/terminology.md`）。
- **Plugin install scope（global/space）**：插件安装范围；single-tenant 下 `global` = instance 级（UI 可显示为 “System”），`space` = 仅某个 Space 可见。

关键约束（规范性倾向）：

- 插件本身不是“第四种 scope”。插件只是“把某些资源/能力装进系统或某个 Space”。
- Conversation 的强隐私不因插件而改变（除非引入独立资源类型，例如 SharedConversation）。

---

## 2) 向 Discourse 学什么（以及我们必须更谨慎的地方）

我们希望达到 Discourse 级别的工程化成熟度，重点学习：

- 插件的 **元数据 + 版本约束**（能表达“需要哪个核心版本”）。
- 插件的 **生命周期**：安装/启用/禁用/升级/卸载；出问题能 safe mode。
- 插件的 **设置**（global settings + admin UI）与可观测性。
- 明确的 **扩展点（outlets/hooks）**，而不是鼓励到处 monkey patch。

但我们必须比 Discourse 更谨慎的点：

- Cybros 的核心价值包含“执行能力”（工具调用、Runner、网络/文件），插件的威胁模型更接近“自动化平台”，风险面更大。
- 因此我们需要把插件按“信任等级”分层，默认 deny-by-default，并让风险在 UI/审计里可见。

---

## 3) 插件分层（信任等级，而不是“有/没有代码”）

> 目标是：让大多数扩展停留在低信任层；高信任层只给少数、可审计、可控的插件。

### 3.1 Tier 0：Content Plugin（内容插件，默认推荐）

只包含声明式资源，不包含可执行代码：

- AgentProfile / PromptBuilder / Workflow 的模板（只读，可用来创建新的 Programmable Agent（写入 Agent repo）后再改）
- Tools/MCP/KB 的“预设配置”（manifest 级别，不含 secrets）
- 文档、示例对话、评测用例（可选）

能力边界（规范性倾向）：

- 不能直接执行任何代码。
- 不能直接读/写用户对话与私有数据。
- 不提供任意 HTML 注入（避免把“内容插件”变成 XSS 载体）。

### 3.2 Tier 1：Sandbox Plugin（沙箱插件，推荐方向）

包含可执行代码，但 **只能在 Runner/沙箱中执行**（而不是 Rails 进程内）：

- 以 “skills / tools” 的形式提供脚本、二进制或容器任务
- （可选）打包并运行 MCP servers（尤其是 internal/foundation server），但对模型暴露的工具面仍建议收敛到少量原语，避免工具爆炸（见 `docs/product/mcp_servers.md`）
- 可包含 “prompt programs（沙箱内 prompt building）” 的基线程序与模板包（见 `docs/product/prompt_programs.md`）
- 通过现有的执行子系统 policy 约束其网络/文件/环境变量权限（见 `docs/execution/execution_subsystem_design.md`）

能力边界：

- 仍然不允许在 Rails 进程内执行任意代码（插件作者拿不到“服务端任意执行”）。
- 允许提供新的工具能力，但每次危险操作仍需按产品策略走审批/审计（deny-by-default）。

### 3.2.1 CLI 工具包（建议）：把“能力”交付为可版本化 CLI，而不是扩 Core

你提出“提供一个或一组 CLI 来实现各种能力（而不是把功能写进 core）”是一个很强的产品思路：它能把能力做成可分发、可升级、可禁用的 Tier 1 包。

但前提是：**LLM 不能直接用 `bash` 随便跑 CLI**，否则会出现大量不稳定与不可诊断问题（交互式提示、输出不可解析、stderr 混入、版本差异）。

阶段性结论（与你的直觉一致）：

- Phase 1 不需要官方内置 CLI 工具包；先把 Cowork + 可编程 Agent 的执行面做稳。
- CLI 思路先记录为扩展方向：后续用一个 PoC 证明“可编程 agent 在沙箱内自举安装 CLI + 受控调用”是可行的。

规范性倾向（最小可用协议，建议与 `docs/product/prompt_programs.md` 7 对齐）：

- **JSON-first**：stdin 输入 JSON，stdout 输出 JSON；stdout 禁止混入日志文本（日志必须走 stderr）。
- **非交互**：禁止 TTY prompt；缺参/失败必须返回稳定 `error_code`（details 必须 safe，不回显 secrets/对话）。
- **预算硬上限**：max input bytes / max output bytes / timeout / 并发上限；超限必须可识别（例如 `output_too_large`）。
- **命令 allowlist**：为“agent runs”提供 subcommand allowlist（避免把 CLI 变成任意执行器）；未在 allowlist 的命令必须拒绝。
- **Secrets 与网络**：只允许通过 Runner 的 secrets 注入与网络 policy；CLI 自己不拥有“宿主 keychain / 任意网络”能力。

落点建议：

- 如果 CLI 能自然表达为“工具集合”，优先将其封装为 **stdio MCP server**（自带 `tools/list` + schema），再进入 `docs/product/mcp_servers.md` 的 Tool Facade 做裁剪与审计。
- 否则由 core 提供一个“受控 CLI tool wrapper”（固定协议 + schema + budgets），把 CLI 作为后端实现，而不是把 CLI 直接暴露给模型。

### 3.3 Tier 2：Core Plugin（核心插件，谨慎）

包含 Ruby/Rails/前端代码并运行在主进程内（类似 Discourse plugins）：

- 仅 system admin 可安装
- 必须显式声明风险与能力（例如：读取对话/访问数据库/注入 UI）
- 必须有 “一键禁用/安全模式” 的止血路径

注意：

- Core plugin 没有真正的安全隔离；它的价值是“生态能力”，不是“安全可控”。
- 如果我们允许 Tier 2，文档必须把这点写得足够醒目，避免误导用户以为它仍受沙箱约束。

---

## 4) 插件包的结构与元数据（建议：YAML manifest + 可选 entrypoint）

建议插件仓库包含（示例）：

- `cybros_plugin.yml`：元数据（id/name/version/authors/url/required_cybros/required_plugin_api、tier、capabilities、可安装 scope…）
- `resources/`：内容资源包（YAML/JSON）
- `skills/`：沙箱执行代码（Tier 1）
- `server/`：Rails 扩展（Tier 2）
- `client/`：前端扩展（Tier 2 / Theme）
- `migrations/`：仅 Tier 2（需要非常谨慎的升级/回滚设计）

元数据需要至少支持：

- **required core version**：插件声明支持的 Cybros 版本范围（避免“升级即崩”）。
- **required plugin API version**：插件 API 的版本（让 core 可以做兼容分支/拒绝加载）。
- **capabilities**：插件会做什么（便于 UI 告知与审计）。

---

## 5) 安装范围与权限（和 Scope 模型对齐）

我们只讨论 single-tenant，但仍然有 global 与 space 的边界（UI 可显示为 System/Space）：

- **Global install（UI: System）**：全局可见；用于组织级标准化、官方/管理员维护的扩展。
- **Space install**：仅某个 Space 可见；用于项目级约定与隔离（Space admin 管理）。

规范性要求（倾向）：

- 安装/升级/禁用/卸载必须落审计事件（who/when/plugin_id/version/scope）。
- 插件启用状态必须可在 “safe mode” 下被一键绕过（类似 Discourse safe mode）。

插件来源与存储（建议，偏 Discourse 风格）：

- Source 形态（至少支持其一）：
  - 本地目录（例如放在 `plugins/<plugin_id>`，便于开发与审阅）
  - Git 仓库（`git clone` 到 persistent volume，便于升级/回滚）
  - 打包产物（zip/tar，便于离线分发）
- Tier 0/1 理论上可运行时安装；Tier 2（Core plugin）建议只在“构建/部署阶段”安装，并要求重启（避免热加载带来不可预测状态）。

---

## 6) 插件设置（Settings，向 Discourse site settings 对齐）

为了避免插件变成“不可运维的黑盒”，插件必须能以统一方式声明与管理设置（尤其是 system admin 侧）。

建议最小设置模型：

- Setting schema 由插件声明（在 `cybros_plugin.yml` 或同目录下的 settings 文件）。
- Setting value 的作用域必须显式：`global` / `space` / `user`（默认 `global`）。
- Setting 类型必须可验证：`bool/int/float/string/enum/json`（禁止随意对象反序列化）。
- secrets 不能出现在插件包内：
  - 插件只能声明 “需要一个 secret”，secret 的值由 admin 在 global settings 填入（并加密存储）。
  - 读取 secret 的能力必须在 capabilities 中显式出现，并落审计（至少记录“哪个插件读取了哪个 secret”，不记录 secret 值）。

备注：

- Phase 1 可以先只做 `global` 级 settings（instance-wide；满足 self-hosted 运维），再扩展到 `space/user`。

---

## 7) 最小可用规格（向 Discourse 的成熟度看齐）

我们说“像 Discourse 一样”，必须至少包含这些工程化要素（否则只是“能加载几份模板”）：

- 元数据与兼容性：插件能声明 required core/plugin API 版本，不满足则拒绝加载。
- 生命周期：install / enable / disable / upgrade / rollback / uninstall（至少对 Tier 0/1 可运行时操作）。
- Safe mode：能在实例级或请求级绕过插件/主题，快速止血定位。
- 设置：插件 settings 有统一 schema + UI/文档；修改可审计。
- 可观测性：错误、耗时、被调用次数能按 plugin_id/version 归因（LLM/tool/skill）。
- 边界可解释：插件的安装范围（global/space install scope）与其产物资源的 resource scope（global/space/user）都必须在 UI 上可解释“为什么你能看到/不能看到”。

---

## 8) 与 git-backed 可变资源的关系（避免“插件更新覆盖用户修改”）

基本原则：

- 插件提供的是 **只读模板/能力**；用户的可变资源仍然由 Agent repo 管理（可选 git；见 `docs/product/versioning_and_sync.md`）。
- 插件更新不应“偷偷改写”用户 repo 的文件；除非用户明确执行 “Upgrade applied resources” 之类的动作，并且可回滚。

因此插件要提供两种内容交付方式（建议）：

1) **Template-only**：只在 UI 里可选择/可 Copy，不自动写入 repo。  
2) **Install-to-repo（可选）**：把模板写入某个 repo（若启用 git：产生 commit 以便回滚；审计 best-effort），后续更新需要显式合并策略。

---

## 9) Phase 切片（本阶段不实现，但先把目标对齐）

为了尽快评估产品形态，建议按风险分层逐步落地：

- Phase 1：Tier 0 Content plugins（global/space 安装 + Copy 模板到 repo）
- Phase 2：Tier 1 Sandbox plugins（skills/tool bundles；完全走执行子系统 policy）
- Phase 3：Tier 2 Core plugins + Theme（引入 outlets/hooks + safe mode + 兼容性治理）

---

## 10) Open questions（需要在文档中尽早收敛）

- 插件的 “官方/可信列表” 是否需要（类似 Discourse official plugins）？
  - 建议默认：**本地 allowlist**（管理员显式允许），并内置一份“随 core 发布的 first-party 插件列表”；签名/供应链校验作为 Phase 3+ 议题。
- 插件 API 的版本策略：SemVer？还是 “core version = plugin API version”？
  - 建议默认：**独立 SemVer**（插件声明 `required_plugin_api` + `required_cybros` 双约束）。
- Theme 的边界怎么划？
  - 建议默认：Phase 1/2 只允许 **CSS variables + DaisyUI theme tokens**；任何模板注入/outlet 都视为 Tier 2（Core plugin）能力。
