## Reference Projects Analysis

> 2026-02-23: Comparative analysis of 10 open-source agent projects + Claude.app + Claude Code sandbox + DesktopCommanderMCP.
> Purpose: Inform architectural decisions for Cybros Nexus execution subsystem.
> Updated: 2026-02-23 with comprehensive per-project findings, Claude Code sandbox analysis, and post-MVP tracking.
> Updated: 2026-02-23 with Claude.app Desktop reverse-engineering — full VM isolation architecture via Virtualization.framework/HyperV.

### Scanned Projects

| Project | Language | Isolation Model | Key Strength |
|---------|----------|----------------|--------------|
| **Codex** (OpenAI) | Rust | Seatbelt (macOS) / Landlock (Linux) | Self-built network proxy, ghost commits, head/tail buffer |
| **Claude Code Sandbox** | TypeScript | Seatbelt (macOS) / bubblewrap (Linux) | OS-level FS+network isolation, proxy-based domain filtering, open-source runtime |
| **OpenClaw** | TypeScript | Docker containers | Lane-based command queue, fuzzy patch matching, container prune |
| **OpenCode** | TypeScript | Permission-based (no sandbox) | Git-based snapshots (tree objects), provider-neutral |
| **NanoClaw** | TypeScript | Linux containers | Per-group isolation, secrets via stdin, IPC filesystem |
| **Bub** | Python | Local bash | Append-only JSONL tape, deterministic routing |
| **Memoh** | Go | Containerd | Semantic memory, multi-bot coordination |
| **OpenManus** | Python | Subprocess | MCP ecosystem, ReAct loop |
| **Pi Mono** | TypeScript | Local (extensible) | Minimal core + extension ecosystem, session trees |
| **Claude Agent SDK** | Python | Claude Code CLI | In-process MCP, hook system |
| **OpenAI Agents SDK** | Python | Tool callables | Handoff abstraction, tracing |
| **Claude.app** | Electron + Rust/Swift | Virtualization.framework VM (macOS) / HyperV (Windows) | Full VM isolation, VirtioFS, seccomp+cgroup inside VM, domain allowlist, MITM proxy |
| **DesktopCommanderMCP** | TypeScript | Config-based (allowedDirectories) | Process lifecycle management, streaming search, line-based output pagination |

---

### Key Findings Adopted into Design

#### 1. Head/Tail Output Buffer (from Codex)

When output exceeds `MAX_OUTPUT_BYTES`, retain first 50% + last 50% with a `[... truncated ...]` marker. Avoids losing the end of output (where errors typically appear).

**Adopted in**: `04_protocol_reliability.md` &sect;10.3

#### 2. Standardized Execution Environment (from Codex)

Inject `NO_COLOR=1`, `TERM=dumb`, `LANG=C.UTF-8`, `PAGER=cat`, `GIT_PAGER=cat` into all sandbox executions. Prevents terminal escape codes, interactive pagers, and locale-dependent behavior from corrupting output.

**Adopted in**: `04_protocol_reliability.md` &sect;10.5.2

#### 3. Exit Code Conventions (from Codex)

Timeout &rarr; 124, Signal kill &rarr; 128+N. Standard Unix conventions.

**Adopted in**: `04_protocol_reliability.md` &sect;10.5.3

#### 4. Secret Passing via stdin (from NanoClaw)

Never mount secrets as files on the filesystem. Pass through stdin pipe or tmpfs (cleared after directive completes). Never use environment variables for secrets.

**Adopted in**: `02_security_profiles.md` &sect;5.7

#### 5. Self-built CONNECT Proxy (from Codex)

Codex built `codex-network-proxy` (Rust): HTTP + SOCKS5 proxy with allowlist/denylist enforcement, "limited" mode for read-only network. Returns `403` with `x-proxy-error` header. Admin API for debugging.

**Influences**: Egress proxy implementation (Phase 1 for UDS CONNECT+SOCKS5 allowlist; Phase 4+ for DNS audit/firewall hardening). Recommend Go implementation referencing Codex's test cases.

#### 6. Kill-on-Drop / prctl (from Codex)

`kill_on_drop(true)` for all child processes + Linux `prctl(PR_SET_DEATHSIG, SIGTERM)`. Orphan cleanup on crash.

**Adopted in**: `04_protocol_reliability.md` &sect;10.2.1

#### 7. Container Prune with Dual Criteria (from OpenClaw)

Prune containers after idle timeout (24h) OR max age (7 days). Check interval &ge; 5 minutes.

**Influences**: Facility cleanup strategy (Phase 3+).

#### 8. Incremental Cleanup (from OpenClaw)

Never do bulk cleanup. Batch-limited prune jobs with minimum interval between runs.

**Adopted in**: `06_operations.md` &sect;15.7

#### 9. Execve-level Command Interception (from Codex shell-tool MCP)

Codex 的 `codex-shell-tool-mcp` 通过 **拦截 `execve(2)`** 来获得“真实将要执行的二进制路径与参数”，并把每次 spawn 请求回传给 MCP server 决策（Run / Escalate / Deny）。这能有效避免：

- `$PATH` 前置同名可执行文件（`ls` 不是 `/bin/ls`）造成的规则绕过；
- shell alias / function / wrapper 藏匿真实执行目标；
- “看起来安全的命令字符串”在运行时劫持为不安全二进制。

**Influences**: Phase 2+ 的 Trusted/Host 命令审批与“可解释的命令执行”链路（可选增强：在不改变 OS-level sandbox 的前提下增加一层命令级强约束）。

#### 10. Sandbox Policy Hot Reload (from Codex harness)

Codex harness 会向声明了 `codex/sandbox-state` capability 的 MCP server 发送 `codex/sandbox-state/update` 请求，以**动态更新 sandboxPolicy**（例如 `writable_roots`、`network_access`）。

**Influences**: 说明为什么 FS/NET 默认策略必须“显式配置文件化 + 可版本化”，并且为什么 policy 的变更需要作为一等契约（与我们 Phase 0.5 引入的 `mothership/config/conduits_defaults.yml` 方向一致）。

---

### Per-Project Detailed Findings

#### Claude Code Sandbox Runtime — Deep Dive

