# Cybros Execution Subsystem（Mothership + Nexus）设计方案（v0.6）

> 目标：为 Cybros 提供“在本地/远程主机的隔离环境中执行操作（编辑修改文件、运行命令、收集信息）”的基础设施。
>
> 背景：控制面（Cybros 服务）部署在云端；执行面位于用户的个人电脑/服务器。Nexus 运行在用户主机上，与云端控制面通信，并在同机的 microVM/容器环境中执行命令。
>
> 本版更新（v0.6，2026-02-22）：
> - 平台/运行环境要求定稿：Linux 仅需支持 2024 年后的发行版（x86_64 + aarch64）；macOS 仅做 `darwin-automation`（Apple Silicon，面向最新 macOS 26），不在 macOS 上做容器/隔离。
> - Nexus 实现策略收敛：主机侧 Nexus 采用 Go 单二进制（便于静态链接与跨发行版分发）；Mothership 仍为 Ruby（Rails）。
> - microVM 基线策略定稿：**先用现成发行版基线（Bootstrap）**跑通 Untrusted，再演进到 **Cybros 自维护 hardened baseline（签名/版本化）**，实现可回放与一致性。
> - 网络策略默认“宽松但不裸奔”：提供 **无安全策略 / 宽松 / 严格 / 禁止外部资源访问** 四档 preset，并允许在 preset 上做自定义微调。
> - allowlist v1 冻结为 **domain:port（含 `*.` 通配）**；CIDR/expires_at/approval_required 等作为 future plan 记录。
> - 冻结 `DirectiveSpec.capabilities.net` 的 JSON Schema（V1）与 `reason_code` 列表，Mothership/Nexus 可并行开工。
> - Secrets 边界拆分：将 **平台凭据（Nexus 身份/证书/短期 token）** 作为 MVP 必做；**用户业务 secrets** 先留接口，列入 future plan（不阻塞主线）。
> - 执行模型澄清：**v1 允许任意脚本/命令**；未来增加配合 Nexus 的 **sandbox 内置 CLI**，把高频操作包装成更稳定、更可审计的原语（提升成功率 + 降低风险）。
> - 安装与兼容策略定稿：生产安装脚本提供你们验证过的 **推荐版本**；Nexus 只强制 **最低版本**，对更高版本只提示“未验证”而不强行阻塞。


## 0. 范围与原则

### 0.1 设计原则

- **控制面与执行面分离**：Mothership 负责编排、策略、审计；Nexus 负责实际执行与隔离落地。
- **Pull 优先**：Nexus 主动向控制面拉取任务，避免在用户机器开放入站端口（天然适配 NAT/企业内网）。
- **Deny-by-default**：默认不允许网络/宿主 IO/敏感 env；一切能力由 policy 显式授予。
- **“用户决定是否信任本机”是一等概念**：执行 profile 分层，不可信默认强隔离；可信才允许更便捷/更高性能的模式。
- **易用与安全平衡**：把“安全做法做得更省事”（一键允许域名并重试、模板 allowlist），避免用户因复杂而绕过检查。
- **结果可回放**：每次执行产出命令/权限/运行时版本/摘要/文件变更（diff）/工件索引，可审计、可重跑。
- **先独立、后集成**：先以独立子系统（Mothership API + Nexus）落地；与 AgentCore / DAG 节点映射与 UI 集成放在最后阶段。

### 0.2 非目标（第一阶段不做）

- 不做交互式 PTY（ssh-like shell）。只做非交互命令 + 结构化文件读写/补丁。
- 不做“自动信任推断”。信任必须由用户/管理员显式设置或审批。
- 不承诺在“完全不可信的宿主机（Nexus 被攻陷）”下保护所有租户数据：Nexus 属于执行面信任边界的一部分（见威胁模型）。
- 不支持 Windows；不支持 Intel Mac；不支持低于 macOS 26 的 macOS 版本。

### 0.3 支持平台与最低环境要求（新增）

> 目标：把“能跑起来的最低系统前置条件”写死，避免为了兼容老系统在底层沙箱/网络策略上被迫降级。

#### Linux Host（支持 2024 年及以后发行版）

- **CPU 架构**：`x86_64`、`aarch64/arm64`
- **推荐能力基线**（按重要性排序）：
  1) systemd（服务管理）
  2) cgroups v2（容器资源限制；microVM/容器配额）
  3) KVM 可用：`/dev/kvm` 可读写（运行 Firecracker）
  4) nftables（或 iptables-nft）可用（实现 Untrusted 的硬 egress 限制）
  5) 支持 OCI 容器运行时（Podman rootless 优先；或 Docker）
