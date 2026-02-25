## 9. DirectiveSpec 协议（控制面与 Nexus 的契约）

> 目标：让 Mothership 与 Nexus 可独立演进；将来接入 AgentCore 只需生成 DirectiveSpec。

### 9.1 DirectiveSpec（示例）

```json
{
  "directive_id": "01J...base36",
  "facility": { "id": "01J...", "mount": "/workspace" },
  "sandbox_profile": "untrusted",
  "command": "bundle exec rails test",
  "shell": "/bin/sh",
  "cwd": "/workspace",
  "timeout_seconds": 900,
  "limits": { "cpu": 2, "memory_mb": 4096, "disk_mb": 20480, "max_output_bytes": 2000000 },
  "capabilities": {
    "fs": { "read": ["workspace:**"], "write": ["workspace:**"] },
    "net": { "mode": "allowlist", "allow": ["rubygems.org:443", "github.com:443"] },
    "env": { "allow": ["RAILS_ENV"], "secrets": ["secretref:github_token"] }
  },
  "runtime": {
    "type": "oci",
    "image": "ghcr.io/cybros/sandbox@sha256:...",
    "platform": "linux/arm64"
  },
  "artifacts": {
    "collect": ["tmp/test-reports/**", "log/test.log"],
    "always_diff": true
  }
}
```

> 备注：`runtime` 字段是建议新增，用于“可回放”。microVM 模式下可记录 `{kernel_digest, rootfs_digest}`；容器模式记录 OCI digest。

### 9.2 状态与幂等

- Nexus 领取任务：`lease(directive_id, territory_id, ttl)`
- Nexus 执行流程：
  1. **started**（上报沙箱版本、实际生效能力摘要；并将 directive 从 `leased → running`，以便后续心跳/日志上传）
  2. **prepare**（可选）：若 facility 目录为空且 `repo_url` 有值，自动 clone（prepare 输出通过 log_chunks 进入同一日志流）
  3. **执行命令**
  4. **log_chunk(seq, stream, bytes)**（可重试；按 seq 去重）
  5. **heartbeat(progress)** → 返回 `{cancel_requested, lease_renewed}`（续租 + 取消通知）
  6. **finished(exit_code, artifacts_manifest, truncated_flags)**
- Mothership 保证：
  - `directive_id` 幂等
  - `log_chunk` 去重（按 `(directive_id, seq, stream)`）
    - Phase 0.5：允许在 directive 处于 `running` **或终态**时继续上报 `log_chunks`，用于容忍网络重试/乱序导致的“finished 后迟到日志”（仍受 `limits.max_output_bytes` 强制上限）。
  - `started` 幂等：重复上报在 directive 已处于 `running` 或已处于终态时返回 200（duplicate），用于覆盖网络重试/乱序导致的 “started 晚于 finished”。
    - 若重复上报携带的 `nexus_version/sandbox_version` 与已记录不一致，返回 409（用于捕获重试内容漂移/并发 bug）。
  - `finished` 幂等：重复上报在 directive 已处于终态且 `finished_status` 相同 **且 payload 完全一致**则返回 200（duplicate）；若 payload 不一致返回 409（用于捕获“重试但内容变了”的 bug）。
    - 目前实现会计算并持久化 `result_hash`（对规范化后的 finished payload 取 SHA256），用于检测重复上报的内容一致性。
    - 若 `started` 丢失导致 directive 仍为 `leased`，`finished` 允许隐式 `leased → running → terminal`。

> Phase 0.5 现实说明（实现状态）：
> - `prepare`（repo_url auto-clone）已实现（Go daemon）：
>   - 当 facility 目录为空且 `repo_url` 有值时，Nexus 执行 `git clone --depth 1 <repo_url> .`（禁用交互 prompt：`GIT_TERMINAL_PROMPT=0`）。
>   - prepare 的 stdout/stderr 会通过 `log_chunks` 上传并与命令执行日志共享同一 seq 序列。
>   - prepare 失败会在 stderr 写入 `[prepare] failed: ...`，并直接上报 `finished(status: "failed")`（不再执行用户命令）。
> - `log_chunks` 已实现幂等与上限：服务端以 `(directive_id, stream, seq)` 唯一键去重，并按 `limits.max_output_bytes`（缺省 2,000,000）执行截断标记；日志以分片表存储（避免 ActiveStorage “追加”带来的下载+重传放大）。
> - head/tail buffer 仍未实现（当前策略为：达到上限后继续读取但不再持久化/上传）。

### 9.3 Directive 取消（端到端）

> Nexus 是 Pull 模型，不接收推送。取消信号通过 heartbeat 响应传递。