Claude Code 的沙箱系统（`@anthropic-ai/sandbox-runtime`，已开源）是与 Cybros 最直接相关的参考，因为它解决了完全相同的问题：在用户机器上隔离执行 AI 生成的命令。

**双层隔离架构**：
- **文件系统隔离**（deny-only read + allow-only write）：
  - Read：默认允许读取整台机器，仅选择性阻断敏感路径（`~/.ssh`、credentials 等）。
  - Write：默认阻断所有写入，仅显式允许指定目录（CWD 及子目录）。
  - 这种「read=open-by-default, write=closed-by-default」思路比全 deny 更实用——AI 需要读取上下文来工作。
- **网络隔离**（proxy-based domain filtering）：
  - 在沙箱**外部**运行 HTTP + SOCKS5 代理服务器。
  - 沙箱内所有出站流量被强制通过代理（Linux 通过 network namespace 完全切断直连；macOS 通过 Seatbelt 限制只能连到 localhost proxy 端口）。
  - 代理维护 `allowedDomains` / `deniedDomains` 列表，deny 优先。
  - 新域名请求触发用户确认弹窗（allow once / always / deny）。

**平台实现差异**：
- **macOS**：使用 `sandbox-exec` + 动态生成的 Seatbelt profile。FS 限制通过 glob pattern，网络限制通过只允许连接本地代理端口。
- **Linux/WSL2**：使用 **bubblewrap (bwrap)** 创建隔离环境：
  - 全新 mount namespace（tmpfs root），显式 bind-mount 需要的路径。
  - Network namespace 完全隔离（仅 loopback），通过 Unix socket bind-mount 连接到宿主代理。
  - `PR_SET_NO_NEW_PRIVS` 阻止 setuid 提权。
  - 可选 seccomp-BPF 过滤。
  - 需要 `bubblewrap` + `socat` 两个系统包。

**权限系统与沙箱的关系**：
- 权限系统（Permissions）在**工具层**控制：哪些工具可用、哪些文件/域名可访问。应用于所有工具（Bash/Read/Edit/WebFetch/MCP）。
- 沙箱在**OS 层**强制执行：仅应用于 Bash 命令及其子进程。即使提示词注入绕过了 Claude 的决策，OS 层仍然阻断越界访问。
- 两者互补：权限系统阻止 Claude「尝试」越界；沙箱阻止实际进程「执行」越界。

**权限规则语法**（值得参考的设计）：
- `Bash(npm run *)` — glob 匹配命令前缀。
- `Read(~/.ssh/**)` — gitignore 风格路径模式，区分 `*`（单层）和 `**`（递归）。
- `WebFetch(domain:example.com)` — 域名级控制。
- 规则评估顺序：deny → ask → allow（deny 优先）。
- 支持多层设置覆盖：managed > project > user。

**两种沙箱模式**：
- **Auto-allow**：沙箱内命令自动执行无需审批；无法沙箱化的命令回退到常规审批流。
- **Regular permissions**：即使沙箱化也需要审批。

**逃逸机制（设计选择）**：
- `dangerouslyDisableSandbox` 参数允许命令绕过沙箱（例如 Docker 命令），但走常规权限审批。
- 可通过 `allowUnsandboxedCommands: false` 完全禁用此逃逸。

**安全局限性（官方承认）**：
- 网络过滤只做域名级控制，不检查流量内容。
- 允许宽泛域名（如 `github.com`）可能导致数据外泄。
- Domain fronting 可能绕过过滤。
- `allowUnixSockets` 可能意外授予强大的系统访问（如 Docker socket）。
- Linux 的 `enableWeakerNestedSandbox` 在 Docker 内显著削弱隔离。

**Relevance to Cybros（极高）**：
- bubblewrap 是 Cybros **Untrusted profile** 在 Linux 上的理想基础（Phase 1），比 Firecracker microVM 更轻量，适合 MVP。
- proxy-based 网络隔离架构直接验证了我们的 egress proxy 设计方向。
- 「read=open, write=closed」更易用但边界更弱：可作为 Trusted/Host 的可选开关；Untrusted 默认建议 workspace-only。
- 权限层 + OS 层的双层防御模型应纳入 Cybros 的安全架构。
- Seatbelt 方案验证了 macOS darwin-automation 隔离的可行性。

#### DesktopCommanderMCP — Deep Dive

DesktopCommanderMCP 是一个 MCP 服务器，为 Claude Desktop 提供系统自动化能力。虽然不涉及沙箱隔离，但其**进程生命周期管理**和**输出流式传输**模式对 Nexus daemon 有直接参考价值。

**进程生命周期管理（TerminalManager）**：
- Session 模型：`{ pid, process, outputLines[], lastReadIndex, isBlocked, startTime }`。
- **Smart State Detection**：通过正则匹配 REPL 提示符（`>>>`、`>`、`$`、`#`）检测进程是否「等待输入」vs「仍在运行」vs「已完成」。支持 Python/Node/R/Julia/bash/MySQL/PostgreSQL。
- **Line-based output buffering**：按行分割 stdout/stderr（非字符流），通过 `lastReadIndex` 追踪分页位置。三种读取模式：offset=0 读新输出、offset>0 绝对定位、offset<0 尾部读取。
- **Timing telemetry**：记录 exitReason、totalDurationMs、timeToFirstOutputMs、每个 output event 的时间戳。
- 活跃 session 缓存 + 已完成 session 保留最近 100 条（支持回溯查看）。

**Shell 配置适配**：
- 自动检测 shell 类型（bash/zsh/fish/PowerShell）并使用对应参数（`-l -c`、`-Login -Command` 等）。
- 设置 `TERM=xterm-256color`。
- 与我们设计的 `shell` 字段 + `TERM=dumb` 环境标准化有映射关系。

**Streaming Search（SearchManager）**：
- 非阻塞搜索启动 → 立即返回 sessionId。
- 通过 `get_more_search_results(sessionId, offset, length)` 分页获取结果。
- 支持 graceful 取消 (`stop_search`)。
- 旧 session 自动清理。
- 模式与我们的 poll → log_chunks 流式上报类似。

**运维/连接能力（对“远程控制本机”很有启发）**：
- **Remote MCP**：支持从 ChatGPT/Claude Web 等远程客户端连接到本机 MCP（通过其云端中继/服务），解决 NAT/无入站端口的接入问题。
- **动态配置管理**：支持 get/set 配置并热更新（无需重启 server）。
- **审计日志**：所有工具调用自动记录，并带轮转（例如 10MB 上限），便于本机侧排障与追责。

