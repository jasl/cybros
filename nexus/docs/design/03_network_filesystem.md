## 7. 网络访问控制（Egress Policy）

> 目标：默认“最小出站”，并把网络访问能力做成 **可审计、可审批、可回放** 的一等能力。
> 约束：绝大多数访问是 **HTTPS**；少量场景是 **TCP**（GitHub SSH、SSH/Rsync/SCP 到其它服务器）。

### 7.1 网络能力模型（NET capability）

Nexus 对 DirectiveSpec 提供三种模式（由 Policy 计算出 effective 值）：

- `NET=NONE`：完全无网络（推荐作为 Untrusted microVM 的 Phase 3 默认）。
- `NET=ALLOWLIST`：只允许访问 allowlist 内的 `{目标, 端口, 协议}`。
- `NET=UNRESTRICTED`：完全放开（强制审批；建议默认带 TTL；审计更强）。

#### 7.1.1 默认安全策略四档（Policy preset）

> 说明：preset 是 **控制面（Mothership）侧的用户体验抽象**。最终下发给 Nexus 的仍是 `mode + allowlist` 这种“可执行且可回放”的 **effective capability**。

提供四档默认策略（默认：`loose`），并允许用户在 preset 基础上做自定义：

- `off`（无安全策略）：等价于 `mode=unrestricted`，且不做 egress 限制/审计降级。**仅允许 Trusted/Host/darwin-automation 使用**；Untrusted 禁止（避免“误把不可信代码当可信”）。
- `loose`（宽松，默认）：等价于 `mode=allowlist`，默认只放行 `443`（可选 `80`），并提供 GitHub/rubygems/npm 等模板一键勾选；非默认端口（例如 22/873）需要显式加入 allowlist，且在 Untrusted 下建议触发审批。
- `strict`（严格）：仍是 `mode=allowlist`，但默认只放行 `443`；`*.` 通配与非默认端口默认触发审批；UI 必须更强提示（“这会扩大可访问面”）。
- `no_external`（禁止外部资源访问）：MVP 定义为 `mode=none`（完全无网）。未来如需“仅允许内网/私网”，再在 allowlist V2 引入 CIDR/私网判断。

自定义策略：
- 用户可以在 preset 的基础上追加/删除 allowlist 项（形成 `preset=custom` 的 effective 值）。
- 控制面必须把最终 effective 的 allowlist 记录到 directive 的审计信息中（可回放/可解释）。

### 7.2 allowlist 的表达（V1：domain:port）

你已确认：**先从 domain:port 开始**，把 CIDR/expires_at/approval_required 作为 future plan。

V1 allowlist 条目是字符串（便于在 UI/审计/配置里直接展示与复制）：

- 形式：`<host>:<port>`（authority-form）
- `host`：DNS 域名（ASCII/punycode），可选一个前缀通配：`*.example.com`
  - 仅允许前缀通配（`*.`），不允许中间/后缀通配、不允许正则。
  - 不允许 IP 字面量（IPv4/IPv6），避免绕过域名级审计与策略。
- `port`：1–65535

示例：

- `github.com:443`
- `*.githubusercontent.com:443`
- `rubygems.org:443`
- `ssh.github.com:443`（用于 GitHub SSH over 443）

端口策略（默认安全基线）：

- 默认只允许 `443`（可选 `80`），其余端口（`22/873/自定义`）必须显式写入 allowlist，且建议触发审批（至少在 Untrusted 下）。
- `SSH/SCP/Rsync` 等典型数据外流通道：即使允许，也应强审计（记录目的地与连接次数）并建议 directive-level TTL（future plan）。

> Future plan（V2）：允许 CIDR/IP、条目级 `expires_at/approval_required`、以及“仅允许内网/私网”的表达与自动判定。


### 7.3 Linux Untrusted 的强制 egress：UDS proxy（Phase 1）+ host 防火墙（Phase 4+ microVM）

Untrusted 的网络边界必须是“强制的”：sandbox **不能直连外网**，只能通过 egress-proxy，proxy 再按 allowlist 放行并审计。

Phase 1（bubblewrap）：
1) **sandbox（netns）**：只保留 loopback；通过 bind-mount 的 **Unix Domain Socket（UDS）** 连接到宿主 proxy。
2) **socat bridge**：sandbox 内用 `socat` 把 UDS 映射成 `127.0.0.1:<port>`，从而让标准 `HTTP_PROXY/HTTPS_PROXY` 生效。

Phase 4+（microVM）：
1) **microVM → 宿主**：只允许访问 egress-proxy（以及必要的 DNS/时间服务），其它出站在 host 侧直接 `DROP/REJECT`。
2) **egress-proxy → 外部**：由 proxy 根据 allowlist 决定是否建立连接，并写入审计日志。

