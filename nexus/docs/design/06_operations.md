## 15. API 草案（HTTP/JSON，便于独立开发与联调）

> 说明：这里给的是“契约级别”的草案，便于 Nexus 与 Mothership 分工并行推进。
> 未来如果要换成 gRPC streaming，也应保持语义一致（尤其是 lease/幂等/日志分片）。

### 15.1 Enrollment / Territory

> 注：Phase 0 为了跑通闭环，先采用 Decision D16（header auth）。
> Phase 0.5 已支持 CSR 签发与“证书指纹 → territory_id”映射认证（依赖边缘代理注入 fingerprint header）。
> Phase 1 目标：默认切到 mTLS-only（不再接受 header auth）。
> 以 `docs/protocol/conduits_api_openapi.yaml` 为准。

- Phase 0（已实现）：
  - Enrollment token：目前通过 Rails 代码生成（`Conduits::EnrollmentToken.generate!`），尚未提供管理员 API。
  - `POST /conduits/v1/territories/enroll`
    - 入参：`{enroll_token, name?, labels?, metadata?, csr_pem?}`
    - 出参：`{territory_id, config, mtls_client_cert_pem?, ca_bundle_pem?}`
    - 说明：返回的 `territory_id` 用于后续请求的 `X-Nexus-Territory-Id` header（dev only）。
- Phase 0.5（已实现，MVP）：
  - 当 `csr_pem` 传入时，Mothership 签发 client cert，并记录其指纹到 territory。
    - `ca_bundle_pem` 是**签发该 client cert 的 CA 证书**（用于 mTLS 终止层验证 Nexus client cert）；不等同于“验证 Mothership 服务端证书”的 CA bundle。
  - 后续请求可使用边缘代理注入的 `X-Nexus-Client-Cert-Fingerprint` 完成 territory 认证（详见 `CONDUITS_TERRITORY_AUTH_MODE` 配置）。
  - Nexus 侧已提供最小 enrollment CLI（复用 `nexusd`）：
    - `nexusd -config <path> -enroll-token <token> -enroll-with-csr=true -enroll-out-dir ./nexus-credentials`
    - 输出：`{territory_id, client_cert_file, client_key_file, ca_bundle_file}`（JSON），用于写回配置后再启动 daemon。
- Phase 1+（计划）：
  - `POST /conduits/v1/enrollment_tokens`
    - 作用：管理员生成一次性 token（绑定 account，可选 user/labels）。
  - `POST /conduits/v1/territories/enroll`
    - 入参：`{enroll_token, csr_pem, metadata}`
    - 出参：`{territory_id, mtls_client_cert_pem, ca_bundle_pem, config}`

- `POST /conduits/v1/territories/heartbeat`（Phase 0: header auth；Phase 0.5+: fingerprint；Phase 1+: mTLS）
  - 入参：`{nexus_version, labels, capacity, running_directives_count, telemetry?}`
  - 出参：`{ok, territory_id}`（Phase 0）；Phase 1+ 可扩展为 `{server_time, config_overrides}`
  - Phase 0.5 现实说明：当前实现仅持久化 `nexus_version/labels/capacity`；其余字段（如 `running_directives_count/telemetry`）目前接收但忽略。

### 15.2 Poll / Lease / Directive lifecycle（Nexus → Mothership）

- `POST /conduits/v1/polls`（Phase 0: header auth；Phase 0.5+: fingerprint；Phase 1+: mTLS）
  - 入参：`{supported_sandbox_profiles, max_directives_to_claim}`
  - 出参（有任务）：`{directives:[DirectiveSpec...], lease_ttl_seconds}`
  - 出参（无任务）：`{directives:[], retry_after_seconds}`
  - Phase 0.5 现实说明：`supported_sandbox_profiles` 缺省为 `["untrusted"]`；`max_directives_to_claim` 缺省为 1（服务端上限 5）。
  - 实现建议：
    - Phase 0 先用 short poll + `retry_after_seconds` 降低实现复杂度。
    - Phase 1+ 升级为“长轮询”：服务端在超时窗口内等待任务出现（或直到超时），显著降低 QPS 与 DB 压力。