**Access Control（有限但有参考）**：
- `allowedDirectories` 配置限制文件操作范围。
- 路径规范化（大小写、尾部分隔符）+ symlink 解析。
- 递归检查父目录。
- **局限**：仅约束文件操作 API，不约束终端命令（可被 shell 绕过）。项目自己的 SECURITY.md 明确指出这是 guardrails 而非 hardened boundaries。

**Blocked Commands 模式**：
- 默认阻止 34 个高危命令（sudo、mkfs、shutdown 等）。
- 支持管道 / && / || / 子 shell 中的命令提取与逐一检查。
- 与 Cybros 的 `sandbox_profile` 能力约束有概念映射，但粒度更粗。

**Relevance to Cybros（中等）**：
- **进程生命周期管理模式** → Nexus daemon 可参考 session + smart state detection 模式管理 sandbox 进程。
- **Line-based 输出分页** → 与我们的 log_chunk(seq) 上报模型互补：Nexus 内部可用类似的 line buffer 管理输出，再通过 seq 分片上传到 Mothership。
- **Timing telemetry** → 为 directive 执行添加 `time_to_first_output`、`exit_reason` 等结构化遥测字段（Phase 2 structured events）。
- **Blocked commands 的命令解析** → Cybros Trusted/Host profile 可参考其管道/子 shell 命令提取逻辑来验证命令安全性。

#### Codex (OpenAI) — Deep Dive

Codex is the most architecturally relevant reference for Cybros's execution subsystem.

**Sandbox isolation model**:
- macOS: Uses App Sandbox (Seatbelt) profiles for process-level restriction. Each command execution gets a sandboxed shell with explicit path grants.
- Linux: Uses Landlock LSM for filesystem access control without root, supplemented by seccomp-bpf for syscall filtering.
- Both platforms: Process-group based lifecycle — kill entire group on timeout/cancel.

**Network proxy (`codex-network-proxy`)**:
- Self-built in Rust with HTTP CONNECT + SOCKS5 support.
- Allowlist/denylist enforcement at the proxy level.
- "Limited" mode: read-only network (allows GET but blocks POST/PUT). Interesting concept but not adopted — too complex to enforce reliably at proxy level for arbitrary TCP.
- Returns `403 Forbidden` with `x-proxy-error` header describing why the request was blocked.
- Admin API endpoint for debugging proxy state and connections.
- Test suite is comprehensive — covers allowlist matching, wildcard domains, concurrent connections, timeout behavior. **Valuable reference for our Go proxy implementation.**

**Command wrapping**:
- Uses the `script` command to wrap execution in a pseudo-terminal, capturing TTY-like output. We opted for simpler `shell -c` approach since we inject `TERM=dumb` to suppress TTY behavior.

**Git integration**:
- Ghost commits: Creates unreferenced git commits to snapshot workspace state. More complex than our `snapshot_before/after` HEAD-based approach, but enables richer rollback.
- Auto-commit after execution if changes detected.

**Relevance to Cybros**:
- Seatbelt profiles → Study for darwin-automation isolation (Phase 5).
- Landlock → Potential supplement for Trusted profile filesystem restriction (Phase 2+).
- Proxy test cases → Direct reference for Phase 1+ egress proxy.

#### OpenClaw — Deep Dive

**Container lifecycle management**:
- Warm pool: Pre-creates containers for instant startup. Container creation is the most expensive operation (~2-5s). Warm pool reduces effective latency to <500ms.
- Container health check: Runs `docker exec` health probe before assigning work. Unhealthy containers are recycled.
- Dual-criteria prune: idle timeout (24h) OR max age (7 days), with check interval &ge; 5 minutes.

**Command execution model**:
- Lane-based command queue: Serializes commands per logical lane (e.g., per conversation). Multiple lanes can execute in parallel across different containers.
- Not adopted: Cybros uses facility-level mutex (one running directive per facility). Lane system is for intra-process parallelism.

**Fuzzy patch matching**:
- When an exact patch application fails (context mismatch due to concurrent edits), attempts fuzzy matching with adjustable context lines.
- Not adopted: Unified diff is the standard. Fuzzy matching adds unpredictability. Agent can retry with updated context.

**Relevance to Cybros**:
- Warm pool concept → Consider for container driver (Phase 1) to reduce Trusted profile startup latency.
- Prune strategy → Adopted for facility cleanup.
- Health check pattern → Apply to sandbox readiness verification.

#### OpenCode — Deep Dive

**Git snapshot approach**:
- Uses `git write-tree` to create tree objects without full commits — lighter weight than Codex's ghost commits.
- Trees are referenced in session metadata for undo/restore.
- Not adopted: Our `snapshot_before/after` with HEAD hashes is simpler and sufficient for Phase 1.

**Permission model**:
- No sandbox isolation. Uses a permission system where users approve tool usage categories (file read, file write, command execution, network).
- Category-level approval with "always allow" option.
- Relevant insight: Even without sandbox, explicit approval UX reduces risk. Aligns with our approval workflow design (Phase 2).

**Provider-neutral architecture**:
- Abstract AI provider interface supporting multiple backends. Clean separation.
- Not adopted: Cybros controls the control plane; no provider abstraction needed.

#### NanoClaw — Deep Dive

**Per-group isolation**:
- Creates isolated container groups (pod-like) for related tasks. Containers within a group share a network namespace but have separate filesystem namespaces.
- Interesting for multi-step directives that need to share state but maintain isolation between steps.
 - **队列与并发控制**：每个 group 有自己的任务队列，同时有全局并发上限（避免资源被单个 group 占满）。与我们“facility 互斥锁 + territory capacity”方向一致。

**Secrets via stdin**:
- Secrets are never written to disk or passed as environment variables.
- Injected via stdin pipe to container processes. Cleaned up when process exits.
- **Adopted**: Direct influence on our secret passing design (&sect;5.7).

**IPC filesystem**:
- Uses a tmpfs-backed IPC directory for structured communication between host and sandbox.
- Commands and responses flow through files in this shared mount.
- Relevant insight: Consider IPC filesystem for future sandbox CLI (&sect;12.3) communication pattern.

