## 11. 部署形态（先独立发展）

### 11.1 单机（最低延迟）

- Mothership（Rails）跑在同一台机器（可 Docker Compose）。
- Nexus：
  - Linux：建议以 systemd service 运行（便于使用 KVM、管理网络/防火墙、挂载磁盘/volume）。
  - macOS：Nexus 作为 launchd user agent（推荐）运行；仅提供 `darwin-automation`（会触发 TCC 授权提示）。
- microVM/容器也在该宿主机上执行，延迟最低。

### 11.2 分布式（多机器）

- Mothership 统一部署（云或内网）。
- 多台机器安装 Nexus（每台一个 territory）。
- facility 亲和到某台 territory；需要迁移时做打包/同步（后续增强）。

### 11.3 仓库内 Nexus（简易版，便于不同步演进）

Nexus 与 Cybros（Mothership）进度可能不同步，建议在 Cybros 仓库根目录加入 `nexus/`，满足两类目标：

- **产品级 Nexus（可独立发布）**：将来可拆到独立仓库或打包为单二进制/安装包，但源代码先放在 `nexus/` 便于联调。
- **Mini Nexus（开发/回归用）**：提供一个“功能覆盖最小集合”的实现（通常仅 Trusted/Host），用于：
  - 快速联调 Mothership API（enroll/poll/log/artifacts）
  - 做协议兼容性测试（contract tests）
  - 在没有 Firecracker/复杂网络限制的环境下也能推进主流程开发

注意：
- Mini Nexus 必须在文档与启动时打印“仅用于开发”的警告；默认禁用 Untrusted/microVM。
- Nexus 与 Mothership 的协议应以 JSON schema/OpenAPI 固化，Mini Nexus 以此做严格校验，避免两边默默 drift。

---

### 11.4 Nexus 安装、升级与依赖管理（新增）

> 目标：把“用户主机侧的环境不确定性”收敛到安装器与分发包里，尽量让 Nexus 本体做到：**单次安装、可自升级、可回滚**。

#### 11.4.1 分发形态（建议）

- **发布物（release artifacts）按 OS/arch 切分**：
  - `nexus-<ver>-linux-amd64.tar.gz`
  - `nexus-<ver>-linux-arm64.tar.gz`
  - `nexus-<ver>-darwin-arm64.tar.gz`
- 每个包至少包含：
  - `nexus`（主二进制或主入口脚本）
  - `config.example.yml`
  - Linux：`cybros-nexus.service`（systemd unit）
  - macOS：`com.cybros.nexus.plist`（launchd plist，或提供生成脚本）
  - `SHA256SUMS` 与签名（推荐：cosign 或 GPG；第一阶段也至少提供 sha256 校验）

#### 11.4.2 安装器（install.sh/pkg）的职责边界

安装器只做“可审计的系统改动”，核心流程：

1) 探测 OS/arch、检查前置（Linux：KVM/cgroups/nftables/容器运行时；macOS：仅检查版本/签名一致性，并提示后续会触发的 TCC 授权）。
2) 下载对应 release artifact → 校验 sha256/签名 → 解包到固定目录（例如 `/opt/cybros-nexus/<ver>/`）。
3) 写入配置文件（例如 `/etc/cybros-nexus/config.yml` 或用户目录）。
4) 注册服务并启动：
   - Linux：systemd（建议 system service；涉及 KVM/防火墙时更合理）
   - macOS：launchd（建议 user agent 或 system daemon，取决于是否需要特权能力）

> 注意：Nexus 的 enrolment token / mTLS 证书属于敏感配置，安装器应尽量避免在命令行历史中泄露（优先交互式输入或从文件读取）。

#### 11.4.3 依赖策略（定稿：默认 BYO；可选受控下载）

你提到“不想把第三方二进制打包进 Nexus，否则还要维护它们的版本”，这里给一个可迭代且不和你偏好冲突的策略：

