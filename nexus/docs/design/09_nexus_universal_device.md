# 09. Nexus 作为统一设备抽象层（Universal Device Abstraction）

> 版本：v0.3（2026-02-27）
>
> 前置文档：[00_overview](00_overview.md)、[01_architecture](01_architecture.md)
>
> 目标：将 Nexus 从"代码执行引擎"泛化为"统一的平台能力代理"，通过 kind 分类 + capabilities 声明 + bridge 模式，以最小自研成本覆盖 OpenClaw 的全部外设支持能力。
>
> 实施策略：**服务端做实、客户端做假**。本阶段只在 Mothership 侧实现完整的数据模型、API、WebSocket 通道和策略引擎；手机、IoT、外设的接入通过测试用例验证 + 轻量 PoC 模拟器证明协议可行性，不实际开发终端 App 或第三方平台插件。

---

## 1. 动机与问题陈述

### 1.1 OpenClaw 的设备能力

OpenClaw Gateway + Node 架构支持：

| 能力类别 | 具体能力 | 平台 |
|---------|---------|------|
| 摄像头 | 拍照（JPG）、录像（MP4）、前/后置切换 | iOS, Android, macOS |
| 屏幕 | 截屏、录屏 | iOS, Android, macOS |
| 音频 | 录音、语音转写（多 provider）、TTS（ElevenLabs） | iOS, Android, macOS |
| 位置 | GPS 定位（精确/粗略） | iOS, Android |
| 语音唤醒 | 全局唤醒词、持续对话循环 | iOS, Android, macOS |
| Canvas/UI | WebView 截图、加载 URL、执行 JS、A2UI 渲染 | iOS, Android, macOS |
| 系统命令 | shell 执行（审批 + allowlist）、通知 | macOS, Linux |
| SMS | 发送短信 | Android |
| 媒体理解 | 图片/音频/视频自动摘要 | 所有（通过 API） |

OpenClaw 的实现方式：Gateway 作为中心，所有 Node 通过 WebSocket 连接，Gateway 直接 RPC 调用 Node 上的能力。

### 1.2 Cybros 当前状态

Cybros 的 Conduits 子系统目前**仅支持代码执行**：

- Territory = 代码执行节点（server / desktop）
- Directive = 一次 shell 命令执行（sandbox 隔离）
- Policy = FS/Net/Secrets 访问控制
- 通信 = REST Pull（2s 轮询）

**需要覆盖但当前无法支持的场景**：手机摄像头/麦克风/GPS、IoT 设备控制、桌面 GUI 自动化（非 shell 命令部分）、实时设备命令调度。

### 1.3 核心洞察

> **所有连接到 Cybros 的东西都是某种 Nexus，只是 kind 不同。**

- 手机 = 一个提供摄像头/麦克风/GPS 能力的 Nexus
- Home Assistant = 一个代理数十个 IoT 子设备的 Bridge Nexus
- Linux 服务器 = 一个提供沙箱代码执行能力的 Nexus
- macOS 桌面 = 一个同时提供代码执行和 GUI 自动化的 Nexus

不应该包办一切。成熟的 IoT 平台（Home Assistant、Node-RED）已经解决了设备发现和协议适配，我们只需要提供标准的接入协议让它们成为 Bridge Nexus。

---

## 2. 前一版草案的正确性问题

经过对 OpenClaw 文档和 Cybros 现有代码的全面审查，前一版草案存在以下需要修正的问题：

### 2.1 Labels JSONB 过载（严重）

**问题**：前一版把 kind、capabilities、tags、location、display_name、bridge_entities 全部塞进 Territory 的 `labels` jsonb 字段。

**为什么不行**：
- `labels` 当前用于 enrollment token 传入的标签 + heartbeat 上报的运行时元数据（os、arch），由 `record_heartbeat!` 合并更新
- 身份字段（kind、platform）需要 schema 级别的约束（enum、NOT NULL），jsonb 无法提供
- `bridge_entities` 作为嵌套数组放在 jsonb 里，无法高效查询子实体（需要 jsonb_array_elements + 嵌套条件）
- capabilities 是可变长数组，GIN 索引可以支持 `?` 操作符查询，但混在 labels 里会导致 index bloat

**修正**：将身份和结构化字段提升为正式列；labels 仅保留自由格式的键值标签。

### 2.2 Directive 模型不适合设备命令（严重）

**问题**：前一版隐含"所有操作都走 Directive"，但 Directive 是 100% 面向命令执行设计的。

**Directive 的字段全景**：command、shell、cwd、sandbox_profile、exit_code、stdout_bytes、stderr_bytes、diff_blob、snapshot_before/after、artifacts_manifest、runtime_ref...

**设备命令的特征**（以 `camera.snap` 为例）：
- 无 command/shell/cwd（不是 shell 命令）
- 无 sandbox_profile（不需要沙箱隔离）
- 无 exit_code/stdout/stderr（不是进程输出）
- 输入：JSON 参数 `{ facing: "back", quality: 80 }`
- 输出：二进制照片 + JSON 元数据
- 执行时间：< 5 秒（vs Directive 的分钟级）
- 不需要 Facility（没有持久工作区）

强行复用 Directive 会导致：大量字段为 NULL、Policy 解析（FS/Net/Secrets）毫无意义、lease/log_chunks 流程是多余的开销。

**修正**：引入平行的 Command 模型，专门处理设备能力调用。

### 2.3 Pull 模型对实时操作的延迟问题（中等）

**问题**：当前 Pull 模型每 2 秒轮询一次。对于"开灯""拍照"等操作，0-2 秒的额外延迟虽非致命，但体验明显不如即时推送。

**更关键的问题**：对于手机，持续 2 秒轮询会严重消耗电量和流量；iOS 更会在后台杀掉持续网络活动的 App。

**OpenClaw 的做法**：WebSocket 长连接，Gateway 直接 push 命令到 Node。

**修正**：为 Command 通道增加 WebSocket（Action Cable）推送能力，REST 作为降级回退。

### 2.4 Policy 模型不覆盖设备权限（中等）

**问题**：当前 Policy 的能力维度是 `fs`（路径前缀）、`net`（域名:端口）、`secrets`（密钥引用）、`sandbox_profile_rules`、`approval`。这些都是执行特有的。

**设备权限的特征**：
- "允许使用摄像头"是一个布尔判断，不是路径前缀匹配
- "允许控制灯光"不涉及网络域名 allowlist
- 审批语义更简单（不需要 3 层 FS-outside-workspace 检查）

**修正**：在现有 Policy 模型中增加 `device` 维度，使用通配符匹配的 allow/deny 列表。

### 2.5 Bridge 子实体生命周期缺失（中等）

**问题**：前一版仅提到 `bridge_entities` 在 labels 中，但未定义：
- 实体如何发现和同步
- 实体状态如何跟踪
- 实体不可达时如何处理
- 子实体的寻址机制

**修正**：独立的 `conduits_bridge_entities` 表 + heartbeat 驱动的实体同步协议。

### 2.6 二进制数据传输路径缺失（低）

**问题**：前一版未说明照片、录音等二进制数据如何传回 Mothership。当前协议只有 log_chunks（文本分片）和 diff_blob（单个 ActiveStorage 附件）。

**修正**：Command 的 result 支持 JSON 元数据 + ActiveStorage 附件（照片/视频/录音）。

---

## 3. 核心设计决策

### D20: 双轨模型（Dual-Track）

**决定**：保留现有 Directive 轨道（执行），新增 Command 轨道（设备能力调用），两个轨道共享 Territory 身份和认证基础设施。

**理由**：
- Directive 模型在 6 个 Phase 中经过了充分验证和加固，不应该为了适配设备命令而退化
- Command 有完全不同的生命周期（秒级 vs 分钟级）、不同的输入输出格式（JSON+binary vs shell+stdout）、不同的权限模型
- 两个轨道共享：Territory mTLS 认证、Account/User 多租户、AuditEvent 审计、Enrollment 流程

```
                    ┌─────────────────────────┐
                    │      Mothership         │
                    │                         │
                    │  ┌─────────┬──────────┐ │
                    │  │Directive│ Command  │ │
                    │  │ Track   │ Track    │ │
                    │  │(执行)   │(设备能力) │ │
                    │  └────┬────┴────┬─────┘ │
                    │       │         │       │
                    │  ┌────┴─────────┴────┐  │
                    │  │  Territory 认证    │  │
                    │  │  Policy 引擎      │  │
                    │  │  Audit 审计       │  │
                    │  └──────────────────┘  │
                    └───────────┬─────────────┘
                                │
              ┌─────────────────┼─────────────────┐
              │                 │                   │
        ┌─────▼─────┐   ┌──────▼──────┐   ┌───────▼───────┐
        │ Nexus     │   │ Nexus       │   │ Nexus         │
        │ :server   │   │ :mobile     │   │ :bridge       │
        │           │   │             │   │               │
        │ Directive │   │ Command     │   │ Command       │
        │ + Command │   │ only        │   │ only          │
        └───────────┘   └─────────────┘   └───────────────┘
```

### D21: Territory Kind 作为一等字段

**决定**：`kind` 作为 Territory 的枚举列（非 jsonb），影响：
- 可用的通信通道（Pull / WebSocket / 两者皆有）
- 可声明的 capabilities 范围
- 配对方式
- 心跳内容

| Kind | 部署形态 | 通信 | Directive 轨道 | Command 轨道 |
|------|---------|------|--------------|------------|
| `server` | Linux daemon | REST Pull | ✓ | ✓（有限：系统信息采集等） |
| `desktop` | macOS menubar app | REST Pull + WebSocket | ✓ | ✓（GUI 自动化、截屏等） |
| `mobile` | iOS/Android app | WebSocket（主）+ REST（降级） | ✗ | ✓（摄像头、麦克风、GPS 等） |
| `bridge` | 第三方平台插件 | REST Pull + WebSocket | ✗ | ✓（代理子设备能力） |

### D22: Capabilities 命名空间

**决定**：采用两级点分命名 `namespace.action`，namespace 定义能力类别，action 定义具体操作。

**命名空间注册表**（可扩展）：

| Namespace | 含义 | 典型 Kind |
|-----------|------|----------|
| `sandbox` | 代码执行与隔离 | server, desktop |
| `camera` | 摄像头 | mobile, bridge, desktop |
| `audio` | 音频采集与播放 | mobile, bridge, desktop |
| `screen` | 屏幕捕获与录制 | mobile, desktop |
| `location` | 地理位置 | mobile |
| `notification` | 推送通知 | mobile |
| `sms` | 短信 | mobile (Android) |
| `automation` | GUI/系统自动化 | desktop |
| `iot` | IoT 设备控制 | bridge |
| `sensor` | 传感器读取 | bridge, mobile |
| `system` | 系统信息采集 | server, desktop |