#### Bub — Deep Dive

**Append-only JSONL tape**:
- Every agent action and observation is appended to a `.jsonl` file. Complete replay possible.
- Simple, debuggable, no external dependencies.
- Not adopted for production audit (Cybros has server-side Mothership audit), but consider for Nexus-local debugging logs.

**Deterministic routing**:
- Routes tasks to specific handlers based on task characteristics (type, requirements, etc.).
- Simple hash-based routing — no load balancing complexity.
- Relevant insight: Simple routing suffices for early phases. Complex scheduling (capacity-aware, affinity) can be added incrementally.

#### Memoh — Deep Dive

**Multi-bot coordination**:
- Multiple agent instances coordinate through a shared containerd runtime.
- Agents claim tasks from a shared queue with lock-based exclusion.
- Relevant insight: Pattern aligns with our facility-level mutex. Consider for multi-territory coordination in future.

**Semantic memory**:
- Uses embeddings to store and retrieve contextual information across sessions.
- Not adopted: Out of scope for execution subsystem. Relevant for AgentCore integration.

#### OpenManus — Deep Dive

**MCP ecosystem integration**:
- Deep integration with Model Context Protocol for tool discovery and invocation.
- MCP servers provide tools; agent orchestrator selects and sequences tool calls.
- Relevant insight: When Cybros integrates with AgentCore, MCP-style tool abstraction may simplify the mapping from tool calls to DirectiveSpec (&sect;12.2).

**ReAct loop pattern**:
- Reason-Act-Observe loop for iterative task execution.
- Agent reasons about what to do, executes an action, observes the result, then reasons again.
- Relevant insight: This is the expected usage pattern for Cybros directives — Agent creates directive, observes result, creates next directive. Our design supports this naturally through the Mothership API.

#### Pi Mono — Deep Dive

**Extension ecosystem**:
- Minimal core with plugin-based extensions for different capabilities.
- Extensions register tools, prompts, and resources dynamically.
- Relevant insight: Consider extension-point architecture for sandbox drivers (&sect;12.3 future CLI).

**Session trees**:
- Conversations branch into tree structures, allowing parallel exploration.
- Session state preserved at branch points for rollback.
- Relevant insight: Facility snapshots serve a similar purpose — enabling exploration with rollback capability.

#### Claude Agent SDK — Deep Dive

**In-process MCP**:
- MCP servers run in-process, sharing memory with the agent.
- Faster than subprocess-based MCP but less isolation.

**Hook system**:
- Pre-execution and post-execution hooks for tool calls.
- Hooks can validate, transform, or block tool invocations.
- Relevant insight: Hook pattern is valuable for policy enforcement. Nexus's directive preprocessing (env injection, capabilities check) is conceptually similar. Consider formalizing as a hook chain in Phase 2 policy enforcement.

#### OpenAI Agents SDK — Deep Dive

**Handoff abstraction**:
- Agents can "hand off" conversation control to other specialized agents.
- Clean interface for agent-to-agent delegation.
- Relevant insight: When Cybros integrates multi-agent workflows, directive delegation across territories/facilities could use a similar pattern.

**Structured tracing**:
- Built-in tracing for debugging agent behavior — captures tool calls, model responses, timing.
- Traces are structured (not just log lines) and can be visualized.
- Relevant insight: Directive execution should emit structured trace events. Our current `log_chunks` covers stdout/stderr, but structured execution events (command start, env injection, network decisions, signal sent) would aid debugging. **Track as Phase 2+ enhancement.**

**Experimental Codex tool wrapper**:
- The SDK includes an experimental `codex_tool` wrapper that exposes sandbox knobs like `sandbox_mode`/`working_directory` and emits rich streaming events (`command_execution`, `file_change`, `mcp_tool_call`, etc.).
- Relevant insight: When Cybros is exposed as an Agent tool (AgentCore/MCP), we should provide similar ergonomics: per-call capability knobs + structured streaming events, not just raw stdout/stderr.

#### Claude.app (Desktop) — Deep Dive (Reverse-Engineered)

> 2026-02-23: 通过解包 Claude Desktop v1.1.4010 的 app.asar、分析 bundled JS（`.vite/build/index.js`）、
> 检查 native modules（`swift_addon.node`、`claude-native-binding.node`）以及挂载 `smol-bin` 镜像，
> 逆向出完整的 VM 隔离架构。**关键发现：Claude Desktop 不使用 sandbox-exec/Seatbelt 进程级隔离，
> 而是使用完整的虚拟机级别隔离。**

**整体架构（三层）**：

```
┌─────────────────────────────────────────────────────────┐
│ Host (macOS / Windows)                                  │
│ ┌─────────────────┐  ┌────────────────────────────────┐ │
│ │ Electron Main   │  │ swift_addon.node (macOS)       │ │
│ │ Process         │──│   → Virtualization.framework   │ │
│ │ (index.js)      │  │ cowork-vm-service (Windows)    │ │
│ │                 │  │   → HyperV via Named Pipes     │ │
│ └─────────────────┘  └────────────┬───────────────────┘ │
│                                   │ VirtioFS / vsock    │
│ ┌─────────────────────────────────┴───────────────────┐ │
│ │ Linux VM (rootfs.img / rootfs.vhdx)                 │ │
│ │  ┌──────────────┐  ┌────────────────────────────┐   │ │
│ │  │ sdk-daemon   │  │ sandbox-helper             │   │ │
│ │  │ (Go, HTTP    │  │ (Go, seccomp + cgroup      │   │ │
│ │  │  proxy,      │  │  + chroot, per-process     │   │ │
│ │  │  VirtioFS    │  │  isolation within VM)      │   │ │
│ │  │  mounts)     │  │                            │   │ │
│ │  └──────────────┘  └────────────────────────────┘   │ │
│ └─────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

**第一层：Host → VM 隔离（hypervisor 级别）**：
- **macOS**：使用 Apple **Virtualization.framework**，通过 Swift native module（`swift_addon.node`，36MB）访问。
  - 主二进制文件持有 `com.apple.security.virtualization` entitlement。
  - 不使用 App Sandbox（无 `com.apple.security.app-sandbox` entitlement）。
  - 实际隔离完全依赖 VM 边界，而非进程沙箱。
- **Windows**：使用 **HyperV**，通过 Named Pipe（`\\.\pipe\cowork-vm-service`）+ JSON 协议通信。
  - 消息格式：4 字节大端 uint32 长度前缀 + JSON 负载。
- **Guest OS**：Linux rootfs（macOS 用 `.img`，Windows 用 `.vhdx` + `vmlinuz` + `initrd`）。
  - Bundle 通过 SHA 校验，从 `https://downloads.claude.ai/vms/linux/{arch}/{sha}` 下载。
  - 使用 Zstandard 压缩。
  - 本地缓存在 `{userData}/vm_bundles/claudevm.bundle`。

