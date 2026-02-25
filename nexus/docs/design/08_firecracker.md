## 8. Firecracker microVM 驱动（Phase 3）

> 本节描述可选的 Firecracker microVM 驱动，作为 bubblewrap namespace 隔离的硬件虚拟化升级。
> 通过 `untrusted_driver: "firecracker"` 配置项启用。

### 8.1 动机

bubblewrap 通过 Linux namespace 提供进程级隔离（mount/network/PID/user），轻量且无需 KVM。但 namespace 隔离与宿主共享同一个内核——一旦内核存在可利用漏洞，攻击者可从沙箱逃逸到宿主。

Firecracker microVM 通过 KVM 硬件虚拟化提供独立的 guest 内核，隔离边界从"同一内核的 namespace"升级为"独立内核 + 独立地址空间"。适用于：

- 多租户共享环境（不同用户的 directive 运行在同一物理机上）
- 最高安全要求的不可信代码执行
- 需要与宿主内核完全隔离的场景

### 8.2 架构

#### 8.2.1 三盘模型

每次 directive 执行启动一个短暂的 Firecracker microVM，挂载三个 block 设备：

| 设备 | 盘 ID | 模式 | 内容 |
|------|-------|------|------|
| /dev/vda | rootfs | 只读 | Ubuntu 24.04 minimal + `/sbin/nexus-init` |
| /dev/vdb | cmd | 只读 | 小型 ext4，包含 `/run.sh` wrapper 脚本 |
| /dev/vdc | workspace | 读写 | facility 目录转换为 ext4 镜像 |

rootfs 只读意味着每次运行无需复制基础镜像——所有可变状态在 tmpfs（/tmp, /run）或 workspace 盘上。

#### 8.2.2 网络：Vsock + Egress Proxy

VM **不挂载任何网络接口**（无 eth0、无 TAP），仅有一个 vsock 设备。所有出站流量通过 vsock → egress proxy 路径，实现硬网络隔离：

```
Guest 进程 → TCP localhost:9080 → socat → vsock CID=2:9080
  → Firecracker → UDS <vsock_path>_9080
  → vsock bridge → egress proxy UDS → Egress Proxy → 互联网
```

**Host 侧**：

1. egress proxy 监听 UDS（与 bwrap 相同的 `StartForDirective`）
2. vsock bridge（Go 实现）监听 `<vsock_path>_9080`，将每个连接桥接到 egress proxy UDS

**Guest 侧**（在 `nexus-init` 中）：

1. socat 将 TCP localhost:9080 桥接到 vsock CID=2:9080
2. wrapper 脚本设置 `HTTP_PROXY=http://127.0.0.1:9080`

**优势**：

- 无需 TAP 设备创建（无需 root/CAP_NET_ADMIN）
- 无需 iptables/nftables 规则
- 比 bwrap 的 `--unshare-net` 更强：VM 内无 loopback 可滥用
- egress proxy 代码完全不变——vsock bridge 是透明传输层

### 8.3 Init 脚本生命周期

`/sbin/nexus-init`（烘焙在基础 rootfs 镜像中）：

```sh
#!/bin/sh
# 1. 挂载基础文件系统
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /run

# 2. 挂载 command 和 workspace 盘（目录预建在 rootfs 中）
mount -t ext4 -o ro /dev/vdb /mnt/cmd
mount -t ext4 /dev/vdc /workspace

# 3. 启动 vsock-to-TCP 桥接（egress proxy 通道）
socat TCP-LISTEN:9080,fork,reuseaddr VSOCK-CONNECT:2:9080 &
SOCAT_PID=$!
trap "kill $SOCAT_PID 2>/dev/null" EXIT

# 4. 执行用户命令
sh /mnt/cmd/run.sh
EXIT_CODE=$?

# 5. 报告退出码并关机
echo "NEXUS_EXIT_CODE=${EXIT_CODE}"
sync
umount /workspace 2>/dev/null
exec reboot -f
```

> **关机方式**：使用 `reboot -f` 而非 `poweroff -f`。
> 在 x86_64 + `pci=off` 环境下，`poweroff -f` 仅 halt CPU 而不触发 KVM 退出事件
> （ACPI 关机需要 PCI）。`reboot -f` 触发 triple fault，Firecracker 检测到
> `KVM_EXIT_SHUTDOWN` 后正常退出。该方式在 aarch64（PSCI）和 x86_64 上均可正常工作。
>
> **注意**：rootfs 镜像中需预建 `/mnt/cmd` 和 `/workspace` 目录，因为 rootfs 以只读挂载。

### 8.4 配置

VM 资产（内核、rootfs 镜像）和 Firecracker 二进制文件统一存放在 `~/.cybros/` 目录下：

```
~/.cybros/
├── bin/
│   └── firecracker          # Firecracker 二进制
├── vmlinux                  # guest 内核
└── rootfs.ext4              # 基础 rootfs 镜像
```

> **目录选择**：选用 `~/.cybros` 而非 `~/.nexus`，因为 nexus-xyz（区块链证明器 CLI）已占用 `~/.nexus` 目录。