**保留的执行 capabilities**（映射现有 sandbox_profile）：
- `sandbox.exec` — 可执行代码
- `sandbox.bwrap` — 支持 bubblewrap 隔离
- `sandbox.container` — 支持容器隔离
- `sandbox.firecracker` — 支持 microVM 隔离
- `sandbox.host` — 支持宿主直接执行（需审批）
- `sandbox.darwin_automation` — 支持 macOS 自动化

**设备 capabilities**：
- `camera.snap` — 拍照
- `camera.record` — 录像
- `screen.capture` — 截屏
- `screen.record` — 录屏
- `audio.record` — 录音
- `audio.play` — 播放音频
- `location.get` — 获取位置
- `notification.push` — 推送通知
- `sms.send` — 发送短信
- `automation.applescript` — AppleScript 执行
- `automation.shortcuts` — Shortcuts 调用
- `iot.light.control` — 灯光控制
- `iot.switch.control` — 开关控制
- `iot.lock.control` — 门锁控制
- `iot.climate.control` — 温控
- `sensor.temperature` — 温度
- `sensor.humidity` — 湿度
- `sensor.motion` — 运动检测
- `system.info` — 系统信息

**通配符匹配规则**（用于 Policy）：
- `camera.*` 匹配 `camera.snap`、`camera.record` 等
- `iot.*` 匹配所有 `iot.` 开头的能力
- `*` 匹配所有能力（危险，仅 global default 使用）

### D23: 三级降级通信（WebSocket → Push Notification → REST）

**决定**：Command 推送采用三级降级模型：

1. **WebSocket**（Action Cable）：App 前台时首选，sub-second 延迟
2. **Push Notification**（APNs/FCM）：App 后台时 silent push 唤醒，再通过 REST 拉取执行
3. **REST Poll**：兜底，命令排队等待设备上线

**理由**：
- Action Cable 是 Rails 内置能力，无需引入额外依赖
- WebSocket 提供 sub-second 延迟，适合设备控制场景
- iOS 会杀掉后台 WebSocket 连接，Push Notification 是唯一可靠的后台唤醒手段
- REST 回退保证完全离线后重连时的消息不丢失
- 比 gRPC 双向流更简单（不需要 proto 编译、Go 客户端也容易实现 WebSocket）

**实现节奏**：本阶段实现 WebSocket + REST，Push Notification 预留接口和三级降级分支（push 分支 mock，不实际发送）。详见 Section 11.3。

### D24: Bridge Nexus 不做设备发现

**决定**：Bridge 不负责设备发现，只负责：(1) 将自身已知的实体清单上报给 Mothership；(2) 接收并转发命令到底层平台。

**理由**：
- Home Assistant 自身的设备发现做得极其完善（mDNS、SSDP、Zigbee coordinator、Matter、蓝牙等）
- 我们重做发现没有价值，反而引入巨大复杂度
- Bridge 定位是"翻译层"而非"控制器"

---

## 4. 数据模型变更

### 4.1 Territory 模型扩展

```ruby
# 新增列（migration）
add_column :conduits_territories, :kind, :string, null: false, default: "server"
add_column :conduits_territories, :platform, :string  # linux, darwin, ios, android, homeassistant, nodered, ...
add_column :conduits_territories, :display_name, :string
add_column :conduits_territories, :location, :string  # 层级式："home/living-room"、"office/floor-3"
add_column :conduits_territories, :tags, :jsonb, default: []  # ["homelab", "always-on", "production"]
add_column :conduits_territories, :capabilities, :jsonb, default: []  # ["sandbox.exec", "camera.snap", ...]
add_column :conduits_territories, :websocket_connected_at, :datetime  # WebSocket 连接状态
add_column :conduits_territories, :runtime_status, :jsonb, default: {}, null: false  # Nexus 运行时状态（负载感知）
add_column :conduits_territories, :push_token, :string               # APNs / FCM 注册令牌（预留）
add_column :conduits_territories, :push_platform, :string            # "apns" | "fcm"（预留）

add_index :conduits_territories, :kind
add_index :conduits_territories, :capabilities, using: :gin  # GIN 索引支持 ? 操作符
add_index :conduits_territories, :tags, using: :gin
```

**字段职责划分**：

| 字段 | 职责 | 写入时机 | 示例 |
|------|------|---------|------|
| `kind` | 身份类型（枚举） | enrollment 时确定 | `"server"` |
| `platform` | 运行平台 | enrollment 时确定 | `"linux"`, `"ios"` |
| `display_name` | 人类可读名称 | enrollment 或用户修改 | `"James 的 iPhone"` |
| `location` | 物理位置标记 | 用户配置 | `"home/living-room"` |
| `tags` | 自由标签 | 用户配置 | `["homelab", "always-on"]` |
| `capabilities` | 能力声明列表 | heartbeat 上报 | `["camera.snap", "location.get"]` |
| `labels` | 运行时元数据（保留） | heartbeat 上报 | `{"os": "linux", "arch": "amd64"}` |
| `capacity` | 资源容量（保留） | heartbeat 上报 | `{"sandbox_health": {...}}` |
| `runtime_status` | 运行时负载状态 | heartbeat 上报 | `{"running_directives": 2, "running_commands": 1, "uptime_seconds": 3600}` |

**模型扩展**：

```ruby
# app/models/conduits/territory.rb

KINDS = %w[server desktop mobile bridge].freeze
validates :kind, inclusion: { in: KINDS }

# 能力查询 scope
scope :with_capability, ->(cap) {
  where("capabilities @> ?", [cap].to_json)
}

# 通配符能力查询：camera.* 匹配 camera.snap, camera.record 等
scope :with_capability_matching, ->(pattern) {
  if pattern.end_with?(".*")
    prefix = pattern.delete_suffix(".*")
    where("EXISTS (SELECT 1 FROM jsonb_array_elements_text(capabilities) AS c WHERE c LIKE ?)", "#{prefix}.%")
  else
    with_capability(pattern)
  end
}

scope :at_location, ->(loc) {
  where("location LIKE ?", "#{loc}%")
}

scope :with_tag, ->(tag) {
  where("tags @> ?", [tag].to_json)
}

scope :websocket_connected, -> {
  where.not(websocket_connected_at: nil)
}

# Command 轨道可用
scope :command_capable, -> {
  online.where.not(capabilities: [])
}

# Directive 轨道可用（仅 server / desktop）
scope :directive_capable, -> {
  online.where(kind: %w[server desktop])
}
```

### 4.2 Bridge Entity 模型（新增）

```ruby
# 表：conduits_bridge_entities
# 模型：Conduits::BridgeEntity

create_table :conduits_bridge_entities, id: :uuid do |t|
  t.references :territory, null: false, foreign_key: { to_table: :conduits_territories }, type: :uuid
  t.references :account, null: false, foreign_key: true, type: :uuid

  t.string :entity_ref, null: false    # 平台侧标识："light.living_room"（HA entity_id）
  t.string :entity_type, null: false   # "light", "camera", "sensor", "switch", "lock", "climate"
  t.string :display_name               # "客厅灯"
  t.jsonb :capabilities, default: []   # ["iot.light.control", "iot.light.brightness"]
  t.string :location                   # "home/living-room"（可继承 Territory 的 location）
  t.jsonb :state, default: {}          # 最后已知状态：{"on": true, "brightness": 80}
  t.boolean :available, default: true  # 实体是否可达
  t.datetime :last_seen_at

  t.timestamps
end

add_index :conduits_bridge_entities, [:territory_id, :entity_ref], unique: true
add_index :conduits_bridge_entities, :capabilities, using: :gin
add_index :conduits_bridge_entities, :entity_type
```

```ruby
# app/models/conduits/bridge_entity.rb

class Conduits::BridgeEntity < ApplicationRecord
  belongs_to :territory, class_name: "Conduits::Territory"
  belongs_to :account

  validates :entity_ref, presence: true, uniqueness: { scope: :territory_id }
  validates :entity_type, presence: true
  validate :territory_must_be_bridge

  scope :available, -> { where(available: true) }
  scope :of_type, ->(type) { where(entity_type: type) }

  scope :with_capability, ->(cap) {
    where("capabilities @> ?", [cap].to_json)
  }

  scope :at_location, ->(loc) {
    where("location LIKE ?", "#{loc}%")
  }

  private

  def territory_must_be_bridge
    errors.add(:territory, "must be a bridge") unless territory&.kind == "bridge"
  end
end
```

### 4.3 Command 模型（新增）

```ruby
# 表：conduits_commands
# 模型：Conduits::Command

create_table :conduits_commands, id: :uuid do |t|
  t.references :account, null: false, foreign_key: true, type: :uuid
  t.references :territory, null: false, foreign_key: { to_table: :conduits_territories }, type: :uuid
  t.references :bridge_entity, foreign_key: { to_table: :conduits_bridge_entities }, type: :uuid
  t.references :requested_by_user, foreign_key: { to_table: :users }, type: :uuid
  t.references :approved_by_user, foreign_key: { to_table: :users }, type: :uuid

  t.string :capability, null: false   # "camera.snap", "iot.light.control"
  t.jsonb :params, default: {}        # 能力特定参数
  t.string :state, null: false, default: "queued"
  # 状态机: queued → dispatched → completed | failed | timed_out | canceled
  #         queued → awaiting_approval → queued (approved) | canceled (rejected)
  t.jsonb :result, default: {}        # 能力特定结果
  t.string :error_message             # 失败原因
  t.integer :timeout_seconds, default: 30
  t.jsonb :policy_snapshot            # 创建时的策略评估快照
  t.string :result_hash               # SHA256 幂等性哈希（与 Directive 一致）
  t.jsonb :approval_reasons, default: []  # 需要审批的原因列表

  t.datetime :dispatched_at
  t.datetime :completed_at

  t.timestamps
end

add_index :conduits_commands, [:territory_id, :state]
add_index :conduits_commands, :state
add_index :conduits_commands, :approved_by_user_id
```