**第二层：VM 内部进程隔离（sandbox-helper）**：

`sandbox-helper`（Go，静态链接，aarch64/x64）在 VM 内部提供进程级隔离：
- **seccomp-BPF**：系统调用过滤（`applySeccompFilter` → `seccomp_filter.go`）。
- **cgroup v2**：内存控制器，支持 OOM 检测（通过 `CgroupFD`/`UseCgroupFD`）。
- **chroot**：文件系统根目录隔离。
- **VirtioFS mounts**：宿主目录通过 VirtioFS 挂载到 `/mnt/.virtiofs-root`。
- **Settings 文件**：`/etc/srt-settings.base.json` 定义 FS 和网络策略。

**第三层：sdk-daemon（VM 内部服务）**：

`sdk-daemon`（Go，静态链接）运行在 VM 内部，提供：
- HTTP/HTTPS 代理服务（处理出站请求）。
- VirtioFS mount/unmount 操作。
- cgroup 内存监控（OOM kill 计数）。
- Socket-based 通信（与宿主 Electron 进程交互）。
- MITM 代理支持（`/var/run/mitm-proxy.sock`）。

**完整 VM API（逆向自 index.js）**：

```javascript
// VM 生命周期
configure(memoryMB, cpuCount)
createVM(bundlePath, diskSizeGB = 10)
startVM(bundlePath, memoryGB?)
stopVM()
isRunning() → boolean
isGuestConnected() → boolean

// 进程管理
spawn(id, name, command, args[], cwd, env, additionalMounts, isResume, allowedDomains, sharedCwdPath, oneShot)
kill(id, signal = "SIGTERM")
writeStdin(id, data)
isProcessRunning(id) → {running, exitCode}

// 事件回调
setEventCallbacks(onStdout, onStderr, onExit, onError, onNetworkStatus, onApiReachability)

// 文件系统
mountPath(processId, subpath, mountName, mode)  // mode: "rw" | "rwd"
readFile(processName, filePath)

// SDK 管理
installSdk(sdkSubpath, version)
addApprovedOauthToken(token)
```

**spawn 参数详解**：
- `additionalMounts`：`{subpath: {path, mode}}` 形式，mode 为 `rw`（读写）或 `rwd`（读写+删除）。
- `allowedDomains`：域名白名单数组，控制出站网络访问。
- `sharedCwdPath`：宿主与 VM 共享的工作目录。
- `oneShot`：布尔值，用于一次性 CLI 命令执行。
- `isResume`：布尔值，支持进程恢复。

**网络隔离模型**：

```json
{
  "network": {
    "allowedDomains": [
      "registry.npmjs.org", "npmjs.com", "yarnpkg.com",
      "pypi.org", "files.pythonhosted.org",
      "github.com", "archive.ubuntu.com",
      "api.anthropic.com", "*.anthropic.com",
      "crates.io", "index.crates.io",
      "sentry.io", "*.sentry.io"
    ],
    "deniedDomains": [],
    "allowLocalBinding": true,
    "mitmProxy": {
      "socketPath": "/var/run/mitm-proxy.sock",
      "domains": ["*.anthropic.com", "anthropic.com"]
    }
  }
}
```
- **Domain allowlist** 在 spawn 时传入，限制 VM 内进程可访问的域名。
- **MITM proxy** 通过 Unix socket 拦截特定域名流量（`*.anthropic.com`），用于注入 OAuth token。
- **OAuth token 传递**：通过 `addApprovedOauthToken(token)` API 将 token 传入 VM。

**文件系统策略（smol-bin srt-settings.json）**：

```json
{
  "filesystem": {
    "denyRead": [],
    "allowWrite": ["/"],
    "denyWrite": []
  }
}
```
- VM 内部默认策略：读取无限制，写入允许所有路径（VM 边界本身已提供隔离）。
- 实际的 FS 限制通过 VirtioFS mount 控制——只有 `additionalMounts` 和 `sharedCwdPath` 指定的路径才对宿主可见。

**VM 启动流程（逆向自 `J2t` 函数）**：

```
1. 检查 bundle 是否存在（SHA 校验）
2. 下载 rootfs.img（如需要，Zstandard 解压）
3. 加载 Swift native API（macOS）/ 启动 vm-service（Windows）
4. 设置事件回调（stdout/stderr/exit/error/networkStatus/apiReachability）
5. startVM(bundlePath, memoryGB)
6. 轮询等待 guest 连接（60s 超时，500ms 间隔）
7. installSdk(sdkSubpath, version)
8. 启用 memory balloon 监控
9. 启动 heartbeat（30s 间隔）和 keep-alive（2s 间隔）
```

**健康监控与自恢复**：
- **Heartbeat**：30s 间隔，15s 超时，连续 5 次失败触发 VM 重启。
- **Keep-alive**：2s 间隔 ping，检测 guest 连通性。
- **Network recovery**：连接失败时自动切换到 gvisor 模式。
- **VM diagnostics**：通过 `vm_stat` 监控内存、检测 jetsam 压力、kernel bug（`undefined_instruction`、`NULL dereference`、`kernel Oops`）。
- **Auto-reinstall**：启动失败时自动重新安装 bundle。

**Memory Balloon（动态内存管理）**：
- 三级内存模型：max / baseline / min。
- 宿主内存压力监控（macOS `vm_stat`、jetsam pressure level）。
- 根据压力动态调整 VM 内存分配。
- VZ footprint 追踪。

**CoworkVMProcess（进程封装）**：
- 每个 VM 内进程对应一个 `CoworkVMProcess` 实例。
- stdin 通过 PassThrough stream 转发。
- stdout/stderr 通过事件回调接收。
- OOM kill 检测（`oomKillCount` 计数器）。
- 支持 signal 发送（SIGTERM/SIGKILL）。