> Phase 0.5 现实说明（实现状态，2026-02-23）：
> - 目前**未实现** directive cancel 的用户侧 API，也未实现 `cancel_requested` 状态。
> - `POST /conduits/v1/directives/:id/heartbeat` 的响应中 `cancel_requested` 目前恒为 `false`（见 `Conduits::Directive#cancel_requested?`）。
>
> 下述流程作为 Phase 2+ 的契约草案保留。

流程：
1. 用户调用 `POST /mothership/api/v1/directives/:id/cancel`，Mothership 标记 directive 为 `cancel_requested`。
2. Nexus 的下一次 `heartbeat` 响应中包含 `cancel_requested: true`。
3. Nexus 收到取消信号后：
   - 向沙箱进程发送 **SIGTERM**。
   - 等待 **grace period（10 秒）**。
   - 若进程未退出，**强杀**（SIGKILL / 直接终止 VM/容器）。
4. Nexus 上报 `finished` 并设置 `status: "canceled"`。

取消延迟 = heartbeat 间隔（建议 ≤ 5 秒），因此最坏情况取消延迟约 5+10=15 秒。

### 9.4 协议编码约定（V1，冻结）

> 提前统一，避免实现时不一致导致调试困难。

- **时间**：所有时间字段使用 **RFC 3339 UTC**（例如 `2026-02-23T12:00:00Z`），不允许本地时区偏移。
- **Base64**：`log_chunk.bytes` 使用 **标准 base64 编码**（`+/=`，非 URL-safe），与 Go `encoding/base64.StdEncoding` 一致。
- **大二进制**：
  - diff：Phase 0.5 当前实现为 `finished.diff_base64`（**strict base64**）随 JSON 上传，Mothership 解码后作为 `diff_blob`（ActiveStorage）保存。
    - 限制：解码后的 diff 最大字节数由 `limits.max_diff_bytes` 控制（缺省 1,048,576 bytes）；超过上限返回 422。
    - Future：可迁移为预签名上传 URL（S3/MinIO）或直传对象存储（减少控制面带宽/内存压力）。
  - stdout/stderr：通过 `log_chunks` 分片上传并在服务端去重/限流（Phase 0.5 起不再用 ActiveStorage 做“追加”）。
- **字符串编码**：所有 JSON 均为 **UTF-8**。
- **未知字段**：接收方必须容忍并忽略未知字段（forward compatibility），但建议打日志提示（方便排障）。
- **空值 vs 缺失**：字段缺失（omitted）与 `null` 语义相同，均表示"未设置/使用默认值"。

---

## 10. 可靠性与边界情况（Checklist）

### 10.1 NAT/内网/穿透

**场景 A：控制面在云（推荐）**
- Nexus 出站连云端：天然支持 NAT/内网。

**场景 B：控制面在企业内网**
- Nexus 也在同内网：直连即可。
- Nexus 在受限网络：配置企业 HTTP(S) 代理访问 Mothership。

**场景 C：控制面在本地开发机（Docker Compose），Nexus 在外部网络**
- 默认不可达（本地无公网入口）。
- 推荐方案（按易用排序）：
  1) Tailscale/Headscale（私有 VPN）：为控制面与 Nexus 建立同一 overlay 网络。
  2) Cloudflare Tunnel / ngrok / frp：给本地控制面暴露临时公网入口。
  3) 未来可选：官方 Relay 服务（双向出站 WebSocket，中继转发）。

### 10.2 Nexus 掉线/重启

- lease 到期应自动回收：directive 回到 `queued` 或 `retryable_failed`。
- log_chunks 应支持幂等重试（按 seq 去重），避免重试导致输出重复与存储放大。

> Phase 0.5 现实说明（实现状态）：
> - lease 过期回收：已提供 reaper（service/job），能把 `leased` 且过期的 directive 退回 `queued` 并解锁 facility；并已通过 **SolidQueue recurring** 接入定时调度（默认每分钟）。
> - log_chunks：已实现 seq 去重与服务端输出上限（见 §9.2）。
> - TTL 清理（默认 30 天）已实现并接入 recurring：
>   - `Conduits::LogChunkCleanupJob`（每小时）
>   - `Conduits::DiffBlobCleanupJob`（每日）

#### 10.2.1 Nexus 生命周期管理

**优雅关闭（SIGTERM / decommissioned）**：
1. 停止接受新 directive（不再 poll）。
2. 对所有正在执行的 directive：向 sandbox 进程发送 **SIGTERM**。
3. 等待 **grace period（30 秒）**，让进程自行退出。
4. 未退出的进程 **SIGKILL** 强杀。
5. 对所有 directive 上报 `finished(status: "canceled")`。
6. 退出。