```ruby
# app/models/conduits/command.rb

class Conduits::Command < ApplicationRecord
  include AASM

  belongs_to :account
  belongs_to :territory, class_name: "Conduits::Territory"
  belongs_to :bridge_entity, class_name: "Conduits::BridgeEntity", optional: true
  belongs_to :requested_by_user, class_name: "User", optional: true
  belongs_to :approved_by_user, class_name: "User", optional: true

  # ActiveStorage 附件（照片、视频、录音等二进制结果）
  has_one_attached :result_attachment

  validates :capability, presence: true
  validates :timeout_seconds, numericality: { greater_than: 0, less_than_or_equal_to: 300 }
  validate :capability_supported_by_territory
  validate :bridge_entity_belongs_to_territory

  aasm column: :state, whiny_transitions: true do
    state :queued, initial: true
    state :awaiting_approval
    state :dispatched
    state :completed
    state :failed
    state :timed_out
    state :canceled

    event :request_approval do
      transitions from: :queued, to: :awaiting_approval
    end

    event :approve do
      transitions from: :awaiting_approval, to: :queued
    end

    event :reject do
      transitions from: :awaiting_approval, to: :canceled
      after { update!(completed_at: Time.current) }
    end

    event :dispatch do
      transitions from: :queued, to: :dispatched
      after { update!(dispatched_at: Time.current) }
    end

    event :complete do
      transitions from: :dispatched, to: :completed
      after { update!(completed_at: Time.current) }
    end

    event :fail do
      transitions from: [:queued, :dispatched], to: :failed
      after { update!(completed_at: Time.current) }
    end

    event :time_out do
      transitions from: [:queued, :dispatched, :awaiting_approval], to: :timed_out
      after { update!(completed_at: Time.current) }
    end

    event :cancel do
      transitions from: [:queued, :dispatched, :awaiting_approval], to: :canceled
      after { update!(completed_at: Time.current) }
    end
  end

  scope :pending, -> { where(state: %w[queued dispatched]) }
  scope :pending_approval, -> { where(state: "awaiting_approval") }
  scope :for_territory, ->(tid) { where(territory_id: tid) }
  scope :expired, -> {
    where(state: %w[queued dispatched awaiting_approval])
      .where("created_at + (timeout_seconds * interval '1 second') < ?", Time.current)
  }

  def terminal?
    state.in?(%w[completed failed timed_out canceled])
  end

  # Compute idempotency hash for result submission (matches Directive track pattern).
  def compute_result_hash(status:, result_data:, error_message:)
    canonical = {
      "status" => status.to_s,
      "result" => normalize_json(result_data || {}),
      "error_message" => error_message,
    }
    Digest::SHA256.hexdigest(JSON.generate(canonical))
  end

  private

  def capability_supported_by_territory
    return if territory.nil?
    return if territory.capabilities&.include?(capability)

    # 检查 bridge_entity 的 capabilities
    if bridge_entity.present?
      return if bridge_entity.capabilities&.include?(capability)
    end

    errors.add(:capability, "#{capability} is not supported by this territory")
  end

  def bridge_entity_belongs_to_territory
    return if bridge_entity.nil?
    return if bridge_entity.territory_id == territory_id

    errors.add(:bridge_entity, "does not belong to the target territory")
  end

  def normalize_json(value)
    case value
    when Hash then value.map { |k, v| [k.to_s, normalize_json(v)] }.sort_by(&:first).to_h
    when Array then value.map { |v| normalize_json(v) }
    else value
    end
  end
end
```

### 4.4 Command Permission 模型（Policy 扩展）

在现有 `Conduits::Policy` 的 content jsonb 中增加 `device` 维度：

```ruby
# Policy content schema 扩展
{
  # === 现有维度（Directive 轨道，保持不变） ===
  "fs": { "read": [...], "write": [...] },
  "net": { "mode": "none|allowlist|unrestricted", "allow": [...] },
  "secrets": { ... },
  "sandbox_profile_rules": { ... },
  "approval": { ... },

  # === 新增维度（Command 轨道） ===
  "device": {
    "allowed": ["camera.*", "location.get", "iot.light.*"],
    "denied": ["sms.send"],
    "approval_required": ["camera.record", "iot.lock.control"]
  }
}
```

**合并语义**（与现有 restrictive-ceiling 一致）：
- `allowed`：intersection（两个级别都必须 allow 才生效）
- `denied`：union（任何级别 deny 都会 deny）
- `approval_required`：union（任何级别要求审批都需要审批）
- denied 优先于 allowed（显式拒绝不可被低级别覆盖）

```ruby
# app/lib/conduits/device_policy_v1.rb

module Conduits
  module DevicePolicyV1
    # 检查某能力是否被允许
    def self.evaluate(capability, device_policies)
      # 合并所有层级的 device policy
      merged = merge_policies(device_policies)

      # denied 优先
      return { verdict: :denied } if matches_any?(capability, merged[:denied])

      # 检查 allowed
      unless matches_any?(capability, merged[:allowed])
        return { verdict: :denied, reason: "not in allowed list" }
      end

      # 检查是否需要审批
      if matches_any?(capability, merged[:approval_required])
        return { verdict: :needs_approval }
      end

      { verdict: :skip }
    end

    # 通配符匹配
    def self.matches_any?(capability, patterns)
      patterns.any? do |pattern|
        if pattern == "*"
          true
        elsif pattern.end_with?(".*")
          capability.start_with?(pattern.delete_suffix(".*") + ".")
        else
          capability == pattern
        end
      end
    end

    # 层级合并
    def self.merge_policies(policies)
      result = { allowed: nil, denied: [], approval_required: [] }

      policies.sort_by(&:priority).each do |policy|
        device = policy.content&.dig("device") || {}

        if device["allowed"]
          result[:allowed] = if result[:allowed].nil?
            device["allowed"]
          else
            intersect_patterns(result[:allowed], device["allowed"])
          end
        end

        result[:denied] |= (device["denied"] || [])
        result[:approval_required] |= (device["approval_required"] || [])
      end

      # 如果没有任何 allowed 声明，默认拒绝所有
      result[:allowed] ||= []
      result
    end
  end
end
```

---

## 5. 通信协议扩展

### 5.1 协议总览

```
                    Mothership
                    ┌─────────────────────────────┐
                    │                             │
                    │  REST API (/conduits/v1/*)   │ ← Directive 轨道（已有）
                    │                             │   + Command 轨道（新增端点）
                    │  Action Cable (WebSocket)   │ ← Command 推送（新增）
                    │                             │
                    └──────────────┬──────────────┘
                                   │
                    ┌──────────────┼──────────────┐
                    │              │              │
              ┌─────▼────┐  ┌─────▼────┐  ┌─────▼────┐
              │ server   │  │ mobile   │  │ bridge   │
              │          │  │          │  │          │
              │ REST Pull│  │ WebSocket│  │ REST Pull│
              │ (2s poll)│  │ (推送)   │  │ +WS     │
              └──────────┘  └──────────┘  └──────────┘
```

### 5.2 现有端点（保持不变）

Directive 轨道的全部端点保持不变，协议版本仍为 V1：

| 方法 | 路径 | 用途 |
|------|------|------|
| POST | `/conduits/v1/territories/enroll` | 注册 |
| POST | `/conduits/v1/territories/heartbeat` | 心跳 |
| POST | `/conduits/v1/polls` | 拉取 Directive |
| POST | `/conduits/v1/directives/:id/started` | 上报开始 |
| POST | `/conduits/v1/directives/:id/heartbeat` | Directive 心跳 |
| POST | `/conduits/v1/directives/:id/log_chunks` | 上传日志 |
| POST | `/conduits/v1/directives/:id/finished` | 上报完成 |

### 5.3 新增端点（Command 轨道）

**Territory API（Nexus 侧调用，mTLS 认证）**：

```
GET    /conduits/v1/commands/pending          — Territory 拉取待执行命令（降级回退）
POST   /conduits/v1/commands/:id/result      — Territory 提交命令结果（支持 result_hash 幂等）
POST   /conduits/v1/commands/:id/cancel       — 取消命令
```

**Mothership API（管理面板 / Agent 调用，X-Account-Id + X-User-Id 认证）**：

```
POST   /mothership/api/v1/commands            — 创建命令（含 DevicePolicy 评估）
GET    /mothership/api/v1/commands            — 列出命令
GET    /mothership/api/v1/commands/:id        — 查看命令详情
POST   /mothership/api/v1/commands/:id/approve — 审批命令（不可审批自己创建的）
POST   /mothership/api/v1/commands/:id/reject  — 拒绝命令
```

**POST /conduits/v1/commands/:id/result**

Territory 执行完命令后回调 Mothership。

请求（Territory → Mothership，需 Territory 认证）：
```json
{
  "status": "completed",
  "result": {
    "lat": 37.7749,
    "lon": -122.4194,
    "accuracy_m": 5.2
  },
  "attachment_base64": "...",
  "attachment_content_type": "image/jpeg",
  "attachment_filename": "snap_20260226_143022.jpg",
  "error_message": null
}
```

响应：
```json
{
  "ok": true,
  "command_id": "...",
  "final_state": "completed"
}
```

**GET /conduits/v1/commands/pending**

WebSocket 不可用时的降级回退。Territory 轮询待执行命令。

请求参数：`?max=5`

响应：
```json
{
  "commands": [
    {
      "command_id": "...",
      "capability": "camera.snap",
      "params": { "facing": "back", "quality": 80 },
      "bridge_entity_ref": null,
      "timeout_seconds": 30,
      "created_at": "2026-02-26T14:30:22Z"
    }
  ],
  "retry_after_seconds": 5
}
```

### 5.4 WebSocket 通道（Action Cable）

```ruby
# app/channels/conduits/territory_channel.rb

module Conduits
  class TerritoryChannel < ApplicationCable::Channel
    def subscribed
      territory = authenticate_territory!
      return reject unless territory

      stream_for territory
      territory.update!(websocket_connected_at: Time.current)
    end

    def unsubscribed
      territory = current_territory
      territory&.update!(websocket_connected_at: nil)
    end

    # Territory 直接通过 WebSocket 提交命令结果
    def command_result(data)
      command = Conduits::Command.find(data["command_id"])
      # ... 与 REST 端点相同的处理逻辑
    end
  end
end
```

**Mothership 推送命令**：

```ruby
# app/services/conduits/command_dispatcher.rb
# 三级降级：WebSocket → Push Notification → REST Poll（详见 Section 11.3）

class Conduits::CommandDispatcher
  def dispatch(command)
    territory = command.territory

    if territory.websocket_connected?
      # 优先级 1: WebSocket 推送（sub-second）
      push_via_websocket(command)
    elsif territory.push_token.present?
      # 优先级 2: Push Notification 唤醒（本阶段 mock，不实际发送）
      push_via_notification(command)
    else
      # 优先级 3: 保持 queued 状态，等待 Territory 通过 REST 拉取
    end
  end

  private

  def push_via_websocket(command)
    Conduits::TerritoryChannel.broadcast_to(command.territory, {
      type: "command",
      command_id: command.id,
      capability: command.capability,
      params: command.params,
      bridge_entity_ref: command.bridge_entity&.entity_ref,
      timeout_seconds: command.timeout_seconds
    })
    command.dispatch!
  end

  def push_via_notification(command)
    # 本阶段：记录意图到日志，不实际调用 APNs/FCM
    Rails.logger.info("[CommandDispatcher] push_notification fallback for command #{command.id} (mock)")
    command.dispatch!
  end
end
```