Nexus 为提升易用性，默认在 sandbox 内注入：

- `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`（指向 sandbox 内 `127.0.0.1:<port>`；该端口经 socat 转发到宿主 UDS proxy）
- （可选）对 git：下发 `GIT_CONFIG_PARAMETERS` 或临时 config，确保 git/https 能自动走代理

#### 7.3.0.1 Egress Proxy 实现决策（D6）

> 决策：自写 Go 实现，参考 Codex 的 `codex-network-proxy`（Rust）测试用例。

- **语言**：Go（与 Nexus 保持一致，便于集成与部署）。
- **协议**：HTTP CONNECT + SOCKS5（Phase 1 必做；覆盖更多非 HTTP 场景，如 SSH/rsync）。
- **参考**：Codex 的代理实现提供了全面的测试用例，覆盖 allowlist 匹配、wildcard 域名、并发连接、超时行为。建议在实现时直接移植这些测试场景。
- **特性**：
  - Allowlist/denylist 执行（per-directive 配置）。
  - `x-proxy-error` 响应 header（调试用，包含 deny 原因码）。
  - Admin API（可选，便于调试代理状态与当前连接）。
  - DNS 审计日志（记录 qname/answers/ttl，Phase 4）。
- **不做**：TLS MITM、read-only mode（GET-only 代理模式，参考 Codex 的 "limited" mode，但太复杂且不可靠）。
- **阶段**：
  - Phase 1：实现 CONNECT+SOCKS5 allowlist + UDS 接入（bubblewrap 使用）。
  - Phase 4+：补 DNS 审计日志、可选 SNI 一致性校验、以及 host 防火墙联动（microVM）。

#### 7.3.1 为什么选择 HTTP CONNECT（不做 TLS MITM）

- 对 HTTPS：使用 HTTP 代理的 CONNECT 隧道即可，不需要解密 TLS 内容；仍可在“域名 + 端口”维度做控制与审计。
- 对少量 TCP（SSH/rsync/scp）：也可以走 CONNECT（建立到 `host:port` 的 TCP tunnel）。
  - 代价：客户端需要 ProxyCommand / wrapper（可先由脚本显式配置；未来由 sandbox 内置 CLI 自动处理）。

#### 7.3.2 SNI/Host 一致性校验（可选增强）

当流量为 TLS 时，proxy 可读取 ClientHello 的 SNI（不解密应用层），并与 CONNECT 的目标主机名做一致性校验：

- 匹配：放行并记录。
- 不匹配：拒绝或降级为强告警（取决于 profile/审批策略）。

> 备注：若未来 ECH 普及导致 SNI 不可见，则退化为仅基于 CONNECT host 的策略，并通过更强审计与最小 allowlist 降低风险。

### 7.4 典型用例模板（降低用户“关闭安全限制”的概率）

建议在 UI/配置里提供“模板”，让用户一键选择常见组合：

- **GitHub（HTTPS）**：`github.com:443`、`api.github.com:443`、`objects.githubusercontent.com:443`、`codeload.github.com:443`
- **GitHub（SSH over 443）**：`ssh.github.com:443`（GitHub 官方支持；代理/防火墙环境更容易放行）
- **部署（SSH）**：`<your-host>:22`（建议仅 Trusted/Host 或显式审批）
- **rsync**：
  - over SSH：同 SSH `22`
  - daemon mode：`<your-host>:873`（强审批）

### 7.5 审计要求（最小集）

至少记录：

- 每次 egress 连接尝试：`{directive_id, sandbox_id, dest_host, dest_port, proto, decision(allow/deny), policy_source, timestamp}`
- 对 deny：记录 `reason_code`（例如 `NET_MODE_NONE` / `NOT_IN_ALLOWLIST` / `PORT_NOT_ALLOWED` / `PROXY_REQUIRED` / `SNI_MISMATCH` 等；其中 `POLICY_EXPIRED`/`APPROVAL_REQUIRED` 预留给 future plan）
- （可选）对 DNS：记录 `{qname, answers, ttl}`（便于溯源与回放解释）

### 7.6 `DirectiveSpec.capabilities.net` JSON Schema（V1，冻结）

> 目的：让 Mothership/Nexus/proxy 三方对字段与语义达成一致，避免“看起来一样、实现不一致”。

