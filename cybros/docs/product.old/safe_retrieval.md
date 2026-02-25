# Safe Retrieval（互联网 Read）契约（Draft）

本文档把产品层的 “Internet Read（读取互联网信息）默认放行” 收敛成一个**可实现且可审计**的安全契约：Safe Retrieval。

目标：

- 让 “Read internet” 尽可能接近“读资料”，而不是“任意网络能力”。
- 在默认放行的前提下，尽量降低 SSRF / 数据外传 / 提示注入诱导访问内网 等风险。
- 为实现提供稳定边界：允许什么、不允许什么、失败时怎么报错、审计记录什么。

本契约是产品层规范，不限定实现位置（可在 Runner、控制面代理、或专用网络侧车实现）。

---

## 1) 非目标（刻意不承诺）

- 不承诺“彻底阻断”所有数据外传：LLM 可能在请求 URL/参数中编码敏感信息；Safe Retrieval 只能尽量降低风险并提供止损机制。
- 不承诺支持浏览器级渲染（JS 执行、登录态 cookie、复杂交互）。
- 不承诺支持任意协议（仅 HTTP(S)）。

---

## 2) 输入契约（Request）

### 2.1 允许的协议与方法

- 仅允许 `https://` 与 `http://`（建议默认优先 https）。
- 仅允许 `GET`（可选支持 `HEAD` 用于探测；但最终内容仍需 GET）。
- 禁止 request body。
- 禁止 URL userinfo（例如 `https://user:pass@example.com/...`）。

### 2.2 Headers 与身份

- 禁止调用方自定义 headers（避免携带 secrets/cookies/自定义 auth）。
- 可由系统固定注入最小 headers（例如稳定 `User-Agent`、`Accept`）。
- 禁止携带 cookie。

### 2.3 URL 与重定向

- 最大重定向次数：建议 `<= 5`。
- 每一次重定向的目标都必须重新通过本契约的“目的地校验”（见 3.1）。
- 禁止协议降级（https → http）除非 admin 明确允许（默认拒绝）。
- 禁止重定向到非 HTTP(S) scheme。
- 端口策略建议默认收敛到 `80/443`（可配置 allowlist 放开其它端口）。

### 2.4 请求大小与并发

- 每次请求必须有超时（连接/读取）。
- 必须有最大响应大小上限（含解压后），超限直接中止并标记为 `response_too_large`。
- 必须有全局与 per-user 的并发上限（避免滥用当爬虫/DoS 工具）。

---

## 3) 安全约束（Security）

### 3.1 目的地校验（SSRF/内网访问防护）

Safe Retrieval 必须拒绝访问以下目标（默认阻断）：

#### 3.1.1 默认阻断：域名与网段（清单）

域名（建议）：

- `localhost`、`*.localhost`
- `.local`（以及可配置的 internal TLD，例如 `.internal` / `.corp`）

IPv4 网段（建议最小集）：

- `127.0.0.0/8`（loopback）
- `10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`（RFC1918 私网）
- `169.254.0.0/16`（link-local）
- `100.64.0.0/10`（CGNAT）
- `0.0.0.0/8`（"this network"）
- `224.0.0.0/4`（multicast）与 `240.0.0.0/4`（reserved）
- `198.18.0.0/15`（benchmark/testing）

IPv6 网段（建议最小集）：

- `::1/128`（loopback）
- `::/128`（unspecified）
- `fe80::/10`（link-local）
- `fc00::/7`（unique local）
- `ff00::/8`（multicast）

Metadata / 特殊目标（建议最小集）：

- `169.254.169.254`（常见云 metadata）
- 其它云厂商 metadata IP（以配置表维护；默认阻断）

实现要点（避免 DNS rebind）：

- 必须对 hostname 做 DNS 解析，并对解析出的 IP 做 allow/deny 判定（建议：只允许 global-unicast）。
- 若一个 hostname 解析到多个 IP，只要其中任意一个 IP 被阻断，就应拒绝该请求（避免部分解析结果落入内网）。
- 连接建立后必须校验实际 peer IP；并对重定向链路逐跳校验。

#### 3.1.2 端口策略（建议）

- 默认仅允许 `80/443`。
- 如需允许其它端口，必须通过显式 allowlist（例如 `example.com:8443`），并落审计（不落内容）。

### 3.2 输出处理（内容安全）

- 不返回二进制：对非文本 content-type（或无法安全解码）返回错误 `unsupported_content_type`。
- 对 HTML：
  - 以“抽取正文文本”为主（去脚本/样式/表单）；不要执行任何 JS。
  - 必须限制输出文本长度（避免上下文/成本爆炸）。