- **Nexus 本体**：Go 单二进制（per OS/arch），尽量静态/自包含（这属于“静态链接”，不引入额外运维负担）。
- **第三方系统组件（外部二进制）**：默认 **BYO（由用户/管理员安装与升级）**，Nexus 只做：
  - `nexus doctor`：检测是否存在、版本是否满足最低要求、关键能力是否可用（/dev/kvm、nft、rootless 容器等）
  - `nexus compat`：输出“已验证组合”（如：Ubuntu 24.04 + podman 5.x + firecracker >= X）
  - **可选** `nexus deps fetch`（默认关闭）：仅当你想要“更丝滑安装体验”时，才让安装器从官方 release 下载固定版本并校验 hash（这相当于“受控下载”，但依然不把二进制塞进主包里）。

按 profile 拆分依赖：

- **Linux / Untrusted（bubblewrap，Phase 1 MVP）**：
  - 依赖：`bubblewrap` + `socat`（Ubuntu: `apt install bubblewrap socat`；Fedora: `dnf install bubblewrap socat`）。
  - 策略：不打包；仅做探测与提示。非常轻量，大部分 Linux 发行版均有包。
  - 无需 KVM 或 root 权限（利用 user namespace）。
- **Linux / Trusted（容器）**：
  - 依赖：Podman（rootless 优先）或 Docker（rootful 需更谨慎）。
  - 策略：不打包；仅做探测与提示（例如给出 apt/dnf 的安装指令模板）。
- **Linux / Untrusted 加固（Firecracker microVM，Phase 3 可选）**：
  - 依赖：Firecracker + `jailer`、KVM（`/dev/kvm`）、以及 nftables/iptables-nft（做硬 egress）。
  - 策略：不打包；Nexus 通过 `doctor` 校验；必要时再启用”受控下载”选项。
  - 备注：kernel/rootfs 如果由你们提供官方基线镜像，则它们属于”你们产品工件”，建议走版本化下载（便于回放与审计），这部分维护成本不可避免但也最可控。
- **macOS / darwin-automation**：
  - 不依赖容器/虚拟化组件；依赖的是系统自带能力与 TCC 授权（Automation/Accessibility/Screen Recording 等）。
  - 策略：不打包第三方二进制；把“需要的系统权限”写入产品文档与审批 UI，并提供自检（例如检测是否已获得 Automation 权限）。

> 解释一下你问的“内置”：
> - **静态链接（推荐）**：把依赖库编进同一个二进制（Go/Rust 常见），用户侧无需额外安装运行库。
> - **打包外部可执行文件（默认不做）**：把 firecracker/podman 等第三方可执行文件随 Nexus 一起分发（无论是 tarball 里直接带，还是二进制里 embed 再解压），都会带来额外版本维护与安全响应成本，因此默认 BYO。

#### 11.4.4 兼容性策略（定稿：安装脚本给推荐版本；Nexus 只约束最低版本）

- 生产安装脚本（`install.sh`/pkg）提供“你们验证过的推荐版本组合”（写入文档/输出到 `nexus compat`）。
- Nexus 启动与 `nexus doctor` 只做 **最低版本**强校验：
  - 低于最低版本：拒绝启动/拒绝启用对应 profile（避免踩到已知不安全或缺能力的版本）。
  - 高于最低版本：默认允许，但标记为 **unverified**（未在兼容矩阵中验证），并提示用户“建议回归测试/必要时回退到推荐版本”。
- 目标是在“不锁死用户升级”的同时，维持可支持的最低安全/功能基线。

---

## 12. 与 AgentCore 的集成与 Nexus CLI（补齐缺失章节）

> 本节定义“接口与映射”，避免把 AgentCore 绑定到某个具体 sandbox 实现。
> 思路：AgentCore 只做决策与编排；Mothership/Nexus 负责执行、隔离、审计与工件。

### 12.1 集成边界（推荐）

- AgentCore（或任意 Agent）只需要：
  1) 生成 DirectiveSpec（或调用 Mothership API 创建 directive）
  2) 读取日志/工件/diff 并继续推理
- Mothership 负责：
  - policy 计算（effective capabilities）
  - 审批与审计（尤其是 Host/macOS automation）
  - 调度/lease/超时回收