**Crash 后重启（孤儿进程清理）**：
- Nexus 重启时**杀掉所有孤儿 sandbox 进程**，而非尝试恢复。
- 理由：crash 后内存状态全丢（directive ID、token、heartbeat 定时器），无法恢复 heartbeat 和输出捕获。lease 会在 Mothership 侧超时，Mothership 会重新分配 directive。
- Linux 实现：`prctl(PR_SET_DEATHSIG, SIGTERM)` 确保父进程死亡时子进程收到信号。
- 启动时额外检查：扫描 `facilities/` 目录下是否有残留的 PID 文件，有则 kill 并清理。
- **Phase 6 增强**：如需"恢复执行"，需设计 checkpoint/resume 机制（把 directive 状态持久化到磁盘）。

**Nexus 启动时 presence 注册**：
- Nexus 启动后应向 Mothership 发送 `territories/heartbeat`（包含 `nexus_version`、labels、capacity）。
- Mothership 更新 territory 状态为 `online`。
- **Rate limit（已实现）**：Mothership 对 enrollment 端点限流（每 IP 每小时 ≤ 10 次），防止 DoS（Rack::Attack）。

### 10.3 大日志/无限输出

- `max_output_bytes` 硬上限（默认 **2,000,000 bytes**，**stdout+stderr 合计**），超限截断并在 `finished` 上报时标记 `stdout_truncated/stderr_truncated`。
- **Head/Tail Buffer 策略**（参考 Codex）：超限时保留前 N 字节 + 后 N 字节（各 50%），中间插入 `[... truncated ...]` 标记。比单纯截断更有调试价值。
- UI 只展示尾部 + 提供下载完整（若已保存到对象存储）。

> Phase 0.5 现实说明（实现状态）：
> - Nexus 侧目前为“达到上限后不再上传、继续读取并丢弃”模式；未实现 head/tail buffer。
> - Mothership 侧已强制 `max_output_bytes`，并把 stdout/stderr 以分片表（`conduits_log_chunks`）存储与去重；不再使用 ActiveStorage 做“追加”。
> - Future：如需“可下载的单文件完整日志”，可在 finished 时将分片定稿合并为单个 blob（对象存储），或提供按 seq 流式拉取。

### 10.4 磁盘打满

- facility 配额（soft/hard）。
- directive 临时目录独立配额。
- 超限时终止 directive 并标记 `failed(disk_quota_exceeded)`。

### 10.5 并发写冲突

- facility 级互斥锁：同一 facility 同时只允许一个 `running` directive。
- 支持”只读 directive”（例如索引/扫描）以共享并发（后续增强）。

### 10.5.1 Facility 状态快照（repo 类型）

> 多次 directive 共享同一 facility 时，避免 git 脏状态导致 diff 基准不明确。

- **repo facility**：Nexus 在每次 directive 开始前记录 `HEAD` commit hash（`snapshot_before`），directive 结束后记录新的 `HEAD`（`snapshot_after`）。两个 hash 写入 `finished` 上报。
- **diff 基准**：`git diff <snapshot_before>...<snapshot_after>` 作为本次 directive 的变更。若 directive 没有产生 commit，则用 `git diff` 对比工作树与 `snapshot_before`。
- **非 repo facility**：Phase 1 暂不产出目录级 diff；后续可引入 rsync-style 目录快照或者可选的 filesystem snapshot（ZFS/btrfs snapshot、overlay diff 等）。
- **Diff 大小上限**：1 MiB。超过上限应由 Nexus 生成截断 diff 并在 `finished` 上报 `diff_truncated: true`（例如保留前后各 512 KB）；二进制文件在 diff 中只记录路径和大小（不 inline 内容）。

> Phase 0.5 现实说明（实现状态）：
> - 目前 Mothership 仅存储 `snapshot_before/snapshot_after/diff_truncated`（若 Nexus 在 `finished` 中上报），不负责生成 diff 或做 server-side 截断。
> - `diff_base64` 的大小由服务端按 `limits.max_diff_bytes`（缺省 1,048,576 bytes）强制；若 Nexus 上传超限 diff，Mothership 返回 422。

### 10.5.2 执行环境标准化

> 参考 Codex，所有 sandbox 执行必须注入标准化环境变量，确保输出可解析且行为可预测。

Nexus 在执行任何 directive 命令前注入：

```
NO_COLOR=1              # 禁用终端颜色转义
TERM=dumb               # 禁用交互式终端特性
LANG=C.UTF-8            # 统一 locale
LC_ALL=C.UTF-8          # 覆盖所有 locale 类别
PAGER=cat               # 禁用分页器
GIT_PAGER=cat           # 禁用 git 分页器
CYBROS_NEXUS=1          # 标识 Nexus 执行环境
```