### 5.5 心跳协议扩展

**现有 heartbeat 请求格式**：

```json
{
  "nexus_version": "0.5.0",
  "labels": { "os": "linux", "arch": "amd64" },
  "capacity": { "sandbox_health": { ... } },
  "running_directives_count": 1
}
```

**扩展后**（新字段为可选，老版本 Nexus 不受影响）：

```json
{
  "nexus_version": "0.7.0",
  "labels": { "os": "ios", "device_model": "iPhone 16 Pro" },
  "capacity": {
    "foreground": true,
    "battery_level": 85,
    "network_type": "wifi"
  },
  "capabilities": ["camera.snap", "camera.record", "location.get", "audio.record"],
  "runtime_status": {
    "running_directives": 2,
    "running_commands": 1,
    "directive_ids": ["uuid-1", "uuid-2"],
    "uptime_seconds": 3600
  },

  "bridge_entities": [
    {
      "entity_ref": "light.living_room",
      "entity_type": "light",
      "display_name": "客厅灯",
      "capabilities": ["iot.light.control", "iot.light.brightness", "iot.light.color"],
      "location": "home/living-room",
      "state": { "on": true, "brightness": 80 },
      "available": true
    },
    {
      "entity_ref": "camera.front_door",
      "entity_type": "camera",
      "display_name": "前门摄像头",
      "capabilities": ["camera.snap", "camera.record"],
      "location": "home/entrance",
      "state": { "recording": false },
      "available": true
    }
  ]
}
```

**Mothership 处理 heartbeat 时**：
1. 更新 Territory 的 `capabilities`（如果传入）
2. 更新 Territory 的 `runtime_status`（如果传入），用于负载感知调度
3. 如果有 `bridge_entities`，执行实体同步：
   - Upsert（按 territory_id + entity_ref 匹配）
   - 将 heartbeat 中不存在但数据库中存在的实体标记为 `available: false`
   - 更新 `last_seen_at` 和 `state`

**负载感知调度**：PollService 在 `lease_directives` 时检查 `territory.has_capacity?`（基于 `runtime_status.running_directives` vs `capacity.max_concurrent`）。Territory 已满时直接返回空结果，避免无谓加锁。

---

## 6. 配对流程

### 6.1 Server / Desktop（现有流程，不变）

```
管理员生成 enrollment token（含 labels）
  → 管理员把 token 配置到 Nexus 的 config 文件
  → Nexus 启动时 POST /conduits/v1/territories/enroll
  → Mothership 签发 mTLS 证书
  → 配对完成
```

仅在 enrollment 请求中新增 `kind` 和 `platform` 字段：

```json
{
  "enroll_token": "...",
  "name": "homelab-server-1",
  "kind": "server",
  "platform": "linux",
  "labels": { "arch": "amd64" },
  "metadata": { ... },
  "csr_pem": "..."
}
```

### 6.2 Mobile（交互式配对，新增）

```
用户打开 Mothership Web UI → 点击"添加设备"
  → 选择"手机"
  → Mothership 生成一次性 enrollment token
  → 页面显示 QR Code（JSON 编码）
  → 用户在手机 App 中扫码
  → App 解析 QR Code：
      {
        "mothership_url": "https://cybros.example.com",
        "enroll_token": "...",
        "account_id": "..."
      }
  → App POST /conduits/v1/territories/enroll
      {
        "enroll_token": "...",
        "name": "James 的 iPhone",
        "kind": "mobile",
        "platform": "ios",
        "labels": { "device_model": "iPhone 16 Pro" },
        "csr_pem": "..."
      }
  → Mothership 签发 mTLS 证书
  → App 保存证书，建立 WebSocket 连接
  → Mothership UI 实时显示新设备上线
```

**与 OpenClaw 的区别**：
- OpenClaw 使用 Gateway 本地审批（CLI 命令 `openclaw nodes approve`）
- Cybros 使用预生成的 enrollment token（含 TTL 和一次性使用约束），不需要额外审批步骤
- 这样更安全（token 有时效）且更适合 Web UI 交互

### 6.3 Bridge（插件配置配对，新增）

```
用户在 Home Assistant 中安装 Cybros Bridge 插件
  → 插件配置页面：
      - Mothership URL
      - Enrollment Token（从 Mothership Web UI 生成）
  → 插件 POST /conduits/v1/territories/enroll
      {
        "enroll_token": "...",
        "name": "Home Assistant - 家庭网关",
        "kind": "bridge",
        "platform": "homeassistant",
        "labels": { "ha_version": "2026.2" }
      }
  → Mothership 签发 mTLS 证书
  → 插件保存证书
  → 插件启动定期 heartbeat，上报 bridge_entities
  → 插件建立 WebSocket 连接，接收命令推送
```

---

## 7. Command 调度生命周期

### 7.1 Agent 发起命令

Agent 通过 Tool 接口发起设备命令。Tool 定义示例：

```ruby
# Agent tool: device_command
# 输入：
#   capability: "camera.snap"
#   target: { location: "home/front-door" }  或  { territory_id: "..." }  或  { tag: "always-on" }
#   params: { facing: "back", quality: 80 }
# 输出：命令结果（JSON + 可选附件）
```

### 7.2 Mothership 寻址目标设备

```ruby
# app/services/conduits/command_target_resolver.rb

class Conduits::CommandTargetResolver
  def resolve(account:, capability:, target:)
    # 1. 直接指定 territory_id
    if target[:territory_id]
      territory = account.territories.find(target[:territory_id])
      entity = resolve_entity(territory, capability, target)
      return { territory: territory, entity: entity }
    end

    # 2. 按能力 + 位置 + 标签查询
    scope = account.territories.online.with_capability(capability)
    scope = scope.at_location(target[:location]) if target[:location]
    scope = scope.with_tag(target[:tag]) if target[:tag]

    # 3. 也搜索 bridge 子实体
    entity_scope = account.bridge_entities
                         .available
                         .with_capability(capability)
    entity_scope = entity_scope.at_location(target[:location]) if target[:location]

    # 4. 合并候选
    candidates = scope.to_a
    entity_candidates = entity_scope.includes(:territory).to_a

    # 5. 选择最佳目标
    if candidates.any?
      territory = candidates.first  # 简单策略：取第一个
      return { territory: territory, entity: nil }
    end

    if entity_candidates.any?
      entity = entity_candidates.first
      return { territory: entity.territory, entity: entity }
    end

    raise Conduits::NoTargetAvailable, "No device found for #{capability} at #{target}"
  end
end
```

### 7.3 完整命令流

**正常流程（policy verdict = allowed）**：

```
                Agent                    Mothership                     Territory
                  │                          │                             │
                  │  POST /commands           │                             │
                  │  { capability, target,    │                             │
                  │    params }               │                             │
                  │─────────────────────────>│                             │
                  │                          │                             │
                  │                   1. 解析目标设备（CommandTargetResolver）│
                  │                   2. 评估 device policy（CommandPolicyGate）
                  │                   3. 创建 Command (queued) + policy_snapshot
                  │                   4. 记录 AuditEvent（command.created）│
                  │                          │                             │
                  │  201 { command_id,       │  WebSocket push:            │
                  │    state: "queued" }     │  { type: "command", ... }   │
                  │<─────────────────────────│───────────────────────────>│
                  │                          │  Command state: dispatched  │
                  │                          │                             │
                  │                          │            Territory 执行能力
                  │                          │            (拍照 / 控灯 / ...)
                  │                          │                             │
                  │                          │  POST /commands/:id/result  │
                  │                          │  { status, result,          │
                  │                          │    attachment }             │
                  │                          │<───────────────────────────│
                  │                          │                             │
                  │                   5. 计算 result_hash（幂等性）        │
                  │                   6. 更新 Command (completed)          │
                  │                   7. 记录 AuditEvent（command.completed）
                  │                          │                             │
                  │  GET /commands/:id       │                             │
                  │  { result, attachment }   │                             │
                  │<─────────────────────────│                             │
```

**审批流程（policy verdict = needs_approval）**：

```
                Agent/User               Mothership                  Approver
                  │                          │                          │
                  │  POST /commands           │                          │
                  │  { capability: "iot.lock.control" }                  │
                  │─────────────────────────>│                          │
                  │                          │                          │
                  │                   1. CommandPolicyGate → needs_approval
                  │                   2. 创建 Command (queued)          │
                  │                   3. request_approval! → awaiting_approval
                  │                   4. AuditEvent（command.awaiting_approval）
                  │                          │                          │
                  │  202 { command_id,       │                          │
                  │    state: "awaiting_approval",                      │
                  │    approval_reasons }    │                          │
                  │<─────────────────────────│                          │
                  │                          │                          │
                  │                          │  POST /commands/:id/approve
                  │                          │<─────────────────────────│
                  │                          │                          │
                  │                   5. lock! + approve! → queued      │
                  │                   6. CommandDispatcher.dispatch      │
                  │                   7. AuditEvent（command.approved）  │
                  │                          │                          │
                  │                          │  200 { state: "queued",  │
                  │                          │    dispatched_via }      │
                  │                          │─────────────────────────>│
                  │                          │                          │
                  │                   ... (same as normal flow) ...     │
```

**安全约束**：
- 发起者不可审批自己创建的命令（`requested_by_user_id != current_user.id`）
- 审批/拒绝使用 `lock!` + `ActiveRecord::Base.transaction` 防止并发竞态
- AASM `whiny_transitions: true` + `rescue AASM::InvalidTransition` 捕获状态冲突

### 7.4 超时与重试

```ruby
# app/jobs/conduits/command_timeout_job.rb

class Conduits::CommandTimeoutJob < ApplicationJob
  queue_as :conduits

  # 每 10 秒检查一次，回收 queued/dispatched/awaiting_approval 超时命令
  def perform
    Conduits::Command.expired.find_each do |command|
      command.time_out!
      Conduits::AuditService.new(account: command.account, command: command).record(
        "command.timed_out",
        payload: {
          command_id: command.id,
          capability: command.capability,
          territory_id: command.territory_id,
          age_seconds: (Time.current - command.created_at).round,
        }
      )
    rescue AASM::InvalidTransition => e
      Rails.logger.warn("[CommandTimeoutJob] Skipping command #{command.id}: #{e.message}")
    end
  end
end
```