- Nexus 负责：
  - sandbox driver（container/microVM/darwin-automation）
  - 日志/工件上传
  - 执行时硬约束（硬 egress、路径校验、资源配额）

### 12.2 Tool calls → DirectiveSpec 的映射（建议）

建议把 AgentCore 的工具层抽象成“少量稳定原语”，映射到 DirectiveSpec：

- `exec(command|script, cwd?, env_refs?, net_policy?, fs_policy?)` → `DirectiveSpec.steps[].action = "exec"`
- `read_file(path)` / `list_dir(path)` / `stat(path)` → `DirectiveSpec.steps[].action = "read_*"`（严格受 FS policy 约束）
- `apply_patch(patch)` → `DirectiveSpec.steps[].action = "apply_patch"`（建议输出结构化 diff + 风险提示）
- `collect_artifact(paths|globs)` → `DirectiveSpec.artifacts`
- `request_approval(reason, capability_delta)` → 触发审批流（Host / macOS automation / UNRESTRICTED 网络等）

### 12.3 sandbox 内置 CLI（Future plan，与你的方向一致）

- **v1（你已定稿）**：允许任意脚本/命令，安全边界由 `profile + capabilities + 审批 + 审计` 决定。
- **Future**：提供一个随 sandbox 镜像一起发布的 `cybros` CLI（或 `nexus-cli`），供 Agent 调用：
  - 把高频动作（git/包管理/ssh/deploy/patch）包装成更稳定的原语，输出结构化 JSON（提升成功率）。
  - 与 policy 联动：例如 `cybros ssh` 自动走 CONNECT proxy、自动生成临时 ssh_config、自动写审计事件。
  - 与 secrets 联动：优先使用 `secret_ref` 注入，减少密钥进入脚本与日志的概率。

---
## 13. 路线图（从可跑通的 MVP 到终极形态）

> 目标：每个阶段结束都“可验收、可回归、可解释”。不追求一次到位，把复杂度拆成可以逐步加固的层。

### Phase 0：协议冻结 + 最小端到端闭环（开发用，不承诺隔离）

- 输出：
  - DirectiveSpec/DirectiveResult/Policy 的 JSON Schema + OpenAPI（冻结字段与错误码）。
  - 数据模型与状态机（facility/directive/artifacts/audit）。
- Mothership（Ruby/Rails）：
  - 最小 API：enroll、territory heartbeat、poll/lease、create directive（测试 API）、log_chunks、finish directive（可选附带 diff blob）。
- Nexus（Go）：
  - 只实现 `host` driver（无隔离），用于跑通协议与日志链路。
  - `darwin-automation` driver：Phase 0 未实现（占位在 roadmap）。
  - 认证：Phase 0 使用 `X-Nexus-Territory-Id` header（Decision D16，dev only）+ directive JWT（短 TTL）。
- 验收：
  - 在 Rails 集成测试中可跑通：enroll → poll/lease → started/heartbeat/log_chunks → finished（见 `mothership/test/scripts/e2e_conduits.rb`）。

### Phase 0.5：可靠性/安全脚手架（支持长期演进）

> 目标：不改变 Phase 0 的“可联调”性质，但把最容易踩坑的可靠性与安全边界先补齐，为 Phase 1+ 做铺垫。

- Mothership：
  - `log_chunks`：服务端去重（`(directive_id, stream, seq)`）+ `limits.max_output_bytes` 硬上限；日志落库为分片表（避免 ActiveStorage “追加”放大）。
  - lease 回收 reaper：把过期 `leased` directive 退回 `queued` 并解锁 facility（已接入 SolidQueue recurring 定时调度）。
  - TTL 清理 job（默认 30 天）：`conduits_log_chunks`（DB）+ `diff_blob`（ActiveStorage）的小批量渐进式清理（避免 I/O 尖峰）。
  - Enrollment rate limiting：已启用 `POST /territories/enroll` 的 per-IP 限流（Rack::Attack，10/小时，返回 429 + `Retry-After`）。
  - mTLS MVP：enroll 可选 `csr_pem` 签发 client cert，并支持证书指纹认证（由边缘代理注入 fingerprint header；生产应尽早切换 mTLS-only）。
  - FS 默认能力：按 profile 注入默认 `capabilities.fs`（可配置文件化，便于未来调整）。