- 对 JSON：
  - 允许返回，但必须限制最大 bytes，并对深度/节点数做限制（避免 JSON 炸弹）。

### 3.3 “敏感片段”最小止损（可选但强烈建议）

为了降低“模型把 secrets 拼进 URL 参数”这一类事故，Safe Retrieval 可以做最小止损：

- 对 URL（含 query）做轻量敏感模式检测（例如典型 API key 前缀、长 token、`Authorization=` 等）。
- 命中时拒绝请求，并返回稳定错误码 `suspected_secret_in_url`（不在错误详情回显原始 token）。

---

## 4) 输出契约（Response）

返回必须是结构化对象（示例字段）：

- `final_url`（最终 URL；可选：仅返回 origin + path，或返回 hash）
- `status_code`
- `content_type`
- `bytes_read`
- `elapsed_ms`
- `text`（抽取后的文本；有长度上限）
- `truncated`（是否截断）
- `error_code`（若失败）

### 4.1 稳定错误码（建议清单）

> 错误码必须稳定；错误详情（details）必须是 safe 的（不回显 query 中的疑似 secret）。

- `invalid_url`（URL 解析失败）
- `unsupported_scheme`（非 http/https）
- `unsupported_method`（非 GET/HEAD）
- `userinfo_not_allowed`（URL 含 userinfo）
- `port_not_allowed`（端口不在允许范围）
- `dns_failed`（DNS 解析失败）
- `destination_blocked`（目的地命中阻断规则：内网/metadata/internal TLD 等）
- `redirect_limit_exceeded`（重定向次数超限）
- `redirect_blocked`（重定向目标被阻断或不合法）
- `tls_error`（TLS/SNI/证书相关错误）
- `connection_timeout`
- `read_timeout`
- `response_too_large`
- `unsupported_content_type`
- `decode_error`（文本解码失败）
- `extract_failed`（HTML/JSON 抽取失败）
- `suspected_secret_in_url`（疑似 secret 出现在 URL/query；可选启用）
- `rate_limited`（被系统限流）

---

## 5) 审计与可观测性（不落内容）

规范性要求：

- 审计/用量统计只记录计量与元数据，不记录响应内容 `text`。
- 至少记录：
  - `user_id` / `space_id` / `conversation_id` / `turn_id`
  - `requested_host`（或 `requested_host_hash`）
  - `requested_url_hash`（推荐：对完整 URL 做 HMAC/哈希；避免落 query 明文）
  - `status_code` / `error_code` / `elapsed_ms` / `bytes_read` / `truncated`
  - 是否发生重定向（及次数）
  - 目的地校验结果摘要（例如 `blocked_reason` / `resolved_ip_count`；不落 IP 明细也可）

---

## 6) 与 permission gate 的关系

- Safe Retrieval 属于 `Read` 能力，按产品默认策略可不弹窗（见 `docs/product/behavior_spec.md`）。
- 但它不等于“任意网络能力”：更宽的网络（私网、unrestricted、宿主网卡直出等）属于危险能力，必须走审批与审计。

---

## 7) 实现 Checklist（工程化落地清单）

请求与解析：

- [ ] URL parse + normalize（含拒绝 userinfo、拒绝非 http(s)）
- [ ] 方法限制（GET/HEAD）+ 禁止 body
- [ ] 禁止 caller 自定义 headers/cookies；系统仅注入最小 headers
- [ ] 端口限制（默认 80/443；可配置 allowlist）

目的地校验：

- [ ] DNS 解析 hostname（A/AAAA）并对所有解析 IP 做阻断判定（global-unicast only）
- [ ] 连接建立后校验 peer IP（防 DNS rebind）
- [ ] 重定向逐跳校验（每跳都重新做 parse + DNS + 阻断）

传输与资源限制：

- [ ] 连接/读取超时
- [ ] 最大响应 bytes（含解压后）+ 截断标记
- [ ] 最大重定向次数
- [ ] 全局与 per-user 并发上限；必要时 rate limit

内容处理：

- [ ] 仅允许文本类响应（HTML/JSON/text/*），其余 `unsupported_content_type`
- [ ] HTML：不执行 JS；抽取正文文本；限制最大输出字符数
- [ ] JSON：限制 bytes + depth + nodes；必要时做摘要

止损（可选但建议）：

- [ ] URL/query “疑似 secret”检测（命中则 `suspected_secret_in_url` 且不回显 token）

审计与可观测性：

- [ ] 审计不落内容；记录 `requested_host/url_hash`、耗时、bytes、错误码、重定向次数
- [ ] 错误码稳定且可聚合；details 安全