**注意**：`expired` scope 包含 `awaiting_approval` 状态。长时间未审批的命令也会超时，防止命令永久阻塞。`time_out!` 事件支持从 `queued`、`dispatched`、`awaiting_approval` 三种状态转换。

---

## 8. Bridge 协议

### 8.1 Bridge SDK 接口定义

Bridge 是运行在第三方平台上的插件。我们需要提供标准的 SDK/API 让第三方开发者可以开发 bridge。

**Bridge 需要实现的核心接口**：

```
1. Enrollment（启动时）
   → POST /conduits/v1/territories/enroll
   → kind: "bridge", platform: "<platform_name>"

2. Heartbeat（定期，30s-60s）
   → POST /conduits/v1/territories/heartbeat
   → 包含 bridge_entities 列表（全量上报，Mothership 做 reconcile）

3. WebSocket 连接（可选但推荐）
   → 连接 Action Cable
   → 订阅 TerritoryChannel
   → 接收 command 推送

4. 命令执行
   → 收到 command（via WebSocket 或 REST poll）
   → 翻译为平台 API 调用
   → 返回结果（POST /conduits/v1/commands/:id/result）
```

### 8.2 Home Assistant Bridge 示例

```python
# cybros_bridge/ha_bridge.py (Home Assistant Custom Component 示例)

class CybrosBridge:
    """Cybros Bridge for Home Assistant."""

    async def handle_command(self, command):
        """接收 Mothership 推送的命令，翻译为 HA 服务调用。"""

        capability = command["capability"]
        params = command["params"]
        entity_ref = command.get("bridge_entity_ref")

        if capability == "iot.light.control":
            if params.get("action") == "turn_on":
                await self.hass.services.async_call(
                    "light", "turn_on",
                    {"entity_id": entity_ref, **params.get("service_data", {})}
                )
                return {"status": "completed", "result": {"action": "turned_on"}}

            elif params.get("action") == "turn_off":
                await self.hass.services.async_call(
                    "light", "turn_off",
                    {"entity_id": entity_ref}
                )
                return {"status": "completed", "result": {"action": "turned_off"}}

        elif capability == "camera.snap":
            image = await self.hass.components.camera.async_get_image(entity_ref)
            return {
                "status": "completed",
                "result": {"content_type": image.content_type},
                "attachment_base64": base64.b64encode(image.content).decode()
            }

        elif capability.startswith("sensor."):
            state = self.hass.states.get(entity_ref)
            return {
                "status": "completed",
                "result": {
                    "value": state.state,
                    "unit": state.attributes.get("unit_of_measurement"),
                    "last_updated": state.last_updated.isoformat()
                }
            }

    async def collect_entities(self):
        """收集 HA 中的所有实体，转换为 bridge_entities 格式。"""
        entities = []
        for state in self.hass.states.async_all():
            domain = state.entity_id.split(".")[0]
            caps = DOMAIN_CAPABILITY_MAP.get(domain, [])
            if not caps:
                continue

            entities.append({
                "entity_ref": state.entity_id,
                "entity_type": domain,
                "display_name": state.attributes.get("friendly_name", state.entity_id),
                "capabilities": caps,
                "location": state.attributes.get("area_id"),  # HA area → location
                "state": self._extract_state(state),
                "available": state.state != "unavailable"
            })
        return entities

# 域名 → 能力映射
DOMAIN_CAPABILITY_MAP = {
    "light": ["iot.light.control", "iot.light.brightness"],
    "switch": ["iot.switch.control"],
    "lock": ["iot.lock.control"],
    "climate": ["iot.climate.control"],
    "camera": ["camera.snap", "camera.record"],
    "sensor": ["sensor.temperature", "sensor.humidity", "sensor.motion"],
    "binary_sensor": ["sensor.motion", "sensor.door"],
    "cover": ["iot.cover.control"],
    "fan": ["iot.fan.control"],
    "media_player": ["audio.play"],
}
```

### 8.3 实体同步协议

**全量上报 + 服务端 Reconcile**（简单可靠，heartbeat 驱动）：

```ruby
# app/services/conduits/bridge_entity_sync_service.rb

class Conduits::BridgeEntitySyncService
  def sync(territory:, reported_entities:)
    return unless territory.kind == "bridge"

    existing = territory.bridge_entities.index_by(&:entity_ref)
    reported_refs = Set.new

    reported_entities.each do |entry|
      ref = entry["entity_ref"]
      reported_refs.add(ref)

      if existing[ref]
        # Update existing
        existing[ref].update!(
          entity_type: entry["entity_type"],
          display_name: entry["display_name"],
          capabilities: entry["capabilities"] || [],
          location: entry["location"],
          state: entry["state"] || {},
          available: entry.fetch("available", true),
          last_seen_at: Time.current
        )
      else
        # Create new
        territory.bridge_entities.create!(
          account: territory.account,
          entity_ref: ref,
          entity_type: entry["entity_type"],
          display_name: entry["display_name"],
          capabilities: entry["capabilities"] || [],
          location: entry["location"],
          state: entry["state"] || {},
          available: entry.fetch("available", true),
          last_seen_at: Time.current
        )
      end
    end

    # Mark missing entities as unavailable
    missing_refs = existing.keys - reported_refs.to_a
    territory.bridge_entities.where(entity_ref: missing_refs).update_all(available: false)
  end
end
```

---

## 9. Agent 集成

### 9.1 Device Command Tool

Agent 使用的 tool 定义。这是 Mothership 暴露给 Agent Program 的能力接口：

```ruby
# 在 AgentCore 的 tool registry 中注册

{
  name: "device_command",
  description: "Execute a command on a connected device (phone camera, IoT device, etc.)",
  parameters: {
    type: "object",
    properties: {
      capability: {
        type: "string",
        description: "The capability to invoke (e.g., 'camera.snap', 'iot.light.control', 'location.get')"
      },
      target: {
        type: "object",
        description: "How to find the target device",
        properties: {
          location: { type: "string", description: "Hierarchical location (e.g., 'home/living-room')" },
          tag: { type: "string", description: "Device tag (e.g., 'always-on')" },
          territory_id: { type: "string", description: "Specific territory ID (if known)" },
          entity_ref: { type: "string", description: "Specific bridge entity ref (if known)" }
        }
      },
      params: {
        type: "object",
        description: "Capability-specific parameters"
      }
    },
    required: ["capability"]
  }
}
```

### 9.2 使用示例

**Agent 拍照**：
```json
{
  "tool": "device_command",
  "params": {
    "capability": "camera.snap",
    "target": { "location": "home/entrance" },
    "params": { "facing": "back", "quality": 80 }
  }
}
```

**Agent 开灯**：
```json
{
  "tool": "device_command",
  "params": {
    "capability": "iot.light.control",
    "target": { "location": "home/living-room" },
    "params": { "action": "turn_on", "service_data": { "brightness": 200 } }
  }
}
```

**Agent 获取位置**：
```json
{
  "tool": "device_command",
  "params": {
    "capability": "location.get",
    "target": { "tag": "james-phone" },
    "params": { "accuracy": "precise" }
  }
}
```

**Agent 查询设备列表**（辅助 tool）：
```json
{
  "tool": "list_devices",
  "params": {
    "capability": "camera.*",
    "location": "home"
  }
}
```

返回：
```json
[
  {
    "territory_id": "...",
    "display_name": "James 的 iPhone",
    "kind": "mobile",
    "capabilities": ["camera.snap", "camera.record", "location.get"],
    "location": "home",
    "online": true
  },
  {
    "territory_id": "...",
    "entity_ref": "camera.front_door",
    "display_name": "前门摄像头",
    "kind": "bridge",
    "capabilities": ["camera.snap", "camera.record"],
    "location": "home/entrance",
    "online": true
  }
]
```

---

## 10. 与 OpenClaw 的能力对等

| OpenClaw 能力 | Cybros 实现方式 | 备注 |
|--------------|---------------|------|
| `canvas.*`（WebView 控制） | desktop Nexus: `automation.*` capabilities | macOS 已有 darwin-automation 支持 |
| `camera.snap` / `camera.record` | mobile Nexus / bridge Nexus | 手机原生 + HA 摄像头 |
| `screen.record` | desktop / mobile Nexus | 需要平台权限 |
| `location.get` | mobile Nexus: `location.get` | iOS/Android GPS |
| `sms.send` | mobile Nexus: `sms.send` (Android only) | iOS 限制无法直接发 SMS |
| `system.run` | server / desktop Nexus: Directive 轨道 | 已有完整实现 |
| `voicewake.*` | 暂不支持 | 需要语音处理基础设施，列入 future |
| `talk` (连续对话) | 暂不支持 | 需要 TTS/STT 集成，列入 future |
| `audio.record` | mobile Nexus: `audio.record` | 需要平台录音权限 |
| 智能家居控制 | bridge Nexus → Home Assistant | 覆盖所有 HA 支持的协议 |
| Telegram/WhatsApp 接入 | Mothership Channel Adapter | 不是 Nexus 的职责 |

**能力覆盖率**：v1 目标覆盖 OpenClaw 的核心设备能力（camera、location、system、IoT）。语音相关（voicewake、talk）作为 future plan，因其依赖额外的 ML 基础设施。

---

## 11. 边界与不做什么

### 11.1 永久性设计边界

1. **不自建 IoT 协议栈** — Zigbee/Z-Wave/Matter/BLE 全部交给 Home Assistant 等成熟平台
2. **不做设备发现** — Bridge 平台自己处理发现，我们只接收上报的实体清单
3. **不做实时流媒体** — 摄像头返回快照/短视频片段，不做 RTSP 中继
4. **Channel Adapter 不是 Nexus** — Telegram/Slack 等消息通道是 Mothership 的能力，不混入 Nexus
5. **不做语音唤醒** — 需要 on-device 语音处理，复杂度高，列入 future plan

### 11.2 本阶段不做（服务端做实，客户端做假）

本阶段目标是让 Mothership 侧的协议和基础设施**完全就绪**，但不实际开发终端：

| 不做 | 替代验证方式 |
|------|------------|
| iOS / Android App | 测试用例 + PoC mock client（Go/Ruby 脚本模拟 mobile enrollment → WebSocket → command 全流程） |
| Home Assistant 插件 | 测试用例 + PoC mock bridge（模拟 entity 上报 → command 接收 → result 回调） |
| Mothership 设备管理 Web UI | 仅 API 层（测试覆盖），UI 后续阶段补 |
| Push Notification（APNs/FCM） | 服务端预留 push_token 字段和 Dispatcher 三级降级逻辑，但不接入推送服务。测试中 mock push delivery |
| Agent tool 注册（device_command / list_devices） | 测试用例验证 API 合约，与 AgentCore 的正式集成后续补 |