- **可接受的发行版范围**：仅承诺“2024+ 主流发行版”（例如 Ubuntu 24.04+、Fedora 40+ 等），不再适配更早版本。

#### macOS Host（仅支持 Apple Silicon + macOS 26；仅 `darwin-automation`）

- **CPU 架构**：Apple Silicon（arm64）
- **OS**：macOS 26（不支持更早版本）
- **支持范围**：只支持 `darwin-automation`（操作 macOS 原生应用 / Shortcuts / AppleScript / UI Automation）。
  > 不提供 Linux-in-VM/容器隔离执行；如需隔离执行 Linux 工作负载，建议用户改用 Linux territory（物理机/服务器/VM/容器均可）。
- **权限与安全边界**：
  - 依赖 macOS 的隐私权限体系（TCC）：Automation（Apple Events）、Accessibility、Screen Recording 等。
  - 默认 **deny-by-default**：`NET=NONE`、仅允许 workspace（或显式路径 allowlist），并对每次 directive 强制审批与审计（展示目标 App、脚本/命令、将触发的能力）。
  - 企业场景可通过 PPPC（Privacy Preferences Policy Control）配置 profile 进行预授权（MDM），否则需要用户在系统设置中逐项授权。

### 0.3.1 典型使用场景（你补充的 3 类）

> 目的：把默认策略与部署形态对齐，避免“一个方案试图覆盖所有场景”导致安全/体验两头不讨好。

1) **资源受限的“近端”Territory（靠近 Mothership）**
- 形态：与 Mothership 同机或同机房；沙箱资源很小（例如 ~256MB 磁盘、<512MB 内存）。
- 目标：低延迟、快速执行基础 shell/patch/检索（可选集成 DesktopCommanderMCP/MCP 工具增强能力）。
- 建议默认：Linux + `untrusted`（Phase 1 bwrap / Phase 3 microVM）+ workspace-only + `NET=NONE/ALLOWLIST`。
- 注意：MCP 工具与“allowedDirectories/blockedCommands”只能提升 UX，**不能替代 OS-level 隔离与 egress 强制**。

2) **用户电脑的“硬件能力节点”（Linux/Mac）**
- Linux：GPU/ML/企业内网/VPN/真实设备访问等，通常需要 `trusted`（容器）或 `host`（审批）才能做到“硬件可用 + 体验可接受”。
- macOS：只做 `darwin-automation`（风险 ≈ Host），必须显式开启、强审批、强审计。

3) **用户电脑的 Vibe Coding 工作区**
- 目标：编辑/测试/构建代码（高频小步迭代）。
- 建议默认：`trusted`（更偏体验）+ 写入仍尽量 workspace-only；读取可选 Read-open（仅在用户确认/审批后启用），网络默认 allowlist 模板。


---

## 0.4 实现语言与运行时策略（新增）

### 0.4.1 控制面（Mothership）

- **服务端固定 Ruby/Rails**：与现有 Cybros Monolith 保持同栈，复用 ActiveJob/ActiveStorage/Postgres、RBAC、多租户中间件等能力。

### 0.4.2 执行面（Nexus）

Nexus 运行在用户主机侧，承担：长轮询/日志流、facility 生命周期、sandbox driver（microVM/容器/host/automation）落地、以及网络/资源/审计边界的”最后一公里”。

**决定（结合你的偏好与安全诉求）：**

- **产品级 Nexus 使用 Go 实现，并以“单二进制（per OS/arch）”分发**：
  - Linux：承载 `untrusted(microVM)` / `trusted(container)` / `host(审批)`。
  - macOS：只承载 `darwin-automation`（高信任、强审批、强审计），不承载隔离执行。
  - 原因：更适合做系统守护进程与底层隔离控制（KVM、netlink、nftables/iptables、cgroups、tap/tun 等），且跨平台分发不依赖语言运行时。

- **Ruby 仍然保留为 Mini Nexus（开发/联调/协议回归）的首选**：
  - 用 Ruby 快速把 Nexus API/协议跑通（enroll/poll/lease/log/artifacts），减少控制面联调摩擦。
  - Mini Nexus 默认禁用 `untrusted/microVM` 与“硬 egress”能力，仅用于开发环境。
### 0.4.3 如果坚持 Nexus 也用 Ruby：可行，但必须 vendoring 运行时

如果你希望“生产 Nexus 也用 Ruby”，建议把 Ruby 当作 **可分发的依赖工件** 处理：