- `POST /conduits/v1/directives/:id/started`（Phase 0: header auth + directive_token；Phase 0.5+: fingerprint + directive_token；Phase 1+: mTLS + directive_token）
  - 入参：`{effective_capabilities_summary, sandbox_version, runtime_ref?, started_at}`
  - 幂等：若 directive 已为 `running` 或已处于终态，重复上报返回 200（duplicate=true）。
  - 冲突：若重复上报携带的 `nexus_version/sandbox_version` 与已记录不一致，返回 409。
  - Phase 0.5 现实说明：当前实现仅记录 `nexus_version/sandbox_version`；其余字段目前接收但忽略。

- `POST /conduits/v1/directives/:id/heartbeat`（Phase 0: header auth + directive_token；Phase 0.5+: fingerprint + directive_token；Phase 1+: mTLS + directive_token）
  - 入参：`{progress, last_output_seq, now}`
  - 作用：续租（Phase 0.5 当前实现仅续租；`progress/last_output_seq/now` 目前接收但忽略）。

- `POST /conduits/v1/directives/:id/log_chunks`（Phase 0: header auth + directive_token；Phase 0.5+: fingerprint + directive_token；Phase 1+: mTLS + directive_token）
  - 入参：`{stream:”stdout”|”stderr”, seq:int, bytes:base64, truncated:false}`
  - 幂等：V1 契约要求重复 `(directive_id, stream, seq)` 安全；Phase 0.5 已实现服务端去重与 `max_output_bytes` 上限。
  - Phase 0.5 现实说明：为容忍网络重试/乱序导致的“finished 后迟到日志”，当前实现允许在 directive 处于 `running` **或终态**时继续上报 `log_chunks`（仍受 `limits.max_output_bytes` 强制上限）。

- `POST /conduits/v1/directives/:id/artifacts`（Phase 1+）
  - 备注：Phase 0 未实现独立 artifacts 上传端点；Phase 0 的工件能力以 diff blob 与少量 manifest 字段占位。

- `POST /conduits/v1/directives/:id/finished`（Phase 0: header auth + directive_token；Phase 0.5+: fingerprint + directive_token；Phase 1+: mTLS + directive_token）
  - 入参：`{exit_code, status, stdout_truncated, stderr_truncated, diff_truncated, snapshot_before, snapshot_after, artifacts_manifest, diff_base64, finished_at}`
  - 幂等：若 directive 已处于终态且 `finished_status` 相同，且 finished payload 一致，重复上报返回 200（duplicate=true）；payload 不一致返回 409。
  - `diff_base64`：使用 **strict base64** 解码；非法 base64 返回 422；解码后字节数必须 ≤ `limits.max_diff_bytes`（缺省 1,048,576 bytes），否则返回 422。
  - Phase 0.5 现实说明：当前实现不持久化 `finished_at`（以服务端接收时间与 state 变更为准），字段保留为 future 兼容。

### 15.3 用户/系统侧 API（提交任务，不依赖 Agent）

> 说明：本节同时包含“当前实现（Phase 0.5）”与“计划（Phase 2+）”的端点草案；请以每条端点的标注为准。

**Phase 0.5（已实现）**：

- `POST /mothership/api/v1/facilities/:id/directives`
  - 入参：`{command, shell?, cwd?, sandbox_profile?, timeout_seconds?, requested_capabilities?, env_allowlist?, env_refs?, limits?}`
  - 返回：`{directive_id, state, created_at}`

- `GET /mothership/api/v1/facilities/:facility_id/directives/:id/log_chunks`
  - 作用：按 `stream+seq` 分页读取 stdout/stderr 分片（用于 UI/调试）。
  - 查询参数：`stream=stdout|stderr`（必填），`after_seq=-1`（默认），`limit=200`（默认，最大 500）。
  - 返回：`chunks:[{seq, bytes_base64, bytesize, truncated, created_at}]` + `next_after_seq` + `stdout_truncated/stderr_truncated`。

- `GET /mothership/api/v1/facilities/:facility_id/directives/:id`
  - 作用：查询 directive 元数据与状态（Phase 0.5 为最小字段集）。

- `GET /mothership/api/v1/facilities/:facility_id/directives`
  - 作用：列出 facility 下最近的 directives（Phase 0.5 默认返回最近 50 条）。

**Phase 2+（计划）**：