### 11.3 Push Notification 设计（完整方案，本阶段预留接口）

完整的 Mobile 通信是三层降级模型：

```
优先级 1: WebSocket（App 前台）   → sub-second 延迟
优先级 2: Push Notification（App 后台） → silent push 唤醒 → REST 拉取 → 执行
优先级 3: REST Poll（兜底）        → 命令排队，App 回到前台时执行
```

**Territory 需要的字段**（本阶段 migration 中预留）：

```ruby
add_column :conduits_territories, :push_token, :string       # APNs / FCM 注册令牌
add_column :conduits_territories, :push_platform, :string     # "apns" | "fcm"
```

**CommandDispatcher 三级降级**（本阶段实现逻辑，push 分支 mock）：

```ruby
class Conduits::CommandDispatcher
  def dispatch(command)
    territory = command.territory

    if territory.websocket_connected?
      push_via_websocket(command)
    elsif territory.push_token.present?
      push_via_notification(command)  # 本阶段：记录意图，不实际发送
    else
      # 保持 queued，等待 REST poll
    end
  end
end
```

**Capability 分类影响推送方式**：

```ruby
# 后台可执行（silent push 足够）
BACKGROUND_CAPABLE = %w[location.get sensor.* iot.* system.info notification.push].freeze

# 需要前台（弹用户可见通知引导打开 App）
FOREGROUND_REQUIRED = %w[camera.* screen.* audio.record].freeze
```

**iOS 硬约束**：
- Silent push 有频率限制（Apple 不公开阈值，经验值每小时几十次以内）
- 后台执行时间约 30 秒（够 location.get / IoT 转发，不够录长视频）
- Camera/Screen 必须 App 在前台（iOS 安全限制）

### 11.4 残余风险

1. **Bridge 单点故障**：如果 Home Assistant 宕机，所有通过它代理的设备不可控。建议用户配置 HA 高可用。
2. **二进制传输效率**：通过 REST + base64 传输照片/视频效率不高（base64 膨胀 33%）。后续可考虑直接二进制上传或对象存储预签名 URL。
3. **WebSocket 连接稳定性**：移动网络环境下 WebSocket 可能频繁断连重连，需要客户端实现指数退避重连 + 断线期间的命令排队。

---

## 12. 对现有设计的影响

### 12.1 不需要改动的部分

| 组件 | 原因 |
|------|------|
| Directive 模型 | Command 是独立模型，Directive 保持不变 |
| Directive 轨道 API | 所有 `/conduits/v1/directives/*` 端点不变 |
| Poll 模型 | server/desktop 仍然使用 REST Pull 拉取 Directive |
| mTLS 认证 | 所有 kind 的 Territory 共用 mTLS 基础设施 |
| Policy 层级合并 | 新增 `device` 维度，但合并算法不变（restrictive-ceiling） |
| AuditEvent | 新增事件类型，但模型和基础设施不变 |
| Enrollment 流程 | 端点不变，只是请求中新增 `kind`/`platform` 字段 |
| Facility/Workspace | 仅 server/desktop 使用，mobile/bridge 不涉及 |
| Sandbox drivers | 仅 Directive 轨道使用，Command 轨道不涉及 |
| Go Nexus daemon | 本阶段不改动 Go 代码，新协议通过 PoC 客户端验证 |

### 12.2 本阶段需要改动的部分（Mothership 侧）

| 改动 | 影响面 | 复杂度 |
|------|--------|--------|
| Territory 新增列（kind, platform, display_name, location, tags, capabilities, push_token, push_platform） | Migration + Model | 低 |
| BridgeEntity 新表 + 模型 | Migration + Model | 低 |
| Command 新表 + 模型 + AASM | Migration + Model | 中 |
| Action Cable TerritoryChannel | 新增 Channel | 中 |
| CommandDispatcher 服务 | 新增 Service | 中 |
| CommandTargetResolver 服务 | 新增 Service | 中 |
| BridgeEntitySyncService | 新增 Service | 低 |
| DevicePolicyV1 | 新增 Lib | 低 |
| Heartbeat 端点扩展 | 修改现有 Controller | 低 |
| Enrollment 端点扩展 | 修改现有 Controller | 低 |
| Command REST 端点（result / pending / cancel） | 新增 Controller | 中 |
| CommandTimeoutJob | 新增 Job | 低 |
| AuditEvent 新事件类型 | 扩展现有 | 低 |

### 12.3 本阶段不改动、后续阶段实现的部分

| 改动 | 阶段 | 备注 |
|------|------|------|
| Go Nexus WebSocket 客户端 | 后续 | 本阶段用 PoC 脚本验证 |
| iOS / Android App | 后续 | 本阶段用 mock client 测试 |
| Home Assistant 插件 | 后续 | 本阶段用 mock bridge 测试 |
| Mothership 设备管理 Web UI | 后续 | 本阶段仅 API |
| APNs / FCM 推送集成 | 后续 | 本阶段预留字段和接口 |
| AgentCore tool 注册 | 后续 | 本阶段通过 API 测试验证合约 |

### 12.4 向后兼容性

- 现有 server/desktop Nexus（Go daemon）**无需修改即可继续工作**
- `kind` 字段 default 为 `"server"`，现有 Territory 自动归类
- Heartbeat 中的新字段是可选的，老版本 Nexus 不传不影响
- 新 API 端点不与现有端点冲突

---

## 13. 实施路线

> 原则：**服务端做实、客户端做假**。Mothership 侧的数据模型、API、WebSocket、策略引擎全部实现到位并通过测试覆盖。终端设备的接入通过测试用例和 PoC 模拟器验证。

### Phase 7a: 数据模型与基础能力

**目标**：Territory 泛化 + Command 模型 + 设备权限策略。

| # | 任务 | 产出 | 验证方式 |
|---|------|------|---------|
| 1 | Territory 新增列 migration（kind, platform, display_name, location, tags, capabilities, push_token, push_platform, websocket_connected_at） | Migration + Model 扩展 | 单元测试：enum validation、scope 查询 |
| 2 | BridgeEntity 模型（新表） | Migration + Model | 单元测试：CRUD、uniqueness、capability 查询 |
| 3 | Command 模型 + AASM 状态机（新表） | Migration + Model | 单元测试：状态转换、validation、expired scope |
| 4 | DevicePolicyV1（capability 通配符匹配 + 层级合并） | Lib 模块 | 单元测试：通配符匹配、intersection、deny 优先级 |
| 5 | Enrollment 端点扩展（接受 kind/platform 字段） | Controller 修改 | 集成测试：mobile/bridge enrollment |
| 6 | Heartbeat 端点扩展（capabilities 上报 + bridge_entities 同步） | Controller 修改 + BridgeEntitySyncService | 集成测试：capability 更新、entity upsert/reconcile |
| 7 | AuditEvent 新事件类型 | AuditService 扩展 | 单元测试 |

### Phase 7b: Command 轨道 REST API

**目标**：Command 的创建、调度、结果提交、超时回收全链路可用。

| # | 任务 | 产出 | 验证方式 |
|---|------|------|---------|
| 1 | CommandTargetResolver（按 capability + location + tag 解析目标） | Service | 单元测试：直连 territory、bridge entity、多候选选择、no target 异常 |
| 2 | Command 创建 API（内部，Agent/管理员调用） | Service | 集成测试：创建 + device policy 检查 + audit |
| 3 | `GET /conduits/v1/commands/pending`（Territory 拉取待执行命令） | Controller | 集成测试：认证、按 territory 过滤、max 参数 |
| 4 | `POST /conduits/v1/commands/:id/result`（Territory 提交结果） | Controller | 集成测试：状态转换、JSON result、attachment 上传、幂等 |
| 5 | `POST /conduits/v1/commands/:id/cancel` | Controller | 集成测试：取消 queued/dispatched 状态 |
| 6 | CommandTimeoutJob | Job | 单元测试：expired command 回收 |
| 7 | **E2E 测试：Command REST 全流程** | 集成测试 | mobile enrollment → heartbeat w/ capabilities → 创建 command → pending poll → submit result → 验证最终状态 |

### Phase 7c: WebSocket 推送通道

**目标**：Action Cable 实时推送 Command 到 Territory，三级降级调度。

| # | 任务 | 产出 | 验证方式 |
|---|------|------|---------|
| 1 | Action Cable TerritoryChannel（订阅、认证、连接状态追踪） | Channel | 集成测试：连接/断开 → websocket_connected_at 更新 |
| 2 | CommandDispatcher（WebSocket → Push Notification → REST 三级降级） | Service | 单元测试：三种路径分支、push mock |
| 3 | WebSocket command 推送 | Channel broadcast | 集成测试：创建 command → 验证 broadcast payload |
| 4 | WebSocket command_result 回调 | Channel action | 集成测试：通过 WS 提交结果 → command 状态更新 |
| 5 | **E2E 测试：WebSocket 全流程** | 集成测试 | territory WS 连接 → command 创建 → WS push → WS result → 验证 |

### Phase 7d: PoC 模拟器（技术验证）

**目标**：用轻量脚本模拟真实终端设备，证明协议端到端可行。

| # | PoC | 模拟场景 | 形态 |
|---|-----|---------|------|
| 1 | **Mock Mobile Client** | (1) enrollment（kind=mobile）→ (2) WebSocket 连接 → (3) 收到 camera.snap 命令 → (4) 返回模拟照片（fixture JPEG） → (5) 收到 location.get → (6) 返回模拟坐标 | Ruby 脚本（复用 Mothership 测试基础设施）或独立 Go 小程序 |
| 2 | **Mock Bridge Client** | (1) enrollment（kind=bridge）→ (2) heartbeat 上报 bridge_entities（3 个模拟灯 + 1 个模拟传感器）→ (3) WebSocket 连接 → (4) 收到 iot.light.control → (5) 返回成功 → (6) 收到 sensor.temperature → (7) 返回模拟读数 | Ruby 脚本或 Go 小程序 |
| 3 | **Command 寻址验证** | Agent 发起"打开客厅的灯"→ Mothership 解析 location + capability → 找到 bridge entity → 下发到 bridge territory → bridge 返回结果 | 集成测试（可在 7b E2E 基础上扩展） |
| 4 | **多设备同类 capability 场景** | 多个 territory 都有 camera.snap（一个 mobile、一个 bridge camera）→ 验证 target resolver 的候选排序和选择 | 集成测试 |