**smol-bin 镜像内容（已挂载验证）**：

| 文件 | 格式 | 描述 |
|------|------|------|
| `sdk-daemon` | ELF 64-bit ARM aarch64, static Go | VM 内部服务，HTTP proxy + VirtioFS + cgroup |
| `sandbox-helper` | ELF 64-bit ARM aarch64, static Go | 进程级隔离：seccomp + cgroup + chroot |
| `srt-settings.json` | JSON (~1KB) | 网络 + 文件系统策略配置 |

均为静态链接 Go 二进制，无外部依赖。

**与 Claude Code CLI 沙箱的对比**：

| 维度 | Claude Code CLI | Claude Desktop |
|------|----------------|----------------|
| 隔离级别 | 进程级（bwrap/Seatbelt） | VM 级（Virtualization.framework/HyperV） |
| 网络隔离 | 代理环境变量注入 | VM 网络命名空间 + domain allowlist |
| FS 隔离 | bind-mount / Seatbelt profile | VirtioFS 选择性挂载 |
| Guest OS | 无（直接在宿主运行） | Linux rootfs（独立内核） |
| 资源控制 | 有限（cgroup 可选） | 完整（VM 内存/CPU + cgroup + seccomp） |
| 启动成本 | 低（~100ms） | 高（VM boot ~5-10s） |
| 安全强度 | 中（命名空间 + LSM） | 高（hypervisor 边界 + 内部 seccomp） |

**Relevance to Cybros（极高）**：

1. **VM 隔离是最高安全等级的选择** → 验证了 Cybros Phase 3 Firecracker microVM 方向。Claude 选择 VM 而非进程级隔离说明对于桌面端场景，hypervisor 级隔离是工程首选。
2. **VirtioFS + mount API** → 直接参考 Cybros 的 facility 文件系统共享设计。`additionalMounts` 的 `rw`/`rwd` 模式映射到我们的 Facility read/write 策略。
3. **Domain allowlist at spawn time** → 验证了我们的 `DirectiveSpec.capabilities.net` per-directive 网络策略设计。
4. **MITM proxy for API tokens** → 安全的 token 注入模式，通过代理在传输层注入 credentials 而非暴露给 sandbox 进程。参考我们的 secret passing 设计。
5. **sandbox-helper (seccomp + cgroup + chroot)** → 即使在 VM 内部仍需进程级隔离——**defense in depth** 的极致体现。Cybros 的 bubblewrap sandbox 也应在 Firecracker VM 内部保留。
6. **sdk-daemon as in-VM agent** → 对应 Cybros 的 Nexus daemon 在 sandbox 内运行的概念。可参考其 HTTP proxy + VirtioFS mount 管理模式。
7. **Memory balloon / heartbeat / auto-recovery** → VM 级别的运维模式，为 Phase 3+ microVM 管理提供参考。
8. **smol-bin 静态链接 Go 二进制** → 验证了 Go 作为 sandbox 内部工具链的可行性（Nexus daemon 同为 Go）。
9. **SSH gateway**（`claude-ssh`）→ 如果 Cybros 需要提供 facility 交互式访问（Phase 6+），SSH gateway 模式是合适的选择。

---

### Patterns Evaluated but NOT Adopted (with reasons)

| Pattern | Source | Why Not | Revisit When |
|---------|--------|---------|--------------|
| Ghost commits (unreferenced git commits for snapshots) | Codex | Our `snapshot_before/after` mechanism is simpler and sufficient for Phase 1. | Rollback features (Phase 6). |
| Custom patch format ("Begin/End Patch") | OpenClaw | Unified diff is the industry standard. Custom format adds parsing complexity. | Never (standard diff is sufficient). |
| Lane-based command serialization | OpenClaw | Cybros uses facility-level mutual exclusion (one running directive per facility). | Multi-step directive pipelines (future). |
| Semantic memory with embeddings | Memoh | Out of scope for execution subsystem. | AgentCore integration (post-Phase 6). |
| Provider-neutral AI SDK | OpenCode | Cybros controls the control plane; provider abstraction not needed. | Never (by design). |
| Append-only JSONL tape | Bub | Good for local debugging. Cybros has server-side audit via Mothership. | Nexus-local debug mode (nice-to-have). |
| Fuzzy patch matching | OpenClaw | Adds unpredictability. Agent can retry with updated context. | Never (prefer deterministic behavior). |
| Read-only network mode | Codex | Difficult to enforce reliably at proxy level for arbitrary TCP. Too complex for V1. | Phase 4+ if there's demand. |
| In-process MCP (shared memory) | Claude Agent SDK | Cybros sandboxes are process-isolated by design. | Never (isolation is a core principle). |
| dangerouslyDisableSandbox 逃逸 | Claude Code | Cybros 不允许运行时绕过沙箱。如果能力不足应升级 profile 而非绕过。 | Never (profile 升级替代逃逸). |
| Virtualization.framework / HyperV 桌面 VM | Claude.app | Cybros Phase 0-2 使用 bubblewrap，轻量且够用。VM 级隔离留给 Phase 3 Firecracker。 | Phase 3 (Firecracker microVM). |
| Memory balloon dynamic tier | Claude.app | Cybros 的 cgroup 资源限额已足够 Phase 0-2 场景。动态内存调整是 microVM 特有需求。 | Phase 3+ (microVM 资源管理). |
| allowedDirectories 文件 guardrails | DesktopCommanderMCP | 仅约束 API 层不约束子进程，非 hardened boundary。Cybros 需要 OS 级强制执行。 | Never (guardrails 不够). |
| Auto-allow 沙箱模式（自动审批） | Claude Code | Cybros 的审批由 Mothership Policy 控制，不能在 Nexus 侧自动绕过。 | Phase 2+ policy 系统可实现类似的「预批准」能力组合. |

---

### Cross-Project Patterns Summary (Influence Map)