```yaml
# 选择 untrusted profile 使用的驱动
untrusted_driver: "firecracker"  # "bwrap"（默认）或 "firecracker"

firecracker:
  firecracker_path: "~/.cybros/bin/firecracker"  # 二进制路径
  kernel_path: "~/.cybros/vmlinux"               # guest 内核
  rootfs_image_path: "~/.cybros/rootfs.ext4"     # 基础 rootfs 镜像
  vcpus: 2                              # 虚拟 CPU 数
  mem_size_mib: 512                     # 内存大小（MiB）
  workspace_size_mib: 2048              # workspace 镜像最大大小（MiB）
  proxy_socket_dir: ""                  # 代理 UDS 目录（同 bwrap）
```

当 `untrusted_driver` 为空或 `"bwrap"` 时，行为与现有完全一致。

### 8.5 安全属性对比

| 属性 | bubblewrap | Firecracker |
|------|-----------|-------------|
| 内核隔离 | 共享宿主内核 | 独立 guest 内核 |
| 网络隔离 | namespace (`--unshare-net`) | 无网络接口，仅 vsock |
| 文件系统 | bind mount + tmpfs | 独立 block 设备 |
| PID 隔离 | namespace (`--unshare-pid`) | 完全独立进程空间 |
| 内存隔离 | 共享地址空间（cgroup 限制） | 硬件 EPT/stage-2 页表隔离 |
| 逃逸难度 | 内核漏洞可逃逸 | 需同时突破 guest 内核 + KVM |
| 启动延迟 | < 50ms | ~125ms（含内核引导） |
| 无需 root | 是（user namespace） | 是（需 kvm 组） |
| 依赖 | bubblewrap + socat | firecracker + e2fsprogs + socat |

### 8.6 Doctor 检查

当 `untrusted_driver: "firecracker"` 时，`nexusd -doctor` 额外检查：

| 检查项 | 说明 | 失败级别 |
|--------|------|----------|
| `kvm` | `/dev/kvm` 存在且可读写 | fail |
| `firecracker` | 二进制可用 + 版本 | fail |
| `mke2fs` | e2fsprogs 工具（创建 ext4 镜像） | fail |
| `fuse2fs` | FUSE ext4 挂载（workspace 提取） | warn |
| `vm_assets` | kernel_path + rootfs_image_path 文件存在 | fail |
| `firecracker_functional` | 启动最小 VM 并验证退出码 | fail |

### 8.7 平台验证

#### aarch64（NVIDIA Jetson / Tegra）

已在 NVIDIA Jetson (Tegra) aarch64 上验证（10.0.0.114，Ubuntu 24.04）：

- 内核 6.8.12-tegra，`CONFIG_KVM=y`（内核内置）
- Firecracker v1.14.1 aarch64 二进制正常
- microVM ~70ms 引导
- MMIO warning `MissingAddressRange` 为已知良性告警
- 49/49 集成测试通过（16.2s）

#### x86_64（Bazzite / Fedora Atomic 43）

已在 AMD Ryzen AI 9 HX 370 上验证（10.0.0.130，Bazzite — Fedora Atomic 43 变体）：

- 内核 6.12.8-204.bazzite.fc41.x86_64，KVM 可用（`/dev/kvm` crw-rw-rw-）
- Firecracker v1.14.1 x86_64 二进制正常
- **不可变操作系统**：无法 `dnf install`，所有宿主工具需直接下载二进制
- e2fsprogs（mke2fs、fuse2fs、fusermount）已预装
- Guest 内核使用 Firecracker quickstart `vmlinux-5.10.245`
- 49/49 集成测试通过（21.4s）

> **x86_64 关机注意事项**：x86_64 + `pci=off` 环境下必须使用 `reboot -f`（参见 8.3 节说明）。

#### 通用要求

用户需将自己加入 kvm 组：`sudo usermod -aG kvm $USER`

### 8.8 依赖

| 工具 | 用途 | 安装 |
|------|------|------|
| `firecracker` | microVM 管理器 | 从 [GitHub releases](https://github.com/firecracker-microvm/firecracker/releases) 下载到 `~/.cybros/bin/` |
| `mke2fs` | 创建 ext4 镜像（无需 root） | `apt install e2fsprogs`（通常预装） |
| `fuse2fs` | 无 root 挂载 ext4（workspace 提取） | `apt install fuse2fs`（e2fsprogs 的一部分） |
| `fusermount` | 卸载 FUSE 文件系统 | `apt install fuse3` |
| `socat` | guest 内 vsock-TCP 桥接 | 烘焙在 rootfs 镜像中（宿主无需安装） |

> **不可变操作系统**（如 Bazzite/Fedora Atomic、NixOS）：`firecracker` 直接下载二进制到
> `~/.cybros/bin/`，无需包管理器。`mke2fs`/`fuse2fs`/`fusermount` 通常由基础系统预装的
> e2fsprogs 提供。`socat` 仅在 guest rootfs 镜像内使用，宿主无需安装。
>
> Go 编译器仅构建时需要，生产分发不需要。

### 8.9 Future: Phase 4 增强

- virtio-net + TAP + nftables 硬 egress（替代 vsock，支持更复杂网络策略）
- vsock agent daemon（替代 init + command 盘方式，支持交互式会话）
- cgroup v2 资源配额（CPU/memory/IO 限制）
- Jailer 集成（每个 VM 独立 chroot + cgroup）
- VM 热池（预启动 VM 降低延迟）