**PoC 判定标准**：
- Mock client 可以走完 enrollment → WebSocket → command dispatch → result 全流程
- 中间无 hack/workaround，全部走正式 API 端点和 Channel
- 如果 PoC 过程中发现协议设计问题，先修协议再继续

### 开发顺序与依赖关系

```
Phase 7a ──→ Phase 7b ──→ Phase 7d（PoC）
    │              │
    └──→ Phase 7c ─┘

7a 是基础（数据模型），7b 和 7c 可并行但都依赖 7a
7d 依赖 7b + 7c 完成后做端到端验证
```

### 后续阶段（本轮不做，仅记录）

| 阶段 | 内容 | 前置条件 |
|------|------|---------|
| Phase 8a: Go Nexus Command 支持 | Go daemon 增加 WebSocket client + command handler | 7b 协议稳定 |
| Phase 8b: Mobile App | iOS/Android 原生 App（enrollment、WebSocket、camera/location/audio） | 7d PoC 验证通过 |
| Phase 8c: Push Notification | APNs/FCM 集成、Dispatcher push 分支接入真实推送 | 8b App 可用 |
| Phase 8d: Bridge SDK + HA 插件 | Python SDK + Home Assistant Custom Component | 7d PoC 验证通过 |
| Phase 8e: Agent 集成 | device_command / list_devices tool 注册到 AgentCore | 7b API 稳定 |
| Phase 8f: 设备管理 Web UI | Mothership 前端：添加设备、QR 码生成、设备/实体列表、状态监控 | 7a 模型稳定 |

---

## 14. 架构总览图

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Mothership (控制平面)                        │
│                                                                     │
│  ┌─────────────┬──────────────┬────────────┬────────────────────┐  │
│  │  Agent      │  Directive   │  Command   │  Device Registry   │  │
│  │  Programs   │  Scheduler   │  Dispatcher│  (Territory +      │  │
│  │             │  (Poll)      │  (Push)    │   BridgeEntity)    │  │
│  └──────┬──────┴───────┬──────┴──────┬─────┴────────┬───────────┘  │
│         │              │             │              │               │
│  ┌──────┴──────────────┴─────────────┴──────────────┴───────────┐  │
│  │           Policy Engine (FS/Net/Secrets + Device)             │  │
│  │           Audit Trail (AuditEvent)                            │  │
│  │           mTLS Certificate Authority                          │  │
│  └──────────────────────────────────────────────────────────────┘  │
└────────────────────────────┬────────────────────────────────────────┘
                             │
           ┌─────────────────┼─────────────────────────┐
           │                 │                           │
    ┌──────▼──────┐   ┌──────▼──────┐           ┌───────▼───────────┐
    │ Nexus       │   │ Nexus       │           │ Nexus             │
    │ :server     │   │ :mobile     │           │ :bridge           │
    │             │   │             │           │                   │
    │ Linux       │   │ iOS /       │           │ Home Assistant    │
    │ headless    │   │ Android     │           │ Plugin            │
    │ daemon      │   │ app         │           │                   │
    │             │   │             │           │   ┌──────────┐    │
    │ ┌─────────┐ │   │ 📷 camera  │           │   │ 💡 lights │    │
    │ │ sandbox │ │   │ 🎤 audio   │           │   │ 📷 cams  │    │
    │ │  exec   │ │   │ 📍 GPS     │           │   │ 🌡 sensors│    │
    │ │ (bwrap/ │ │   │ 📲 notify  │           │   │ 🔒 locks │    │
    │ │  fc/    │ │   │ 📱 SMS(A)  │           │   │ ...      │    │
    │ │  ctr)   │ │   │            │           │   └──────────┘    │
    │ └─────────┘ │   └────────────┘           └───────────────────┘
    │             │
    │ ┌─────────┐ │
    │ │ system  │ │
    │ │  info   │ │
    │ └─────────┘ │
    └─────────────┘
```

---

## 15. 设计原则总结

1. **不破坏现有** — Directive 轨道（6 个 Phase 的成果）完全保持不变
2. **双轨并行** — 执行（Directive）和设备控制（Command）各自独立演进
3. **不包办一切** — IoT 交给 Bridge 生态，我们只提供接入协议
4. **渐进式扩展** — 从 server 到 desktop 到 mobile 到 bridge，每一步都是增量
5. **共享基础设施** — mTLS、Policy、Audit、Enrollment 在所有 Kind 间共用
6. **最小自研成本** — 自研 server/desktop/mobile App；IoT 通过 Bridge SDK 接入已有平台
7. **服务端做实、客户端做假** — Mothership 侧协议和基础设施一步到位；终端设备通过测试用例 + PoC 模拟器验证，不过早投入原生 App 和第三方插件开发
8. **协议先行** — 先用测试证明协议正确可行，再开发真实客户端。如果 PoC 发现协议问题，修协议的成本远低于修 App

---

## 16. WebSocket-First 通信架构

### 16.1 动机

Directive 轨道原先完全依赖 REST poll（2s 间隔）。Command 轨道已有 WebSocket 推送。
统一为 **WebSocket 优先、REST 兜底**，实现：

- 近实时 Directive 通知（毫秒级 vs 2s poll 延迟）
- Action Cable ping/pong 提供 3s 粒度在线状态追踪
- WebSocket 不可用时自动降级到 REST poll，零人工干预

### 16.2 Directive Wake-Up 通知

Directive 进入 `queued` 状态时（创建 + policy skip，或人工 approve 后），`DirectiveNotifier` 向同 account 下所有 `directive_capable` + `websocket_connected` 的 territory 广播：

```json
{ "type": "directive_available", "directive_id": "...", "sandbox_profile": "untrusted" }
```

Nexus 收到后立即调用 `POST /polls` 走现有 PollService claim 逻辑。**PollService 零改动。**

设计要点：
- **Fire-and-forget** — broadcast 失败不影响正确性，REST poll 2s 内兜底
- **Database 始终为 source of truth** — 与 CommandDispatcher 同一模式
- **广播给所有在线 territory** — PollService 自带 profile/lock/policy 过滤，无需重复
- **Thundering herd 安全** — PollService 使用 `FOR UPDATE SKIP LOCKED`，竞争者拿到空结果

### 16.3 动态 Heartbeat 频率

Heartbeat 响应新增字段：
```json
{
  "ok": true,
  "territory_id": "...",
  "next_heartbeat_interval_seconds": 300,  // WS 连接时 5min，否则 30s
  "websocket_connected": true
}
```

Nexus 根据 `next_heartbeat_interval_seconds` 调整 REST heartbeat 频率。WebSocket 断开后，下一次 heartbeat 响应会恢复 30s 间隔。

REST heartbeat 仍然承载 capabilities、bridge_entities、capacity 等元数据同步，不可废弃。

### 16.4 Enrollment Config 扩展

Enrollment 响应 config 新增：
```json
{
  "cable_url": "/cable",
  "heartbeat_interval_ws_seconds": 300
}
```

告知 Nexus WebSocket 连接地址和 WS 模式下的 heartbeat 间隔。

### 16.5 TerritoryChannel 审计

subscribe/unsubscribe 触发 `territory.websocket_connected` / `territory.websocket_disconnected` 审计事件，提供 WebSocket 连接生命周期的完整可观测性。

### 16.6 Go Nexus AC 客户端（Phase 8a）

Action Cable 协议（`actioncable-v1-json` 子协议）只有 6 种 JSON 消息，Go 实现量极小：

```
← {"type":"welcome"}                              // 连接成功
← {"type":"ping","message":1709039259}             // 3s 心跳
← {"type":"confirm_subscription","identifier":"…"} // 订阅确认
← {"identifier":"…","message":{…}}                 // 推送数据（directive_available / command）
→ {"command":"subscribe","identifier":"…"}         // 订阅请求
→ {"command":"message","identifier":"…","data":"…"} // 发送数据（command_result）
```

推荐使用 `coder/websocket` 或 `gorilla/websocket` + 简单状态机实现。也可参考 `actioncable-go` 库。

---

## Appendix A: 实现状态（2026-02-27）

> 本节记录设计文档各部分的实际实现情况。

### 已完成（Phase 7a-7c）

| 设计章节 | 实现状态 | 备注 |
|---------|---------|------|
| §4.1 Territory 模型扩展 | ✓ | kind, platform, display_name, location, tags, capabilities, websocket_connected_at, runtime_status, push_token, push_platform |
| §4.2 BridgeEntity 模型 | ✓ | 独立表，entity_ref unique per territory，capabilities GIN 索引 |
| §4.3 Command 模型 | ✓ | AASM 状态机（含 awaiting_approval 审批状态），policy_snapshot，result_hash 幂等，approved_by_user，approval_reasons |
| §4.4 Policy device 维度 | ✓ | `device` jsonb 列，DevicePolicyV1 (allowed/denied/approval_required)，merge 语义（intersection/union） |
| §5 Enrollment 扩展 | ✓ | kind/platform/display_name 参数，向后兼容 |
| §6 Heartbeat 扩展 | ✓ | capabilities 上报，runtime_status 上报（负载感知），bridge_entities 同步（BridgeEntitySyncService，事务包裹） |
| §7 Command REST API（Territory 侧） | ✓ | pending (FOR UPDATE SKIP LOCKED), result (base64 attachment + result_hash 幂等), cancel |
| §7 Command API（Mothership 管理面） | ✓ | create（含 CommandPolicyGate 评估）, approve/reject（lock! + 事务 + AASM 竞态保护）, show, index |
| §8 CommandTargetResolver | ✓ | 三级查找（direct → capability+location+tag → bridge entity），确定性排序 |
| §8 CommandPolicyGate | ✓ | DevicePolicyV1 集成层，返回 allowed/denied/needs_approval + policy_snapshot |
| §9 CommandTimeoutJob | ✓ | expired scope 含 awaiting_approval，AASM 竞态保护，command: 审计关联 |
| §10 Action Cable | ✓ | Connection 双认证，TerritoryChannel (stream_for, websocket_connected_at, command_result + result_hash, directive_cancel 推送) |
| §11 CommandDispatcher | ✓ | 三级降级（WebSocket → Push mock → REST），broadcast_command + broadcast_directive_cancel 均有 rescue 错误处理 |
| §12 AuditEvent 扩展 | ✓ | command_id FK，command 事件类型（含 awaiting_approval/approved/rejected），所有审计调用包含 command: 关联 |
| §16 WebSocket-First 通信 | ✓ | DirectiveNotifier wake-up 广播，动态 heartbeat 频率，enrollment cable_url，TerritoryChannel 审计 |
| 负载感知调度 | ✓ | PollService 检查 territory.has_capacity?，runtime_status 驱动的 remaining_slots 限制 |

### 与设计文档的偏差

| 偏差 | 原因 |
|------|------|
| Push Notification 分支为 mock（仅日志） | 按计划：Phase 8c 接入真实 APNs/FCM |
| Device Policy 在 Policy.effective_for 内合并而非独立调用 | 复用现有 Policy 合并架构，DevicePolicyV1.evaluate 仍可独立使用 |
| at_location scope 使用 `sanitize_sql_like` | 审计后增加的安全加固，设计文档未提及 |
| CommandsController#pending 使用 FOR UPDATE SKIP LOCKED | 审计后增加的并发安全，设计文档未提及 |
| Command approve/reject 使用 pessimistic lock (`lock!`) | 自审查发现的并发竞态风险，增加 lock! + 事务包裹 |
| WebSocket result 路径和 REST result 路径均计算 result_hash | 确保两条路径的幂等性行为一致 |
| broadcast_command 和 broadcast_directive_cancel 均有 rescue | 确保广播失败不阻断主流程（fire-and-forget 语义） |
| WebSocket result 路径增加终态 hash 一致性校验 + 无效 status 拒绝 | 协议审计发现 WebSocket 路径绕过了幂等性保护（见 Appendix B §B.1） |
| approve 动作使用 `update!` 持久化 `approved_by_user` | 代码审查发现 AASM 事件只持久化 state 列，approved_by_user_id 赋值在内存中丢失 |
| Command result 附件增加 `MAX_ATTACHMENT_BYTES`（10MB）限制 | 代码审查发现 base64 解码无大小约束，存在 DoS 风险 |
| Conduits V1 命令查询通过 `current_territory.commands` 作用域 | 代码审查发现全局 `find_by` 绕过 account 隔离（纵深防御） |
| WebSocket result 路径增加 `lock!` 悲观锁 + 终态检查移入事务 | 代码审查发现 TOCTOU 竞态：终态检查在事务外无锁保护 |
| Territory 不能 cancel 处于 `awaiting_approval` 的命令 | 代码审查发现设备端可绕过人工审批流程 |

### 未实现（按计划延后）

| 设计章节 | 延后到 | 原因 |
|---------|--------|------|
| §13 Phase 7d: PoC 模拟器 | Phase 8 | 协议已通过集成测试 + 真机验证证明可行 |
| Go Nexus AC 客户端 + Command 支持 | Phase 8a | 依赖协议稳定，AC 协议已文档化（§16.6） |
| iOS/Android App | Phase 8b | 依赖 PoC 验证 |
| Push Notification 真实接入 | Phase 8c | 依赖 Mobile App |
| Bridge SDK + HA 插件 | Phase 8d | 依赖 PoC 验证 |
| Agent 集成（device_command tool） | Phase 8e | 依赖 API 稳定 |
| 设备管理 Web UI | Phase 8f | 依赖模型稳定 |

### 测试覆盖

总计 323 个测试通过（含新增测试覆盖）：模型验证、AASM 状态转换、scope 查询、服务逻辑、E2E 全流程（mobile + bridge + legacy directive）、策略合并（CommandPolicyGate）、审批工作流（approve/reject + 竞态保护）、超时回收（含 awaiting_approval）、result_hash 幂等性、runtime_status 心跳、错误处理。

---

## Appendix B: 协议演进方向（Phase 9+）

> 本节基于对 Phase 7 实现的完整审计，记录已识别的演进方向。这些项目不阻塞 Phase 8（客户端构建），但应在协议进一步稳定后逐步落地。

### B.1 已修复：WebSocket result 路径幂等性对齐

**问题**：`TerritoryChannel#process_command_result` 在 Phase 7c 实现时未完全对齐 REST 端（`Conduits::V1::CommandsController#result`）的幂等性逻辑：

