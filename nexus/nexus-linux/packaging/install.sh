#!/usr/bin/env bash
set -euo pipefail

# MVP install script skeleton.
#
# TODO:
# - Verify downloaded nexusd binary (sha256/signature)
# - Doctor check (/dev/kvm, cgroups v2, nftables, firecracker/jailer, etc.)
# - mTLS enroll flow (write certs to secure path)

NEXUS_USER="cybros-nexus"
INSTALL_BIN_DIR="/usr/local/bin"
STATE_DIR="/var/lib/cybros-nexus"
CONFIG_DIR="/etc/cybros-nexus"

echo "[1/5] Ensure user ${NEXUS_USER}"
if ! id "${NEXUS_USER}" >/dev/null 2>&1; then
  useradd --system --home "${STATE_DIR}" --shell /usr/sbin/nologin "${NEXUS_USER}"
fi

echo "[2/5] Create dirs"
mkdir -p "${STATE_DIR}" "${CONFIG_DIR}"
chown -R "${NEXUS_USER}:${NEXUS_USER}" "${STATE_DIR}"
chmod 0755 "${STATE_DIR}"

echo "[3/5] Install binaries (replace with your actual paths)"
# cp ./dist/nexusd-linux-amd64 "${INSTALL_BIN_DIR}/nexusd"
# cp ./dist/nexus-helper-linux-amd64 "${INSTALL_BIN_DIR}/nexus-helper"

echo "[4/5] Install config (example)"
if [ ! -f "${CONFIG_DIR}/config.yaml" ]; then
  cp ./nexus-linux/config.example.yaml "${CONFIG_DIR}/config.yaml"
fi

echo "[5/5] Install systemd units"
cp ./nexus-linux/packaging/systemd/nexusd.service /etc/systemd/system/cybros-nexusd.service
systemctl daemon-reload
systemctl enable --now cybros-nexusd.service

echo "Done."