- Nexus：
  - Facility prepare（repo_url auto-clone）：当 facility 目录为空且 `repo_url` 有值时自动 `git clone --depth 1 <repo_url> .`（Phase 0 driver 仍是 host；Phase 1 需移入 sandbox driver）。

### Phase 1：Linux Untrusted（bubblewrap）+ Trusted（容器）MVP

- Nexus：
  - 标准 Linux userspace：**Ubuntu 24.04**（amd64+arm64），作为 bubblewrap rootfs 与容器镜像的共同基线（便于一致性与回放）。
  - **Untrusted bubblewrap 驱动**（决策 D11）：使用 bwrap 创建 namespace 隔离环境（mount/network/PID/user），无需 KVM。
    - FS 默认策略（修订决策 D12）：**workspace-only + write allow-only**（仅把 facility/workspace 挂载进沙箱；其它宿主路径默认不可见）。
    - 网络完全隔离（network namespace），出站通过 **UDS egress proxy（CONNECT+SOCKS5）+ allowlist** 强制执行（bubblewrap + socat bridge）。
    - 依赖：`bubblewrap` + `socat`。
  - facility 创建/锁（防并发写）。
  - Trusted 容器驱动：rootless Podman 优先，Docker 兜底（依赖 BYO）。
  - chunked 日志上传（stdout/stderr/structured events）+ 工件上传。
  - 执行后 diff 产出（git diff 或目录 diff）。
- Mothership：
  - 最小 UI：territory 列表、directive 列表、日志查看、diff/工件下载。
- 安全边界（MVP 级）：
  - deny-by-default 的能力模型先落地（哪怕先只覆盖 NET/FS/SECRETS）。
  - Untrusted 网络：Phase 1 直接做 **硬 egress**（netns + UDS proxy），避免“注入 proxy env 但仍可直连”的绕过。
  - Trusted 网络：可先走“软约束”（强制注入 proxy env + 审计提示）；host 防火墙级硬隔离后续再补齐。
- 验收：
  - 在 Linux 上完整跑通“编辑文件 → 运行测试 → 产出 diff/工件”的真实链路。

### Phase 2：Policy/审批/审计（把安全边界产品化）

- Policy：
  - global→account→user→facility→directive 覆盖，输出 effective capabilities。
- 审批：
  - 当申请高危能力（如 `NET=UNRESTRICTED`、Host、宿主路径扩展、secrets）进入 `awaiting_approval`。
  - 审批页面展示：命令、cwd、可读写路径、网络策略、将访问的 secret、目标 automation app（macOS）。
- 审计：
  - 形成统一 audit 事件流：requested → approved → executed → artifacts → finished（可导出）。
- 验收：
  - 任意一次 directive 的”为什么允许/为什么拒绝”都能从审计里复盘出来。

### Phase 3：Linux Untrusted 加固（可选 Firecracker microVM）

> Phase 1 已通过 bubblewrap 提供 Untrusted namespace 隔离。Phase 3 是可选的硬件虚拟化加固。

- Nexus：
  - **可选** Firecracker microVM 驱动：在 bwrap 基础上升级为硬件虚拟化隔离（适合多租户 / 最高安全需求场景）。
  - 先只做 `NET=NONE`（无 tap/nft），把 CPU/内存/磁盘隔离跑通（最小化特权面）。
  - facility：block-backed ext4 镜像 attach（virtio-blk），宿主不 mount。
  - baseline（Bootstrap）：先支持 1 个”现成发行版基线”（建议 Ubuntu 24.04 minimal），Nexus 负责准备/缓存 `{guest kernel, rootfs}`，并把 **digests** 写入 directive 元数据（为回放做准备）。
- 依赖策略：
  - 依赖 BYO：用户安装 firecracker+jailer；Nexus `doctor` 校验 `/dev/kvm`、版本、二进制路径。
- 验收：
  - microVM 内能执行基本命令/工具链；默认无网络；diff/工件/日志链路正常。

