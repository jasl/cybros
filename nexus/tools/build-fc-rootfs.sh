#!/usr/bin/env bash
#
# build-fc-rootfs.sh — Build the base Firecracker rootfs image for Nexus.
#
# Creates an ext4 image containing Ubuntu 24.04 minimal + /sbin/nexus-init.
# The guest kernel is NOT included; download it separately from the
# Firecracker quickstart guide or build from source.
#
# Prerequisites: mke2fs (e2fsprogs), wget/curl, tar, xz
# No root required (uses mke2fs -d).
#
# Usage:
#   bash tools/build-fc-rootfs.sh [--arch aarch64|x86_64] [--output <path>]
#
set -euo pipefail

ARCH="${1:-$(uname -m)}"
OUTPUT=""
SIZE_MIB=512

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --arch)   ARCH="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --size)   SIZE_MIB="$2"; shift 2 ;;
    *)        shift ;;
  esac
done

case "$ARCH" in
  aarch64|arm64) ARCH="arm64"; UBUNTU_ARCH="arm64" ;;
  x86_64|amd64)  ARCH="amd64"; UBUNTU_ARCH="amd64" ;;
  *)
    echo "ERROR: unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

if [ -z "$OUTPUT" ]; then
  OUTPUT="firecracker-rootfs-${ARCH}.ext4"
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

ROOTFS_DIR="$WORK_DIR/rootfs"
mkdir -p "$ROOTFS_DIR"

echo "==> Downloading Ubuntu 24.04 minimal cloud image ($UBUNTU_ARCH)..."
UBUNTU_URL="https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-${UBUNTU_ARCH}-root.tar.xz"
TARBALL="$WORK_DIR/rootfs.tar.xz"

if command -v wget >/dev/null 2>&1; then
  wget -q -O "$TARBALL" "$UBUNTU_URL"
elif command -v curl >/dev/null 2>&1; then
  curl -sL -o "$TARBALL" "$UBUNTU_URL"
else
  echo "ERROR: wget or curl required" >&2
  exit 1
fi

echo "==> Extracting rootfs..."
tar -xJf "$TARBALL" -C "$ROOTFS_DIR"

echo "==> Installing /sbin/nexus-init..."
cat > "$ROOTFS_DIR/sbin/nexus-init" << 'INIT_EOF'
#!/bin/sh
# nexus-init: Firecracker guest init script for Nexus directives.
# Mounted drives:
#   /dev/vda — rootfs (this filesystem, read-only)
#   /dev/vdb — command image (read-only, contains /run.sh)
#   /dev/vdc — workspace image (read-write)

mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /run

mkdir -p /mnt/cmd /workspace
mount -t ext4 -o ro /dev/vdb /mnt/cmd
mount -t ext4 /dev/vdc /workspace

# Start vsock-to-TCP bridge for egress proxy.
# Guest CID=3, host CID=2. Port 9080 matches the egress proxy convention.
socat TCP-LISTEN:9080,fork,reuseaddr VSOCK-CONNECT:2:9080 &
SOCAT_PID=$!
trap "kill $SOCAT_PID 2>/dev/null" EXIT

# Brief pause for socat to start listening.
sleep 0.1

# Execute the command wrapper.
sh /mnt/cmd/run.sh
EXIT_CODE=$?

# Report exit code on serial console (parsed by host-side driver).
echo "NEXUS_EXIT_CODE=${EXIT_CODE}"

# Sync and unmount workspace to ensure all writes are flushed.
sync
umount /workspace 2>/dev/null || true

# Shut down the VM via reboot -f (NOT poweroff -f).
# On x86_64 + pci=off, poweroff -f only halts the CPU without triggering
# a KVM exit event (ACPI shutdown requires PCI). reboot -f triggers a
# triple fault that Firecracker detects as KVM_EXIT_SHUTDOWN.
# Works on both aarch64 (PSCI) and x86_64.
exec reboot -f
INIT_EOF
chmod 755 "$ROOTFS_DIR/sbin/nexus-init"

echo "==> Verifying socat is available in rootfs..."
if [ ! -f "$ROOTFS_DIR/usr/bin/socat" ] && [ ! -f "$ROOTFS_DIR/bin/socat" ]; then
  echo "ERROR: socat not found in rootfs." >&2
  echo "       socat is required for the vsock-to-TCP bridge (egress proxy)." >&2
  echo "       Without it, the guest VM will have no network connectivity." >&2
  echo "       For cloud images, you may need to chroot and apt install socat," >&2
  echo "       or use a pre-built image that includes socat." >&2
  exit 1
fi

echo "==> Creating ext4 image (${SIZE_MIB} MiB)..."
mke2fs -t ext4 -F -d "$ROOTFS_DIR" "$OUTPUT" "${SIZE_MIB}M"

echo "==> Computing SHA256..."
SHA256=$(sha256sum "$OUTPUT" | cut -d' ' -f1)

echo ""
echo "=== Build complete ==="
echo "  Image:  $OUTPUT"
echo "  Size:   ${SIZE_MIB} MiB"
echo "  SHA256: $SHA256"
echo ""
echo "Next steps:"
echo "  1. Download a guest kernel from Firecracker quickstart:"
echo "     https://github.com/firecracker-microvm/firecracker/blob/main/docs/getting-started.md"
echo "  2. Place both files on the host:"
echo "     sudo mkdir -p /opt/nexus"
echo "     sudo mv $OUTPUT /opt/nexus/rootfs.ext4"
echo "     sudo mv vmlinux /opt/nexus/vmlinux"
echo "  3. Configure nexusd:"
echo "     untrusted_driver: firecracker"
echo "     firecracker:"
echo "       kernel_path: /opt/nexus/vmlinux"
echo "       rootfs_image_path: /opt/nexus/rootfs.ext4"