| Pattern Category | Best Implementation | Cybros Adoption | Phase |
|-----------------|--------------------|--------------------|-------|
| Output truncation | Codex (head/tail buffer) | **Adopted** | Phase 0 |
| Env standardization | Codex (NO_COLOR, TERM=dumb) | **Adopted** | Phase 0 |
| Exit code conventions | Codex (124/128+N) | **Adopted** | Phase 0 |
| Process lifecycle (kill-on-drop) | Codex (prctl/DEATHSIG) | **Adopted** | Phase 0 |
| Secret injection | NanoClaw (stdin pipe) | **Adopted** | Phase 5 (implementation) |
| Egress proxy | Codex (CONNECT+SOCKS5) | **Adopted** (Go; Phase 1 CONNECT+SOCKS5+UDS MVP; Phase 4+ adds DNS audit/firewall) | Phase 1 |
| Container prune | OpenClaw (dual-criteria) | **Adopted** | Phase 3+ |
| Incremental cleanup | OpenClaw (batch-limited) | **Adopted** | Phase 0 (design) |
| Warm container pool | OpenClaw | **Track** for container driver | Phase 1 |
| Structured tracing | OpenAI Agents SDK | **Track** for directive events | Phase 2+ |
| Hook-based policy | Claude Agent SDK | **Track** for policy chain | Phase 2 |
| Seatbelt profiles (macOS) | Codex | **Track** for darwin-automation | Phase 5 |
| Landlock LSM (Linux) | Codex | **Track** for Trusted FS restriction | Phase 2+ |
| IPC filesystem | NanoClaw | **Track** for sandbox CLI | Future |
| SSH gateway | Claude.app | **Track** for interactive access | Phase 6+ |
| Git tree snapshots | OpenCode | **Evaluate** vs HEAD-based snapshots | Phase 6 (rollback) |
| VM-level isolation (Virtualization.framework/HyperV) | Claude.app | **Track** for Firecracker microVM direction | Phase 3 |
| VirtioFS selective mount (rw/rwd modes) | Claude.app | **Track** for facility FS sharing | Phase 3 |
| Domain allowlist at spawn time | Claude.app | **Adopted** validates per-directive net policy | Phase 0 |
| MITM proxy for API token injection | Claude.app | **Track** for secret passing via proxy | Phase 4+ |
| In-VM seccomp+cgroup+chroot (defense in depth) | Claude.app | **Track** for in-Firecracker isolation | Phase 3 |
| In-VM agent daemon (sdk-daemon pattern) | Claude.app | **Track** for Nexus inside sandbox | Phase 3 |
| Memory balloon dynamic adjustment | Claude.app | **Track** for microVM resource management | Phase 3 |
| VM heartbeat + auto-recovery | Claude.app | **Track** for microVM health monitoring | Phase 3 |
| Static-linked Go binary for sandbox tools | Claude.app | **Adopted** validates Go as sandbox toolchain | Phase 0 |
| bubblewrap (bwrap) namespace 隔离 | Claude Code Sandbox | **Adopted** for Untrusted Linux | Phase 0/1 |
| Proxy-based network isolation | Claude Code Sandbox | **Adopted** 验证了 egress proxy 方向 | Phase 1 |
| Read-open / Write-closed FS 策略 | Claude Code Sandbox | **Track** (optional in Trusted/Host; Untrusted defaults to workspace-only) | Phase 2+ |
| 权限层 + OS 层双层防御 | Claude Code Sandbox | **Adopted** (Policy + sandbox) | Phase 0 |
| Seatbelt sandbox-exec (macOS) | Claude Code Sandbox | **Track** for darwin-automation | Phase 5 |
| Line-based output pagination | DesktopCommanderMCP | **Track** for Nexus 内部输出管理 | Phase 1 |
| Smart process state detection | DesktopCommanderMCP | **Track** for sandbox 健康检测 | Phase 1 |
| Execution timing telemetry | DesktopCommanderMCP | **Track** for structured events | Phase 2 |
| Blocked commands 管道解析 | DesktopCommanderMCP | **Track** for Trusted/Host command validation | Phase 2 |

---

### Gaps Identified (Not Yet in Design)

| # | Gap | Priority | Suggested Phase | Notes |
|---|-----|----------|-----------------|-------|
| 1 | Shell command safety: validate argv, never use shell for untrusted args | High | Phase 0 | Nexus should sanitize command strings at boundary |
| 2 | Tool output disk degradation: save oversized output to file, return reference | Medium | Phase 1 | Avoid filling Nexus memory with huge outputs |
| 3 | DNS audit logging in egress proxy | Medium | Phase 4 | Record qname/answers/ttl for forensics |
| 4 | Nexus doctor command (self-check for TCC/KVM/dependencies) | Medium | Phase 1 | Auto-detect capability gaps at startup |
| 5 | Directive checkpoint/resume (persist state to disk for crash recovery) | Low | Phase 6 | Required for long-running directive resilience |
| 6 | Structured execution events (beyond stdout/stderr) | Medium | Phase 2 | Capture env injection, network decisions, signals |
| 7 | Container warm pool for Trusted profile | Low | Phase 1 | Reduce container startup latency |
| 8 | Sandbox health check before directive assignment | Medium | Phase 1 | Verify sandbox is operational before using |
| 9 | Nexus-local debug tape (JSONL for local troubleshooting) | Low | Phase 1 | Complement server-side Mothership audit |
| 10 | Seatbelt/sandbox-exec profiles for darwin-automation | Medium | Phase 5 | Process-level macOS isolation |
| 11 | Agent-to-agent handoff protocol for multi-territory workflows | Low | Future | Cross-territory directive delegation |
| 12 | bubblewrap 集成作为 Untrusted profile 的 Linux 沙箱基础 | High | Phase 0/1 | 替代 Firecracker 作为 MVP 隔离方案，更轻量 |
| 13 | 权限层 + OS 层双层防御模型 | High | Phase 0 | Policy（Mothership）+ sandbox（Nexus OS-level）互补 |
| 14 | FS 路径逃逸测试向量（symlink/hardlink/.. traversal） | High | Phase 1 | 验证 realpath 校验与挂载策略不会被绕过 |
| 15 | Seatbelt sandbox-exec 动态 profile 生成 | Medium | Phase 5 | macOS darwin-automation 的进程级隔离 |
| 16 | Execution timing telemetry（time_to_first_output 等） | Medium | Phase 2 | 参考 DesktopCommanderMCP 的 timing 模式 |
| 17 | Trusted/Host profile 命令验证（管道/子 shell 解析） | Medium | Phase 2 | 参考 DesktopCommanderMCP 的 blocked commands 解析 |
| 18 | VirtioFS / Plan9 文件共享（microVM facility mount） | Medium | Phase 3 | 参考 Claude.app 的 additionalMounts rw/rwd 模式 |
| 19 | MITM proxy for credential injection（sandbox-safe secret passing） | Medium | Phase 4+ | 参考 Claude.app 的 mitmProxy.socketPath 模式 |
| 20 | In-VM defense in depth（seccomp+cgroup inside Firecracker） | Medium | Phase 3 | Claude.app 在 VM 内部仍用 sandbox-helper 做进程隔离 |
| 21 | Dynamic memory management for VMs（memory balloon） | Low | Phase 3 | 参考 Claude.app 的 max/baseline/min tier 模型 |
| 22 | VM heartbeat + auto-recovery（guest health monitoring） | Medium | Phase 3 | 参考 Claude.app 的 30s heartbeat / 5-failure restart |
| 23 | Static-linked Go agent binary for sandbox interior | Medium | Phase 3 | 参考 Claude.app 的 sdk-daemon / sandbox-helper 静态编译 |