- **不要假设 macOS/Linux 自带可用 Ruby**（macOS 尤其不可控）。
- 采用 **vendored Ruby runtime**（每个 OS/arch 一份）+ `bundler` + 受控 gem 集合：
  - 安装器（install.sh/pkg）下载并校验对应平台的 Ruby runtime tarball；
  - Nexus 进程固定使用该 runtime 启动（例如 `./vendor/ruby/bin/ruby nexus.rb`）。

Homebrew 的 Portable Ruby 是类似思路：Portable Ruby 版本来自 `vendor/portable-ruby-version`，下载地址按 sha256 digest 拼出来并默认回退到 GHCR（参考 `vendor-install.sh` 的实现）。

> 结论：Ruby Nexus 的工程难点不在“写 Ruby”，而在“可靠分发/升级 Ruby 运行时 + OpenSSL/CA + 依赖收敛”。若你更看重交付确定性与运维成本，仍推荐产品 Nexus 用 Go/Rust。

### 0.4.4 Nexus 特权拆分（必须，面向后续可维护性与安全）

你明确更担心安全性，因此 Nexus 需要从一开始就把“必须 root 的能力”与“长期驻留守护进程”拆开：

#### 0.4.4.1 进程/权限分层

- **nexusd（主进程，无特权）**
  - 职责：mTLS Pull、DirectiveSpec 校验与状态机、日志/工件上传、facility 锁与元数据、选择 sandbox driver。
  - 权限：尽量 **不以 root 运行**；Linux 下仅需要读写 facility workspace 目录、访问本地 unix socket；microVM 场景可通过把 nexusd 加入 `kvm` 组来访问 `/dev/kvm`（避免 root）。
- **nexus-helper（特权 helper，最小特权）**
  - 职责：只做“必须特权”的系统操作，例如：
    - 创建/配置 TAP、netns、nftables/iptables 规则（实现 Untrusted 的硬 egress 限制）。
    -（可选）创建/配置 cgroup（若不依赖 systemd delegation）。
    - 启动 Firecracker `jailer`（其本身会完成 chroot、namespace/cgroup 设置并降权）。
  - 权限：以 root 启动，但通过 systemd 进行强约束（CapabilityBoundingSet、ProtectSystem、NoNewPrivileges 等），并把可写目录限制到 `/run/cybros-nexus/`、facility 根目录等必要路径。

> 设计目标：即便 `nexusd` 出现 RCE，也不能直接获得 root；攻击者必须额外突破 `nexus-helper` 的受限接口与 systemd 沙箱。

#### 0.4.4.2 nexusd ↔ helper 的通信与最小 API

- 仅使用 **本地 Unix Domain Socket**（例如 `/run/cybros-nexus/helper.sock`），文件权限设置为 `root:cybros-nexus 0660`。
- helper 对每个请求做：
  - 调用方身份校验（Linux 可用 SO_PEERCRED 获取 uid/gid；macOS 可用 audit token）。
  - 参数严格校验（例如：只允许操作该 directive 的临时目录/网卡名、只允许写入特定 nft table/chain）。
  - 全量审计（把”做了哪些特权操作”写入 directive audit 事件）。

#### 0.4.4.3 Firecracker 的隔离落地建议（Linux Untrusted）

- Firecracker 官方建议生产环境通过 `jailer` 启动，并由 jailer 施加 cgroup/namespace 隔离并降权；同时建议为 Firecracker 使用专用非特权用户/组，甚至每个 microVM 使用不同 uid/gid 做额外防线。
  （这部分由 **helper** 负责落地，nexusd 不直接碰 root。）
- Firecracker 的 host 网络集成以 TAP 为基础，意味着“网络硬限制”落地必然会涉及 host 侧网络配置（这是 helper 必须存在的根本原因之一）。

#### 0.4.4.4 systemd 单元硬化（示例）

- nexusd（无特权）建议开启：`NoNewPrivileges=yes`、`ProtectSystem=strict`、`ProtectHome=read-only`、`PrivateTmp=yes`、`PrivateDevices=yes` 等。
- helper（最小特权）建议：
  - `CapabilityBoundingSet=` 白名单化（例如只给 `CAP_NET_ADMIN`/`CAP_SYS_ADMIN` 中真正必要的能力；能不用就不用）。
  - `ProtectSystem=strict` + `ReadWritePaths=/run/cybros-nexus /var/lib/cybros-nexus`（按需放行）。
  - `SystemCallFilter=`（可选，后期增强）。

> 备注：具体 systemd hardening 选项以“能跑通”为前提逐步加严，避免一次性把 unit 锁死导致难排障。