若将来实现 DirectiveSpec 的 `capabilities.env`/显式 env 注入，上述变量应作为“默认值”，允许 directive 侧覆写。
（Phase 0.5 现实说明：当前尚未实现 directive 侧 env 注入，因此这些变量会覆盖宿主继承环境，保证输出稳定。）

> Phase 0.5 现实说明（实现状态，2026-02-23）：
> - 以上变量已在 Go daemon 的 env 注入中实现；
> - locale：Linux 使用 `C.UTF-8`，Darwin 使用 `en_US.UTF-8`（避免 macOS 上 `C.UTF-8` 不存在导致的工具告警）。

### 10.5.3 Exit Code 约定

| 场景 | Exit Code | 说明 |
|------|-----------|------|
| 正常退出 | 0-125 | 进程自身返回 |
| Timeout 强杀 | 124 | 达到 `timeout_seconds` 上限 |
| 信号终止 | 128+N | 例如 SIGTERM=143, SIGKILL=137 |
| Cancel（正常退出） | 0 或非零 | 进程收到 SIGTERM 后自行退出 |
| Cancel（强杀） | 137 | grace period 后 SIGKILL |
| Disk quota exceeded | 125 | Nexus 检测到配额超限后终止 |

### 10.6 时钟漂移

- lease/TTL 以服务端时间为准；Nexus 上报仅作为建议。

### 10.7 Credentials / Secrets（按优先级拆分）

> 说明：这里把“平台自身需要的凭据”与“用户业务 secrets”拆开。
> 你已确认：MVP **优先把 Nexus 运行所需凭据做到安全优先**；用户 secrets 先留接口，但作为 future plan，不阻塞主线。

#### 10.7.1 平台凭据（MVP 必做，安全优先）

平台凭据指 Nexus 为了与 Mothership 建立信任、领取任务、上传工件而必须持有的材料，例如：

- Enrollment 一次性 token（只用于首次注册/换证，短期有效）
- Nexus 身份证书（mTLS client cert/key）
- `directive_token`（短期，绑定 directive_id/capabilities，用于上传日志/工件/心跳）

设计要点：

- **短期化**：所有可短期化的都短期化（directive_token/上传 URL/临时凭据），降低泄漏影响面。
- **可撤销**：Mothership 能一键禁用 territory/cert（CRL/denylist/版本号轮换均可）。
- **本地安全存储**：
  - Linux：`/var/lib/cybros-nexus/credentials/*`（600；归属 nexus 用户或 root），并建议提供 systemd credentials 接入（可选增强：`LoadCredentialEncrypted=` 让私钥以“非环境变量文件”形式注入）。
  - macOS：Keychain（不要把私钥明文写入可被 Time Machine/Spotlight 扫到的位置）。
- **输出与工件防泄漏**：平台凭据严禁写入 stdout/stderr；Nexus 在日志链路上做保底 redaction（关键前缀/PEM 头等）。

#### 10.7.2 用户业务 secrets（Future plan，不阻塞 MVP）

用户 secrets 指业务侧需要的凭据，例如：

- GitHub token / Deploy Key
- SSH 私钥、云平台 API Key、第三方服务 Token 等

设计方向（先写进方案，后续排期实现）：

- 控制面只存 **引用**（`secret_ref`），不存明文；Nexus 运行时向 secrets provider 换取短期值。
- 注入方式以 **文件（tmpfs）/fd** 优先，其次环境变量；并支持 `expires_at`。
- **使用审计**：记录”某次 directive 是否请求/取用了哪些 secret_ref”，便于追责与回放解释。
- **防泄漏**：stdout/stderr redaction + 工件扫描/提示（至少在 UI 明示风险）。

MVP 取舍建议：

- Phase 0～4 不阻塞：允许用户在脚本里自行处理凭据（高风险），但必须在 UI 明示并建议使用 Trusted/Host + 审批；等 Nexus/Network/审计闭环稳定后再上 secrets provider。

### 10.8 “软限制”提示（Trusted 容器网络）

- 当处于 Trusted 且网络仅靠 proxy/env 控制时，UI 必须标识：
  - “该模式下网络限制可能被绕过（可信环境）”
  - 引导用户在 Untrusted 模式运行不可信代码。

### 10.9 供应链与可回放（新增，最低要求）

- 所有容器执行应记录 **镜像 digest**（避免 tag 漂移影响回放）。
- microVM 执行应记录 **kernel/rootfs 的版本或 digest**。
- Nexus 版本与 sandbox driver 版本必须写入 directive 元数据（`nexus_version/sandbox_version`）。

---