**注意：**本 schema 只覆盖 `DirectiveSpec.capabilities.net` 这一段，不是完整 DirectiveSpec。

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://cybros.dev/schemas/directivespec/net-capability/v1.json",
  "title": "DirectiveSpec.capabilities.net (NetCapabilityV1)",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "mode"
  ],
  "properties": {
    "mode": {
      "type": "string",
      "enum": [
        "none",
        "allowlist",
        "unrestricted"
      ],
      "description": "Outbound network policy mode for this directive."
    },
    "preset": {
      "type": "string",
      "enum": [
        "off",
        "loose",
        "strict",
        "no_external",
        "custom"
      ],
      "description": "Optional policy preset label for audit/debug. Does not change enforcement semantics."
    },
    "allow": {
      "type": "array",
      "description": "Allowlist entries. Required when mode=allowlist. Each entry is 'host:port'. Host must be a DNS name (optionally prefixed with '*.'), not an IP literal.",
      "items": {
        "$ref": "#/$defs/NetAllowlistEntryV1"
      },
      "minItems": 0,
      "uniqueItems": true
    },
    "ttl_seconds": {
      "type": "integer",
      "minimum": 1,
      "maximum": 86400,
      "description": "Optional TTL hint (seconds) for elevated network permissions (typically mode=unrestricted). Mothership may use it for approvals/audit; enforcement may be added later."
    },
    "x_ext": {
      "type": "object",
      "description": "Extension point for forward-compatible metadata. Keys MUST be prefixed with 'x_'.",
      "propertyNames": {
        "pattern": "^x_[A-Za-z0-9_]+$"
      },
      "additionalProperties": true
    }
  },
  "allOf": [
    {
      "if": {
        "properties": {
          "mode": {
            "const": "allowlist"
          }
        }
      },
      "then": {
        "required": [
          "allow"
        ]
      },
      "else": {
        "not": {
          "required": [
            "allow"
          ]
        }
      }
    }
  ],
  "$defs": {
    "NetAllowlistEntryV1": {
      "type": "string",
      "minLength": 4,
      "maxLength": 255,
      "description": "Destination in authority-form 'host:port'. host is a DNS name (ASCII/punycode) optionally with a leading '*.' wildcard, port is 1-65535. Example: 'github.com:443', '*.example.com:443'.",
      "pattern": "^(localhost|(\\*\\.)?([A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+):([0-9]{1,5})$"
    },
    "NetDecisionReasonCodeV1": {
      "type": "string",
      "enum": [
        "OK",
        "NET_MODE_NONE",
        "NOT_IN_ALLOWLIST",
        "PORT_NOT_ALLOWED",
        "INVALID_DESTINATION",
        "PROXY_REQUIRED",
        "SNI_MISMATCH",
        "DNS_DENIED",
        "POLICY_EXPIRED",
        "APPROVAL_REQUIRED",
        "INTERNAL_ERROR",
        "OTHER"
      ],
      "description": "Reason codes for egress decision/audit events. Codes POLICY_EXPIRED/APPROVAL_REQUIRED are reserved for future policy features."
    },
    "NetApprovalReasonCodeV1": {
      "type": "string",
      "enum": [
        "NET_UNRESTRICTED_REQUESTED",
        "NET_NON_DEFAULT_PORT_REQUESTED",
        "NET_WILDCARD_DOMAIN_REQUESTED",
        "NET_PRIVATE_DESTINATION_REQUESTED",
        "NET_CUSTOM_POLICY_REQUESTED"
      ],
      "description": "Reason codes used by Mothership to explain why a directive requires approval before enabling requested network capabilities."
    }
  }
}
```

#### 7.6.1 allowlist 匹配规则（规范性要求）

- **大小写**：域名匹配必须大小写不敏感；建议实现时统一 lower-case。
- **尾点**：对输入 `example.com.` 建议先规范化为 `example.com`（避免同一域名出现两种写法）。
- **通配语义**：
  - `*.example.com` 仅匹配 `a.example.com`、`b.a.example.com` 等子域，**不匹配**根域 `example.com`。
  - `example.com` 只匹配根域本身，不隐式覆盖子域。
- **禁止 IP 字面量**：例如 `1.2.3.4:443`、`[2001:db8::1]:443` 必须拒绝（未来如要支持，走 allowlist V2 的 CIDR/IP 语义）。
- **端口范围**：schema 的 regex 无法完全约束 1–65535，**实现必须额外校验**。

#### 7.6.2 审批触发条件（规范性建议，V1 默认）

> 审批是控制面行为；Nexus 只执行 effective capability。

建议默认触发审批的情形（至少在 `sandbox_profile=untrusted` 的 directive 中必须触发）：

1) `mode=unrestricted` → `NET_UNRESTRICTED_REQUESTED`
2) `mode=allowlist` 且存在 **非默认端口**（默认：443，可选 80）→ `NET_NON_DEFAULT_PORT_REQUESTED`
3) `mode=allowlist` 且存在 `*.` 通配域名（strict preset 下）→ `NET_WILDCARD_DOMAIN_REQUESTED`
4) `preset=custom`（用户手动编辑 allowlist）且风险评分超阈值（例如包含 22/873 等）→ `NET_CUSTOM_POLICY_REQUESTED`

> 说明：你已决定 V1 不做条目级 `approval_required` 字段；审批触发由 Mothership 的规则引擎计算即可。

#### 7.6.3 `reason_code`（冻结列表，V1）

- **运行期 deny reason（proxy/防火墙）**：使用 `NetDecisionReasonCodeV1`。
- **审批 explain reason（控制面）**：使用 `NetApprovalReasonCodeV1`。
- 兼容性要求：接收方必须能容忍未知 code（fallback 到 `OTHER`），以便未来扩展。

#### 7.6.4 DNS 解析与“私网目的地”策略（必须定义，否则 allowlist 形同虚设）

V1 allowlist 以 `domain:port` 为核心，但这并不自动等价于“只能访问公网”：

- 任意被允许的域名都可能解析到：
  - 私网 IP（RFC1918）、loopback、link-local、组播，甚至企业内网地址；
  - 或被攻击者通过 DNS rebinding/短 TTL 操作让解析结果漂移。

因此 proxy 侧需要明确的 **解析策略**（建议默认值）：

- **解析责任在 proxy**：由 proxy 自己做 DNS 解析并记录审计（不要信任沙箱内 `resolv.conf` 或自定义 resolver）。
- **默认拒绝私网/本机目的地**：若解析结果命中 private/loopback/link-local 等地址段，默认拒绝并返回明确的 `reason_code`（例如 `DNS_DENIED` 或未来扩展专用 code），同时在控制面触发 `NET_PRIVATE_DESTINATION_REQUESTED` 审批原因码。
- **连接绑定**：对每个 CONNECT 建立连接时，把“当时解析到的 IP”写入审计；未来如需要更强防 rebinding，可在连接建立后固定到该 IP（不再二次解析）。
- **`localhost` 特判**：在 Untrusted 的 network namespace 内 `localhost` 通常是沙箱自身；但在 Trusted/Host 下可能指向宿主服务，建议默认不允许或强审批。

---


## 8. 文件系统与本地 IO 控制（Deno 风格）

### 8.1 默认规则

- 沙箱内只挂载 workspace（读写）。
- 其他宿主路径默认不可见。
- `read_file/list_dir/apply_patch` 等操作必须在 workspace 范围内（realpath 校验，防 symlink 逃逸）。
- Phase 0.5 scaffolding：当 directive 未显式提供 `capabilities.fs` 时，Mothership 会按 profile 注入默认值（见 `mothership/config/conduits_defaults.yml`）。
  - 当前默认：`untrusted/trusted/darwin-automation => read=["workspace:**"], write=["workspace:**"]`；`host => read/write 为空（必须显式申请并走审批）`。

### 8.2 扩展读取（Host / Trusted 可选）

当用户需要访问“本机文档/下载目录/企业共享盘”时：
- 只能在 `Trusted` 或 `Host` profile 下启用。
- 必须显式配置路径 allowlist（并在 effective capability 中固化）：
  - `capabilities.fs.read`: 允许读取的路径集合
  - `capabilities.fs.write`: 允许写入的路径集合（更严格，尽量只允许 workspace 或特定输出目录）
- 表达建议（约定，便于跨语言实现一致）：
  - `workspace:**`：facility workspace 内任意路径
  - `host:/Users/alice/Documents/ProjectX/**`：宿主某个绝对路径及其子路径（仅 Trusted/Host 可用；Untrusted 禁止）
- 审批 UI 必须展示这些路径。

### 8.3 Patch 优先（可审计）

建议把“编辑文件”统一表达为：
- `apply_patch(patch)`（git apply 兼容格式或自研安全 patch 格式）
并在执行后强制产出 `git diff`（或目录 diff）作为工件，便于审计与回滚。

### 8.4 Linux Untrusted 的 facility 持久化模型（新增，强制 block-backed）

> 目标：避免 host 目录共享扩大攻击面；让 facility 的隔离边界与 microVM 边界一致。

- 每个 facility 对应一个 **ext4 磁盘镜像或逻辑卷**（`facility-<id>.ext4` / LVM/ZFS volume）。
- Nexus 在启动 microVM 时：
  - 将该块设备以 virtio-blk attach 到 guest（非 rootfs）。
  - guest 内 mount 到 `/workspace`（rw）。
- Directive 级临时目录：
  - 使用 tmpfs 或额外的临时块设备（便于做配额与清理）。
- diff 产出：
  - repo facility：优先 `git diff`（在 guest 内执行或在 Nexus 侧挂载镜像后执行）。
  - 非 repo：目录 diff（需要定义稳定算法/排除规则）。
- 配额与清理：
  - 镜像大小：支持 sparse + 上限；或者卷级 quota。
  - retention：按 TTL/水位清理；清理前可归档到对象存储（可选）。

---