- 已终态时直接 `return`，不校验 `result_hash` 一致性（REST 端返回 409 Conflict）
- 未知 status（非 completed/failed）静默映射为 `fail!`（REST 端返回 422）

**修复（分两轮）**：

第一轮（幂等性对齐）：将 hash 计算提到终态检查之前；终态时做 hash 一致性校验并 warn 日志；无效 status 拒绝处理而非静默降级。

第二轮（代码审查加固）：
- 增加 `lock!` 悲观锁，终态检查移入事务内（修复 TOCTOU 竞态）
- 增加 `MAX_ATTACHMENT_BYTES`（10MB）限制，防止 base64 DoS

**修复位置**：`app/channels/conduits/territory_channel.rb` — `process_command_result` 方法。

**REST 与 WebSocket 行为对齐表**：

| 场景 | REST | WebSocket |
|------|------|-----------|
| 已终态 + hash 匹配 | 200 `duplicate: true` | 静默返回（锁内检查） |
| 已终态 + hash 不匹配 | 409 Conflict | warn 日志 + 返回（锁内检查） |
| 无效 status | 422 | warn 日志 + 返回（锁前检查） |
| 附件超过 10MB | 422 | warn 日志 + 回滚 |
| 正常 completed/failed | 状态转换 + audit | 状态转换 + audit |

> WebSocket 无法返回 HTTP 状态码，对等行为通过日志级别体现。

### B.2 演进项：Command-Directive 关联追踪（correlation_id）

**动机**：Agent 编排多步工作流（如"手机拍照 → 主机 OCR"）时，Command 和 Directive 之间没有关联机制，无法追踪因果链路。

**设计**：在 `conduits_commands` 和 `conduits_directives` 各增加可选 `correlation_id`（UUID）字段。

```ruby
# Migration
add_column :conduits_commands,   :correlation_id, :uuid
add_column :conduits_directives, :correlation_id, :uuid
add_index  :conduits_commands,   :correlation_id
add_index  :conduits_directives, :correlation_id
```

**使用方式**：

1. Agent 发起 Command（`camera.snap`）时生成 `correlation_id`
2. 拿到结果后创建 Directive（OCR 处理）时传入同一个 `correlation_id`
3. Mothership 不做任何编排逻辑，只存储和索引
4. AuditEvent 自然包含 `correlation_id`，可查询完整链路

**设计原则**：编排是 Agent 层的职责，Mothership 只提供关联查询的基础设施。不引入编排原语（DAG、workflow engine），避免在协议层过度设计。

**时间点**：Phase 9 或按需。

### B.3 演进项：Command 日志流（Log Streaming）

**动机**：Command 只返回最终 `result`，无中间输出。对于长时间运行的设备操作（如 `camera.record` 录制视频），调用者无法获知进度。

**当前状态**：`conduits_log_chunks` 表的 `directive_id NOT NULL`，仅支持 Directive 日志流。

**设计**：在 `conduits_log_chunks` 增加可选 `command_id`，`directive_id` 改为 nullable，加 CHECK 约束保证两者有且只有一个非空。

```ruby
# Migration
add_column    :conduits_log_chunks, :command_id, :uuid
add_foreign_key :conduits_log_chunks, :conduits_commands, column: :command_id
change_column_null :conduits_log_chunks, :directive_id, true
add_index :conduits_log_chunks, [:command_id, :stream, :seq],
          name: "index_conduits_log_chunks_command_uniqueness", unique: true,
          where: "command_id IS NOT NULL"

# CHECK constraint (exactly one owner)
execute <<-SQL
  ALTER TABLE conduits_log_chunks
  ADD CONSTRAINT chk_log_chunk_owner
  CHECK (num_nonnulls(directive_id, command_id) = 1);
SQL
```

**Nexus 侧**：复用 Directive 的 log_chunks 上报路径，target 从 `directive_id` 换为 `command_id`。

**延后理由**：Command 的典型操作（`camera.snap`、`sms.send`、`location.get`）都是秒级返回，不需要流式日志。仅当出现 `camera.record`、`audio.record` 等长时间操作场景时才需要。

**时间点**：Phase 9+ 按需。

### B.4 演进项：Bridge Entity 能力可信度

**动机**：BridgeEntity 的 capabilities 在心跳时由 Nexus 上报，Mothership 直接存储不做验证。恶意 Bridge Nexus 可以声称拥有任意能力。

**分阶段设计**：

#### B.4.1 运行时信誉追踪（Phase 9，推荐先做）

不验证声明本身，而是追踪每个 entity + capability 的执行成功率。

```ruby
# BridgeEntity 新增列
add_column :conduits_bridge_entities, :capability_stats, :jsonb, default: {}, null: false
```

数据结构：

```json
{
  "camera.snap":  { "total": 100, "success": 95, "last_failure_at": "2026-03-01T..." },
  "sms.send":     { "total": 10,  "success": 10 }
}
```

**行为**：
- 每次 Command 终态时更新对应 entity 的统计（`Command#complete!` → +success，`Command#fail!` → +failure）
- `CommandTargetResolver` 在多个候选 entity 中优先选择 `success_rate` 更高的
- 当 `success_rate < threshold`（可配置，默认 50%）时标记 entity 为不可用，从候选中移除
- 运维可通过 API 重置统计（手动恢复）

**优势**：零协议变更，纯 Mothership 侧实现，对 Nexus 完全透明。

#### B.4.2 能力探测协议（Phase 10+，可选）

定义 `capability.probe` 元命令，Mothership 周期性发送轻量探测验证实际能力。

```json
{
  "capability": "camera.snap",
  "params": { "__probe": true }
}
```

Nexus 收到 `__probe: true` 时返回能力状态而非实际执行（如检查摄像头权限是否授予、设备是否可达）。

**适用场景**：安全敏感操作（`iot.lock.control`、支付终端）。常规操作（拍照、GPS）信誉追踪已足够。

**时间点**：仅当有安全敏感设备接入需求时再设计详细协议。

### B.5 优先级总览

| 编号 | 演进项 | 复杂度 | 建议时间点 | 前置依赖 |
|------|--------|--------|-----------|---------|
| B.1 | WebSocket 幂等性对齐 | 小 | **已完成** | — |
| B.2 | correlation_id | 小 | Phase 9 | Agent 编排层设计 |
| B.3 | Command 日志流 | 中 | Phase 9+ 按需 | 长时间 Command 场景出现 |
| B.4.1 | Bridge Entity 信誉追踪 | 中 | Phase 9 | Bridge Nexus 接入（Phase 8d） |
| B.4.2 | 能力探测协议 | 大 | Phase 10+ | 安全敏感设备接入需求 |

真机集成测试在 10.0.0.114（aarch64）和 10.0.0.130（x86_64）上通过。现有 Go nexusd 守护进程向后兼容。