- `POST /mothership/api/v1/facilities`
  - `{kind, init:{repo_url?, ref?, template?, import_path?}}`
  - 返回 `facility_id`。

- `POST /mothership/api/v1/directives/:id/approve` / `POST /mothership/api/v1/directives/:id/reject`
  - 作用：审批高危能力（Host、挂载宿主路径、NET=UNRESTRICTED、secrets 等）。

- `POST /mothership/api/v1/directives/:id/cancel`
  - 作用：请求 Nexus 终止该 directive（best-effort + 审计）。

### 15.4 版本协商（避免 Nexus/Mothership 升级互相踩）

- Nexus `heartbeat` 上报 `nexus_version` 与 `protocol_version`。
- Mothership 下发 `min_supported_nexus_version`，不满足则拒绝 lease 并提示升级。

### 15.5 错误响应格式（Phase 0.5 当前实现）

> Phase 0.5 尚未实现“统一错误对象（code/message/details）”，目前主要使用扁平结构，便于联调：
>
> - Conduits API：`{ error: string, detail?: string }`
> - Mothership 用户 API：`{ error: string, detail?: string, details?: string[] }`（validation 失败时常见）

#### 错误码分类与 Nexus 重试策略

| HTTP Status | 含义 | Nexus 行为 |
|-------------|------|-----------|
| 401 | 认证失败（证书/token 无效） | **不重试**，日志报警 |
| 403 | 权限不足（territory 被禁用等） | **不重试**，日志报警 |
| 404 | directive 不存在（已取消/回收） | **不重试**，放弃该 directive |
| 409 | 状态冲突（lease 已被其他 territory 领取） | **不重试**，放弃该 directive |
| 422 | 参数/业务校验失败（status/base64/capabilities 等） | **不重试**，标记 failed |
| 429 | 限流 | **重试**，遵守 `Retry-After` header |
| 502/503 | 服务暂不可用 | **重试**，指数退避（初始 2s，最大 60s） |
| 504 | 网关超时 | **重试**，同上 |

约定：
- 所有 5xx 与 429 为 retryable；所有 4xx（除 429）为 fatal。
- Nexus 对 retryable 错误最多重试 **5 次**；超过后放弃本次操作并记日志。
- `log_chunks` 上传失败不阻塞 directive 执行（best-effort），但必须可重试且幂等（重复 seq 安全）。

> Phase 0.5 现实说明（实现状态，2026-02-23）：
> - Go daemon 已对 `started`/`finished` 实现最多 5 次的 retry（指数退避；尊重 `Retry-After`）。
> - `polls`：未做“同一次 poll 请求”的自动重试（避免重复 claim）；仅在外层循环里按 `retry_after_seconds`/backoff 继续 poll。
> - `log_chunks`：仍为 best-effort（失败会丢失该片日志；协议与服务端幂等保证允许将来增强重试/队列）。

### 15.6 Rate Limiting 参数（V1 常量）

> Phase 0.5 现实说明（实现状态，2026-02-23）：
> - 已启用 `POST /territories/enroll` 的 per-IP 限流（Rack::Attack，10/小时），返回 `429 Too Many Requests` + `Retry-After`。
> - 其余端点的限流暂未启用（仍按 V1 常量建议值保留在表中）。
>
> 备注：Rack::Attack 使用 `Rails.cache` 作为计数存储；若以多进程/多机部署，应配置共享 cache store（例如 Redis）以保证限流全局一致。

| 端点 | 限流维度 | 限值 | 备注 |
|------|---------|------|------|
| `POST /territories/enroll` | per-IP | 10/小时 | 建议：先启用（防 DoS） |
| `POST /polls` | per-territory | 60/分钟 | MVP 后启用 |
| `POST /directives/:id/heartbeat` | per-directive | 30/分钟 | MVP 后启用 |
| `POST /directives/:id/log_chunks` | per-directive | 300/分钟 | MVP 后启用 |

超限返回 `429 Too Many Requests` + `Retry-After` header。

### 15.7 存储配额与清理策略