## 0.5 运行时制品与基线镜像策略（microVM kernel/rootfs）

> 你已确认：为了长期一致性与可维护性，我们最终需要由 Cybros 准备并维护基线；但为了实用性，先从现成发行版开始。

### 0.5.1 为什么需要“基线制品”

- microVM 不是“复用宿主 OS”的执行环境：它至少需要一份 guest kernel 与 rootfs（ext4 等）。
- 如果不把 kernel/rootfs 当作可版本化制品，Directive 的可回放、审计与跨主机一致性会变成偶然。

### 0.5.2 两阶段策略（Bootstrap → Cybros Managed）

**阶段 A：Bootstrap（MVP）——使用现成发行版基线**

- 默认支持 1～2 个发行版基线（例如 Ubuntu 24.04 minimal / Debian stable），覆盖 `linux/amd64` 与 `linux/arm64`。
- Nexus 负责“拉取/转换/缓存”一组已验证的 `{kernel, rootfs}`（或提示管理员用脚本生成），并把 **digest** 写入 directive 元数据。
- 目的：尽快跑通 Untrusted microVM + 网络/审计/审批闭环，把研发资源投入到隔离与控制面能力，而不是过早自建镜像流水线。

**阶段 B：Cybros Managed（终极形态）——自维护 hardened baseline**

- Cybros 构建并发布 hardened baseline（最小 rootfs、受控 init、默认禁用不必要服务/守护进程）。
- 制品版本化：`baseline_name@sha256:<digest>`（tag 仅用于人类可读），并提供签名/校验。
- Nexus 支持 `nexus image list/pin/update`；Policy 可以指定“必须使用某个 digest”。

### 0.5.3 维护边界与成本归属

- Upstream 发行版基线：你们只对“已验证组合”负责（kernel/rootfs 的 URL+digest）；上游可用性问题可通过镜像/缓存降低。
- Cybros Managed baseline：你们负责漏洞响应、更新节奏与兼容性测试（这是产品一致性与安全性的核心成本）。

### 0.5.4 与依赖 BYO 的关系

- **Firecracker/jailer / Podman/Docker**：默认 BYO（外部系统组件），你们只做最低版本约束 + doctor 检测。
- **baseline kernel/rootfs**：属于执行一致性的关键制品；即使早期来自上游，也建议在控制面记录 digest，用于回放与审计。


---

## 1. 需求清单（功能点）

### 1.1 核心能力

- 在 **Linux（优先）** 与 **macOS（可选）** 的目标机器上执行：
  - 运行命令（可配置超时、资源限制）。
  - 读/写 workspace 内文件；应用 patch；产出 diff。
  - 收集工件（测试报告、日志、生成文件、截图等）。
- Facility **需要持久化**（跨多次 directive/多轮对话），并且必须可锁定防并发写冲突。
- 必须支持 **不可信代码**：
  - 默认不可信：必须在强隔离环境执行（Linux: Phase 1 bubblewrap；Phase 3+ microVM）。macOS 不提供“不可信代码”的隔离执行（仅 `darwin-automation`，高信任 + 强审批）。
  - 用户可选择标记“可信环境”获得更好性能/更低延迟（容器/宿主）。
- 网络访问支持 **policy 三档**：
  - 全禁 `none`
  - 白名单 `allowlist`
  - 不限制 `unrestricted`
- Cybros 与主机之间的连接必须 **安全**：
  - 认证（防伪装 Nexus/控制面）
  - 加密（防窃听）
  - 最小权限（短期凭证、可撤销）
- 多租户隔离：至少按 **account（租户）** 与 **user（用户）** 做隔离边界，支持未来形态（单用户/单租户多用户/多租户）。

### 1.2 运维与可靠性

- NAT/内网/企业代理场景可用：
  - Nexus 只需出站访问控制面（Pull）。
  - 支持 Nexus 通过 HTTP(S) 代理访问控制面。
  - 对“控制面在本地开发机、外部机器要连接”的场景给出清晰方案（隧道/VPN/Relay）。
- 任务调度与容错：
  - lease/心跳机制，Nexus 掉线可回收并重派。
  - 幂等：日志/工件上传可重试不重复。
  - 取消：用户可取消正在执行的 directive（Nexus 负责终止沙箱）。
- 可观测性：
  - 流式日志（chunked），并且有大小上限与截断标记。
  - 审计事件（谁批准/谁触发/跑了什么/访问了哪些资源）。

---

## 2. 威胁模型（Threat Model）

### 2.0 资产与信任边界（先写清楚“要保护什么”）