### Phase 4：Linux Untrusted microVM（NET=ALLOWLIST/UNRESTRICTED + 硬 egress + 少量 TCP）

- Nexus：
  - 引入 nexus-helper（`CAP_NET_ADMIN` 等最小特权）来配置 tap/netns/nftables。
  - 默认强制所有 egress 走 egress-proxy（Nexus 内置或 sidecar），并在 host 侧把“除了 proxy 之外的出站”硬拒绝。
  - allowlist：以 **CONNECT host:port** 为核心做审计与拦截；对 TLS 可选做 SNI 一致性校验（细节见第 7 节）。
  - 端口策略：默认仅 `443`（可选 `80`）；`22/873/自定义端口/内网 CIDR` 需要显式 allowlist，并建议触发审批（至少在 Untrusted 下）。
  - 模板：内置 `ssh.github.com:443`（GitHub SSH over 443）与常见包管理域名模板，降低用户因“太难用”而关闭限制。
- 验收：
  - Untrusted 下：无法直连外网；allowlist 生效；审计里能看到每个域名/端口的访问记录与拒绝原因；额外端口必须走审批/显式授权。

### Phase 5：macOS darwin-automation（只做自动化，不做隔离）

- Nexus：
  - 实现 `darwin-automation` driver：Shortcuts/AppleScript/UI automation 的受控执行器。
  - 把“目标 App/将触发权限/将读写的路径”纳入审批与审计。
  - 提供 `doctor`：检测基础依赖与提示用户完成 TCC 授权（Automation/Accessibility/Screen Recording）。
- 产品文案/UX：
  - 明确：darwin-automation ≈ Host 高危能力，禁止跑不可信任意代码。
- 验收：
  - 在 macOS 上能稳定完成一个端到端自动化案例（打开 App、读信息、导出结果到 workspace 并上传）。

### Phase 6：生产化（可运维、可升级、可扩展）

- 可靠性：
  - nexusd / helper / sandbox 进程的 crash recovery 与幂等（同一 directive 可重试/续跑）。
  - 资源治理：并发上限、cgroup 配额、磁盘配额、超时/取消。
- 运维：
  - 版本管理（Nexus 自升级/回滚）、兼容矩阵、灰度。
  - 观测：健康检查、心跳、关键指标（directive 成功率、时延、资源使用、policy 拒绝原因）。
- 安全：
  - 制品签名校验（Nexus、基线镜像），以及依赖的 SBOM/来源记录。
- 验收：
  - 一组 territory 在长时间运行下稳定，且出现异常时能定位（日志+指标+审计闭环）。

### Phase 7：万能设备抽象（Universal Device Abstraction）

> 详细设计：[`09_nexus_universal_device.md`](09_nexus_universal_device.md)

- Mothership：
  - Territory 种类（`server | desktop | mobile | bridge`）：一等列柱，非标签。
  - 双轨模型：Directive 轨道（代码执行，不变）+ Command 轨道（设备能力，新增）。
  - Command AASM：`queued → dispatched → completed | failed | timed_out | canceled`。
  - BridgeEntity 模型：桥接 territory 的子设备，通过 heartbeat 全量同步。
  - Device Policy 维度：Policy 模型新增 `device` jsonb 列（allowed/denied/approval_required，通配符匹配）。
  - CommandTargetResolver：直接/能力/位置/标签/桥接实体多维路由。
  - CommandDispatcher：三级分发（WebSocket → Push Notification → REST Poll）。
  - Action Cable WebSocket 推送通道（TerritoryChannel）。
  - Enrollment 扩展：`kind`/`platform`/`display_name` 参数，向后兼容（默认 `kind=server`）。
  - Heartbeat 扩展：`capabilities` + `bridge_entities` 同步。
- 安全加固：
  - `FOR UPDATE SKIP LOCKED` 防止 Command 并发竞态。
  - `sanitize_sql_like` 防止 LIKE 通配符注入。
  - AASM 状态机保护（rescue InvalidTransition）。
  - Base64 解码错误处理。