> Phase 0.5 现实说明（当前实现状态，2026-02-23）：
> - `log_chunks` 已落库为 `conduits_log_chunks` 分片表（按 `(directive_id, stream, seq)` 幂等去重），并强制 `limits.max_output_bytes`（缺省 **2,000,000 bytes**，stdout+stderr 合计）上限。
> - lease 回收 reaper 已实现并接入定时调度。
> - 已采用 **SolidQueue** 作为定时调度机制：recurring 任务定义在 `mothership/config/recurring.yml`，并由 `mothership/bin/jobs` 运行（或用 `SOLID_QUEUE_IN_PUMA=1` 交给 Puma plugin 托管）。
> - TTL 清理 job 已实现为 **小批量渐进式清理**（避免 I/O 尖峰），默认保留 30 天。

#### 可配置项（ENV，V1，可调整）

```bash
# === Mothership 端（Jobs） ===
# conduits_log_chunks TTL 清理
CONDUITS_LOG_CHUNK_TTL_DAYS=30
CONDUITS_LOG_CHUNK_CLEANUP_BATCH_SIZE=1000
CONDUITS_LOG_CHUNK_CLEANUP_MAX_BATCHES=10
CONDUITS_LOG_CHUNK_CLEANUP_SLEEP_SECONDS=0.05

# ActiveStorage diff blob TTL 清理
CONDUITS_DIFF_BLOB_TTL_DAYS=30
CONDUITS_DIFF_BLOB_CLEANUP_BATCH_SIZE=100
CONDUITS_DIFF_BLOB_CLEANUP_SLEEP_SECONDS=0.05

# === Nexus 端（建议常量草案；未全部实现）===
FACILITY_QUOTA_BYTES=10737418240  # 10 GiB（单个 facility 磁盘配额）
MAX_OUTPUT_BYTES=2000000          # 2,000,000 bytes（stdout+stderr 合计上限；缺省值）
MAX_DIFF_BYTES=1048576            # 1 MiB（diff 上限）
```

#### 清理策略

- **渐进式增量清理**（不集中清理，避免磁盘 I/O 尖峰）：
  - Mothership：分别对 ActiveStorage diff blob 与 `conduits_log_chunks` 做批量清理（recurring + batch 上限 + 可配置 sleep）。
  - 参考 OpenClaw：每次 prune 间隔 ≥ 5 分钟，避免密集清理。
- **diff blob（ActiveStorage）保留 30 天**后自动标记为 purge-ready。
- **log_chunks（DB）保留 30 天**后删除（并在 UI 中提示“日志已过期”）。
- **传输压缩（可选增强）**：可在 Phase 1+ 增加 `Content-Encoding: gzip`，减少日志上传带宽。

---

## 16. 调度、隔离与资源模型（更细的边界）

### 16.1 调度原则（最小可用版）

- **硬约束**：
  - territory 必须属于同一 `account_id`（或共享池但仅限 Untrusted profile）。
  - territory labels 必须满足 directive 的 profile/OS/arch 要求。
  - facility 的 `territory_id` 绑定时，directive 默认落在同一 territory（避免搬运）。
- **软约束**：
  - capacity：并发上限、CPU/内存余量。
  - 亲和：优先选择最近有该 facility 缓存的 territory。
- **decommissioned**：
  - territory 进入 `decommissioned` 后不再分配新 directive；当前 directive 允许完成或超时回收。

### 16.2 Facility 生命周期（创建/迁移/清理）

- 创建：
  - `empty`：创建空目录（适合办公自动化/脚本生成）。
  - `repo`：工作区用于代码仓库。`repo_url` 为辅助性元数据（supplement），非必须。
    - 有 `repo_url` 且目录为空 → Nexus 在首条 directive 的 prepare 阶段自动 clone（便捷行为）。
    - 无 `repo_url` 或目录非空 → 跳过自动 clone（Agent 或用户手动初始化）。
    - 设计原则：聪明的 Agent 发现空目录时通常会自行 git clone 或引导用户准备环境，因此 `repo_url` 定位为"提示 + 加速"而非前置条件。
  - `imported_path`：导入宿主路径（只允许 Trusted/Host + 审批 + 只读默认）。
- 清理：
  - 按 retention_policy（TTL/空间水位）自动归档/清理。
  - 归档：打包 facility → 对象存储（可选），用于迁移或回滚。
