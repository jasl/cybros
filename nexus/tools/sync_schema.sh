#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SRC_NET="${ROOT_DIR}/docs/protocol/directivespec_capabilities_net.schema.v1.json"
DST_NET="${ROOT_DIR}/protocol/schema/directivespec_capabilities_net.schema.v1.json"

SRC_FS="${ROOT_DIR}/docs/protocol/directivespec_capabilities_fs.schema.v1.json"
DST_FS="${ROOT_DIR}/protocol/schema/directivespec_capabilities_fs.schema.v1.json"

mkdir -p "$(dirname "${DST_NET}")"
cp -f "${SRC_NET}" "${DST_NET}"
cp -f "${SRC_FS}" "${DST_FS}"

echo "Synced schema:"
echo "  ${SRC_NET}"
echo "  -> ${DST_NET}"
echo "  ${SRC_FS}"
echo "  -> ${DST_FS}"