- 验收：
  - 293 测试，933 断言，0 失败。覆盖 Territory device、BridgeEntity、Command、DevicePolicy、CommandDispatcher、CommandTargetResolver、CommandTimeoutJob、E2E 全流程。
  - 真机集成测试通过（aarch64 server + x86_64 desktop）。

### 终极形态定义（你最终想要的”安全 + 易用”）

- Linux：Untrusted 默认 microVM + 硬 egress + 可回放工件/镜像；Trusted/Host 作为显式选择并受审批约束。
- macOS：darwin-automation 作为“自动化节点”能力存在，但其风险边界明确、默认最小权限、全量可审计。
- 控制面（Mothership）：策略/审批/审计一体化，能解释“为什么允许/为什么拒绝/发生了什么”，并能支撑企业合规（审计导出、权限模型、密钥治理）。

---

## 14. 实现选择与分发策略（更新）

> 背景补充：服务端（Mothership）你已确定使用 Ruby。执行端（Nexus）对语言不设限，但要覆盖 Linux（2024+，x86_64/arm64）与 macOS 26（Apple Silicon），并在 Linux 上实现 Untrusted 强隔离（microVM + 硬 egress）。

### 14.1 推荐决策（务实路线）

- **Mothership：Ruby/Rails（固定）**
- **Nexus（产品级）：Go（推荐）或 Rust**
  - 原因：便于做 **单二进制分发**、跨平台构建、系统级能力（KVM/Firecracker、网络/防火墙、cgroups、mount）与长期运行的可靠性。
  - microVM 编排上，Go 生态有成熟的 Firecracker SDK 可直接用；Rust 同样可行但团队熟悉度需评估。
- **Nexus（开发/联调）：Ruby Mini Nexus**
  - 目标：快速推进协议、状态机、日志/工件幂等与 Mothership 联调；
  - 明确定位：默认 **不提供** Untrusted/microVM/硬 egress，仅用于开发与 CI 的契约测试。

### 14.2 如果 Nexus 也想用 Ruby：可以，但要按“产品级依赖”治理 Ruby runtime

Ruby 作为 Nexus 语言的主要挑战是 **分发与可重复性**：

- 不能依赖系统 Ruby（macOS 更不可控，Linux 发行版也会出现版本漂移/依赖不一致）。
- 需要把 Ruby runtime（含 OpenSSL/CA）当作 vendored artifact 来发布与升级：
  - 每个平台/架构一份：`linux-amd64`、`linux-arm64`、`darwin-arm64`。
  - 安装器下载后校验 sha256（或签名），再启动 Nexus。
  - Gems 必须锁定（Gemfile.lock）并尽量减少 native extension（避免编译链依赖）。

> 经验结论：如果你希望“用户机器上尽量少装东西”，Go/Rust 单二进制通常会显著降低支持成本；Ruby 更适合做控制面与快速原型。

### 14.3 关于 Homebrew 的 Portable Ruby：可借鉴“portable runtime”模式，但不建议直接依赖它

你观察得对：`homebrew-portable-ruby` 这个 tap 仓库已经归档；官方说明其内容已迁移进 `Homebrew/brew` 与 `Homebrew/homebrew-core`，Portable Ruby 机制仍在运作（用于在系统 Ruby 不满足要求时为 brew 提供可控运行时）。

Homebrew 的 vendored Portable Ruby 逻辑（以 brew 的行为与日志为准）大致是：

- `brew` 会读取 `vendor/portable-ruby-version` 来决定需要安装的 portable-ruby 版本。
- 下载地址不一定写死在 `install.sh`：实际由 `brew vendor-install` 相关脚本决定，并会从 GHCR 拉取 portable-ruby 的 OCI blob（digest 形式），例如：

```text
https://ghcr.io/v2/homebrew/portable-ruby/portable-ruby/blobs/sha256:<digest>
```

**这对你的启发**：如果你要做 Ruby Nexus，完全可以复刻“portable runtime + 校验 + 自动升级”的模式；但更建议你自己维护运行时包与版本节奏（镜像源、签名、CVE 响应），避免绑定 Homebrew 的发布策略与分发渠道。

---