- 迁移（后续增强）：
  - 当 territory 下线或需要扩容时，将归档包恢复到另一 territory。

### 16.3 资源限制的最低要求

- `timeout_seconds`：到时强制终止沙箱。
- `max_output_bytes`：日志硬上限，避免 DB/对象存储被刷爆。
- `cpu/memory`：
  - microVM：通过 VM 配置限制。
  - 容器：通过 cgroups（rootless 可能受限，需在可信模式下接受限制弱一些并提示）。
- `disk_mb`：
  - facility 配额（镜像大小/卷配额/项目配额），至少要能阻止”打满整盘”。

---

## 17. “不过度复杂但足够安全”的 UX 规则（避免用户绕过）

- 默认：`Untrusted + NET=NONE`，并解释原因（不可信代码常见风险）。
- 当工具调用被网络拦截时：
  - 不弹一堆术语，只给“被阻止的域名列表”+“一键允许并重试”。
  - allowlist 的范围选择只给两档：`仅本次` / `对该 facility 永久`。
- 当请求高危能力（Host/宿主路径写/NET=UNRESTRICTED/secrets）时：
  - 强制审批（不能一键永久允许）。
  - 审批页只展示 5 件事：命令、cwd、可读写路径、网络模式、将注入的 secrets（名称，不显示值）。
  - 审批记录写审计事件，且可回看。
- macOS Host Automation：
  - UI 必须显著提示“将操作你的 macOS 系统/应用，风险等同于本地脚本”。

---

## 18. Nexus 在 Monolith 仓库中的组织与演进策略

你已决定：
- Mothership 必须作为 Cybros 内部模块/namespace（Monolith）。
- Nexus 与 Cybros 进度可能不同步，但希望同仓库便于开发期联调。

推荐仓库布局（示例）：

- Go shared packages (at module root):
  - `daemon/`：产品级 Nexus（目标：支持 Untrusted/microVM、强制网络出口等）。
  - `protocol/`：协议契约（OpenAPI/JSON schema）与兼容性测试用例。
  - `client/`, `config/`, `logstream/`, `netpolicy/`, `sandbox/`, `version/`：其他共享包。
- `nexus-linux/`, `nexus-macos/`：平台入口与打包。

演进原则：
- **协议先行**：所有变更先更新 schema/OpenAPI，再更新 Mothership 与 Nexus。
- **兼容窗口**：Mothership 保持 “N-1 Nexus 兼容”（至少兼容上一个 minor 版本），Nexus 也应能与新旧 Mothership 协商（见第 15.4 节）。
- **Mini Nexus 的职责边界**：
  - 用于 API 联调与回归；不追求强隔离、不默认允许 Untrusted。
  - 任何安全能力（microVM/egress 强制）必须在产品级 Nexus 中实现并验证。

---

## 19. Territory capability / role / tags（主机能力标注与自动发现）

### 19.1 目标

- 让用户在“添加主机/环境”时能设置：
  - **角色**（role）：例如 `gpu`, `storage`, `office`, `home`, `ci`, `prod-like` 等。
  - **能力**（capability）：例如 `gpu=nvidia`, `cuda=12`, `ram_gb=64`。
- 让系统（Nexus 或后续 Agent）能自动发现并回填能力标签，便于调度与决策。

### 19.2 重要边界（不要把 tags 当作强安全边界）

- capability/tags 主要用于 **调度与体验**，而不是单独作为安全边界：
  - 即使 territory 标记 `office`，仍需通过 network policy/审批控制内网访问。
  - 即使 territory 标记 `gpu`，也不能因此绕过 Untrusted 的隔离默认值。
- 来源需要区分并可审计：
  - `manual`：用户手动设置
  - `observed`：Nexus 自动探测（例如读取系统信息/执行受控 probe）
  - `agent_suggested`：Agent 提议（必须用户确认后才落地为有效标签）

### 19.3 自动发现方式（不依赖 Agent，也不引入高风险）

从低风险开始：
- Nexus 在 `heartbeat` 上报基础事实（facts）：
  - OS/arch/kernel、CPU 核数、内存/磁盘、容器运行时可用性
  - GPU：检测 `/dev/nvidia*`、`nvidia-smi` 是否存在（存在才声明）
  - KVM：`/dev/kvm` 可用性（决定能否跑 Firecracker）
  - macOS：仅声明支持 `darwin-automation`；并做最小权限探测（例如 Apple Events/Automation 是否已获授权，未授权则在 UI 中提示用户完成授权）