---

### Decision Log (Discussion Outcomes)

> Records key decisions made during design discussions with rationale.
> D1-D15 were established during the initial design sprint (2026-02-23).

| # | Decision | Rationale | Date |
|---|----------|-----------|------|
| D1 | **Command format: string, not JSON array** | LLM should not output JSON for commands. Mothership wraps at dispatch time. Shell handles parsing. Unified across all platforms. | 2026-02-23 |
| D2 | **Kill orphan processes on Nexus restart** (not resume) | Memory state lost after crash. Can't resume heartbeat or output capture. Lease timeout handles reassignment. Checkpoint/resume deferred to Phase 6. | 2026-02-23 |
| D3 | **mTLS MVP: self-signed CA only** | Phase 0 scope is validating mTLS feasibility. No rotation, no CRL. Full PKI in later phase. | 2026-02-23 |
| D4 | **Enrollment rate limiting in Phase 0** | Enrollment endpoint is public-facing. 10/IP/hour prevents DoS. Other endpoint rate limits post-MVP. | 2026-02-23 |
| D5 | **Policy merge: per-capability independent rules** | net/fs use restrictive ceiling (intersection); secrets/sandbox use priority replace; approval uses most-restrictive-wins. | 2026-02-23 |
| D6 | **Egress proxy: self-write in Go** | Reference Codex's test cases for coverage. Go matches Nexus language. CONNECT+SOCKS5 support. | 2026-02-23 |
| D7 | **repo_url is supplementary metadata** | Smart agents handle empty directories themselves. `repo_url` is a hint for acceleration, not a mandatory prerequisite. Agent/user can manually clone. | 2026-02-23 |
| D8 | **Facility prepare stage** | Nexus auto-clones on first use only if repo_url set AND directory empty. Otherwise no-op. Phase 0.5 当前实现：prepare 失败会写入 stderr 并 `finished(status: "failed")`（不执行命令）。 | 2026-02-23 |
| D9 | **Storage constants: 10GB facility, 2,000,000B output, 1MiB diff** | Conservative defaults. Can be tuned per-facility via policy. 30-day blob TTL with incremental cleanup. | 2026-02-23 |
| D10 | **Secret passing: stdin/tmpfs only, never env vars** | Env vars leak through child processes, logs, crash dumps. stdin pipe is the safest injection path. | 2026-02-23 |
| D11 | **Linux Untrusted 基础：bubblewrap > Firecracker（MVP）** | Claude Code 已验证 bwrap 在 Linux 上提供足够的 FS+network namespace 隔离。比 Firecracker 轻量得多，无需 KVM。Phase 0/1 用 bwrap，Phase 3+ 可选 Firecracker 加强。 | 2026-02-23 |
| D12 | **FS 默认策略：workspace-only + write allow-only（Untrusted）** | Read-open 更易用但边界更弱且维护 denylist 成本高；Untrusted 默认只挂载 workspace。Read-open/Write-closed 仅作为 Trusted/Host 可选开关（配合审批与审计）。 | 2026-02-23 |
| D13 | **双层防御：Policy 层 + OS 层互补** | Policy（Mothership）在逻辑层控制能力；sandbox（Nexus OS-level）在物理层强制执行。即使提示词注入绕过逻辑层，OS 层仍阻断越界。 | 2026-02-23 |
| D14 | **Phase 3 microVM 内部仍需进程隔离（defense in depth）** | Claude.app 逆向表明即使在 VM 内部仍用 sandbox-helper（seccomp+cgroup+chroot）做进程级隔离。Cybros 的 Firecracker VM 内部也应保留 bubblewrap 或类似隔离。 | 2026-02-23 |
| D15 | **VirtioFS rw/rwd mount 模式参考** | Claude.app 的 additionalMounts 支持 rw（读写）和 rwd（读写+删除）两种模式。Cybros facility mount 应参考此设计，区分写入和删除权限。 | 2026-02-23 |
| D16 | **Phase 0 mTLS：可独立开发，临时用 header auth** | mTLS CA 基础设施可交由 Cowork 独立开发。Phase 0 临时使用 `X-Nexus-Territory-Id` header 认证 + IP 限制，需记录安全降级风险。 | 2026-02-23 |
| D17 | **状态机：aasm gem，Territory 记录动态，Directive 不记录** | Territory 状态变更需要 audit trail（`aasm with_new_state` callback 或独立事件表）。Directive 状态变更频繁且有 log_chunks 审计，无需额外记录。 | 2026-02-23 |
| D18 | **Log chunk 存储：独立 log_chunks 表（Phase 0.5）** | stdout/stderr 以 `(directive_id, stream, seq)` 分片落库并去重；服务端强制 `max_output_bytes`。避免 ActiveStorage “追加”导致的下载+重传放大，并为未来“按 seq 流式拉取/finished 定稿合并 blob”保留空间。 | 2026-02-23 |
| D19 | **用户侧 API + Ruby 测试脚本** | 需要 `POST /mothership/api/v1/facilities/:id/directives` 端点创建 directive。配套 Ruby 脚本用于端到端测试集。 | 2026-02-23 |