**核心资产（按优先级）**：
- 用户 workspace（facility）中的源码/文档/数据与生成物。
- 平台凭据：enroll token、territory 身份材料（未来 mTLS 证书）、directive_token、对象存储上传凭据等。
- 用户业务 secrets（未来）：GitHub token/SSH key/云 API key 等。
- 审计与证据：日志、diff、工件清单、审批记录（可追责与复盘）。
- 多租户隔离：不同 account/user/facility 之间的硬隔离与最小暴露。

**信任边界（必须默认按“最坏情况”设计）**：
- 控制面（Mothership）与执行面（Nexus）之间是跨网络边界：需要强认证 + 加密 + 可撤销。
- Sandbox 与宿主 OS 之间是最高风险边界：Untrusted 必须有 OS/虚拟化强制边界，不能只靠提示/约定。
- Facility 是“持久化状态”的边界：需要互斥锁、配额、清理与归档策略，避免跨任务污染与 DoS。

### 2.1 主要威胁

- 不可信代码试图：
  - 逃逸沙箱获取宿主权限（container escape / kernel exploit）。
  - 读取宿主敏感文件（SSH key、云凭据、/etc、home）。
  - 通过网络外传 secrets/隐私数据。
  - 资源消耗攻击（fork bomb、磁盘打满、日志洪泛）。
- LLM/提示注入导致：
  - 误执行高危命令（rm -rf、curl|bash）。
  - 放宽权限（网络 unrestricted、宿主读写）而用户未充分理解。
- Nexus 端被攻陷：
  - 伪造执行结果、伪造日志。
  - 窃取同机的其他租户 facility（如果共存且隔离不足）。

### 2.2 核心防线

- **分级信任 + 强隔离默认**：不可信默认强隔离（Phase 1: bwrap；Phase 3+: microVM/VM）；容器仅用于可信；宿主仅用于显式审批。
- **最小可用权限**：默认 `NET=NONE`、只挂载 workspace；secrets 以短期 token 注入且可审计。
- **强制网络出口控制**：Untrusted 模式下通过“只允许访问 egress proxy + allowlist”实现硬限制（Linux 必须做到硬限制；macOS 初期可先实现“强制代理 + 软限制提示”，后续再补 host 级网络硬限制）。
- **资源限制**：CPU/内存/磁盘/时间/最大输出。
- **审计与可撤销**：每次放宽权限都落审计，可撤销 nexus 证书/禁用 territory。

### 2.3 Phase 0 安全降级说明（必须显式写在文档里）

Phase 0 的目标是协议与闭环可用，不是安全上线：

- **认证降级**：Phase 0 使用 `X-Nexus-Territory-Id` header（Decision D16）标识 territory，**可伪造**；仅用于本地联调/集成测试。
- **隔离缺失**：Phase 0 的 Nexus 仅实现 `host` driver（无隔离），`sandbox_profile`/`capabilities` 仅做占位与审计回传，不能作为安全承诺。
- **能力未强制**：Phase 0 不提供网络 allowlist 的强制执行、不提供宿主路径访问的强制边界。

因此 Phase 0 的运行前提是：单租户、自用、完全信任运行 Nexus 的机器与网络环境。

### 2.4 容易疏漏但必须补齐的安全细节（Phase 1+）

- **directive_token 绑定**：token 必须绑定 territory 身份（mTLS 指纹/territory_id），并在服务端校验，防止 token 在不同 territory 间横向使用。
- **log_chunks 幂等与限额**：按 `(directive_id, stream, seq)` 去重；服务端强制 `max_output_bytes` 与速率限制，避免被刷爆存储与内存。
- **domain allowlist 的“解析绕过”**：仅靠域名匹配无法阻止 DNS rebinding / 域名解析到私网 IP；proxy 侧需要做“解析结果策略”（默认拒绝私网/loopback/link-local，或触发审批）。
- **`localhost` 特判**：在 Trusted/Host 下，`localhost` 可能指向宿主服务（如 metadata/daemon）；建议默认拒绝或强审批。
- **路径与链接逃逸**：对所有文件读写与 patch 应做 `realpath` 校验，并在沙箱侧避免把宿主敏感路径 bind-mount 进来；尤其注意 symlink/hardlink 与 `..` traversal。

### 2.5 残余风险与非目标（需要产品与文案承认）

- 不承诺在“宿主 OS 或 Nexus 完全被攻陷”下仍能保护用户数据与多租户隔离（执行面本身是信任边界的一部分）。
- 不承诺对“用户主动授予的 Host/darwin-automation 高危能力”提供隔离防护；此类能力的风险主要靠审批与审计控制。

---