- Mothership 将事实转成 `labels/capabilities`（带 `observed_at` 与 `source=observed`）。

### 19.4 调度与权限的结合

- DirectiveSpec 支持 `requirements`（软/硬）：
  - 硬要求：必须满足 `requires: ["gpu.nvidia"]`
  - 软偏好：优先 `prefer: ["location.office"]`
- 同时引入 **territory roles** 做访问控制：
  - 只有 role=`office` 的 territory 才允许申请 `NET=ALLOWLIST(internal domains)`，并且需要审批。
  - role=`prod` 的 territory 默认拒绝所有 host/profile 与写入宿主路径的能力。

---

## 20. 环境配置/Provisioning（Agent 可协助，但默认独立可用）

### 20.1 目标

帮助用户把目标主机/工作区配置到“可运行任务”的状态（安装软件、拉起服务、配置凭据），同时避免安全失控。

### 20.2 安全前提

- Provisioning 属于高风险操作，必须满足：
  - 仅在 `Trusted` 或 `Host` profile 下执行（Untrusted 禁止）。
  - 默认需要审批（至少第一次/每次变更）。
  - **声明式/幂等**（可重复运行，结果一致）。
  - 记录变更摘要（安装了什么包、改了哪些配置、写了哪些文件）。

### 20.3 Recipe 模型（建议）

- `ProvisioningRecipe`：
  - 输入：目标（territory 或 facility）、期望能力（ruby/node/docker/cuda 等）、网络策略、secrets refs
  - 输出：安装/配置步骤（脚本或一组受控命令）
- 执行模式：
  1) `plan`（只生成计划，不修改）
  2) `apply`（执行修改）
  3) `verify`（验证能力是否具备）

### 20.4 “降低用户绕过安全”的产品策略

- 优先把依赖装进容器镜像/VM 镜像（workspace 层），减少在宿主装软件。
- 只有当需要宿主能力（GPU driver、企业 VPN、设备访问）时才做 host provisioning。

---

## 21. 主机监控与资源上报（Telemetry）

### 21.1 目标

- 让用户知道“接入的主机是否在线、能否执行、资源是否紧张”。
- 为调度提供输入（capacity/负载），并能对异常（掉线、磁盘不足）做告警。

### 21.2 最小实现（MVP）

Nexus 在 `heartbeat` 上报：
- `last_seen_at`
- `running_directives_count`
- `cpu_load`、`mem_used/total`、`disk_used/total`（至少 facility 根盘）
- `sandbox_inventory`（支持的 profiles、microVM/container 可用性、关键版本）

Mothership 提供：
- territory 列表页：在线/离线、最近心跳、负载、运行中的 directives
- facility 列表页：大小、最近访问、配额水位
- directive 详情页：实际资源使用摘要（可选）

### 21.3 进阶（可选）

- Prometheus exporter（Nexus/Mothership）+ Grafana（时序监控）。
- 异常策略：心跳超时自动标记 offline；自动 decommissioned；低磁盘自动拒绝新 directive。


---

## 22. 开发落地踩坑清单（务必提前规避）

> 这部分重点是“实现时最容易踩坑、但踩了会很痛”的点；建议作为 PR checklist。

### 22.1 网络策略（最容易变成假安全）

1) **仅设置 `HTTP(S)_PROXY` ≠ 强限制**（Trusted/Host）：进程可以绕过代理直连。
   - 结论：只有 Untrusted（microVM）才能给出“硬限制”安全承诺；其它 profile 必须在 UI/审计里明确标注为软限制。
2) **CONNECT 的语义是纯 TCP 隧道**：代理成功后会“盲转发”两端字节流；因此 allowlist 只能在 `host:port` 级别做控制。
3) **SSH/Rsync 走代理的可用性坑**：
   - GitHub 官方支持 `ssh.github.com:443` 绕过 22 端口封锁，但客户端需要配置 `~/.ssh/config`（或 ProxyCommand/wrapper）。
   - 结论：MVP 里不要假设“加了 allowlist 就能用 SSH”；要么只推荐 HTTPS git，要么在 CLI/文档里给出明确配置。
4) **DNS 是常见绕过通道**：即便 TCP 都被拦，也可能通过 DNS 外传/DoH 绕过。
   - 建议：Untrusted 下明确 DNS 策略（只允许到宿主 stub/指定 resolver；禁止 DoH/DoT；记录 DNS 审计）。
5) **IPv6 旁路**：很多实现只封 IPv4，IPv6 直接绕过。
   - 建议：要么明确禁用 IPv6，要么把 IPv6 规则一起做完整（microVM 与宿主防火墙两侧都要考虑）。
6) **QUIC/HTTP3（UDP 443）**：如果你放行了 UDP 443，HTTPS 可能走 QUIC 绕开 HTTP 代理路径。
   - 建议：V1 直接不支持 UDP allowlist；Untrusted 下只允许 TCP 到 proxy。

### 22.2 allowlist 解析与匹配（细节不统一会出事故）

1) **域名规范化**：大小写、尾点、IDN/punycode（`bücher.de` vs `xn--bcher-kva.de`）必须统一处理，否则 allowlist 可能被绕过或误拦。
2) **通配匹配的边界**：必须按 7.6.1 定义的规则实现（`*.example.com` 不匹配 `example.com`）。
3) **禁止 IP 字面量**：否则用户会用 IP 绕过域名审计；同时 SNI/证书也难解释。

### 22.3 nftables/iptables 落地（规则污染与清理）

1) **不要污染用户现有防火墙规则**：必须使用独立 table/chain，并给规则打可识别 comment/tag。
2) **崩溃清理**：Nexus 异常退出后残留规则会导致用户“断网”或安全策略失效。
   - 建议：把规则生命周期与 directive 生命周期绑定；systemd `ExecStopPost`/watchdog 做兜底清理。
3) **并发竞争**：多 directive 并发时规则增删要做到幂等与可重入（建议用 nft set + reference counting）。

### 22.4 microVM（Firecracker）落地

1) **/dev/kvm 权限与架构差异**：Firecracker 需要 KVM，并支持 x86_64 与 aarch64；安装脚本必须检查 `/dev/kvm` 可用性与权限。
2) **生产环境建议用 jailer**：按官方生产主机建议做隔离与降权，并保持宿主/微码更新。
3) **facility 用块设备**：你已经收敛到 virtio-blk + ext4 镜像；实现时注意 fsck/挂载失败恢复、以及快照/清理的原子性。

### 22.5 平台凭据存储（别用环境变量糊弄）

1) **避免把私钥/证书放进环境变量**：容易被子进程、日志、crash dump 泄漏。
2) **systemd credentials 作为增强**：可把敏感材料以 credential 文件形式注入，并支持加密载入（`LoadCredentialEncrypted=` 等）。
3) **权限与备份**：Linux 上凭据目录必须 600/700；macOS 上优先用 Keychain（避免被 Time Machine/Spotlight 扫到）。

### 22.6 darwin-automation（权限、可用性与用户预期）

1) **TCC 权限是最大的不确定性**：Automation/Accessibility/Screen Recording 等权限没有获得就会“看起来能跑但处处失败”。
2) **企业设备靠 PPPC profile 管理**：可用 MDM 下发 PPPC（Privacy Preferences Policy Control）payload 预授权，但并非所有权限都能真正做到完全静默。
3) **建议做 nexus doctor**：在 macOS 上提供自检命令，明确告诉用户缺了哪些权限、怎么打开。

### 22.7 协议兼容与版本演进

1) **严格校验 + 兼容窗口**：Mothership/Nexus 必须有 `protocol_version` 与兼容策略；否则一升级就互相打爆。
2) **对未知字段要有策略**：建议保留 `x_ext` 扩展区；未知字段默认忽略但保留日志提示（方便排障）。

### 22.8 观测与排障

1) **把“为什么被拦截”结构化返回**：blocked host/port + reason_code + 建议动作（加入 allowlist/申请审批）。
2) **日志要有 backpressure**：避免被 stdout 洪泛拖死 Nexus/控制面。
3) **所有安全关键决策都要落审计**：尤其是“放开网络/非默认端口/host automation”。
