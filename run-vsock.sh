#!/usr/bin/env bash

set -xeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${SCRIPT_DIR}/_install"

# we want gpu acceleration
export GALLIUM_DRIVER=d3d12
export MESA_D3D12_DEFAULT_ADAPTER_NAME=nvidia
export GSK_RENDERER=gl

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/mutter-xdg-runtime}"
mkdir -p "${XDG_RUNTIME_DIR}"

# mutter and its private libraries (libmutter-*, libfreerdp2, ...) are installed
# under this non-standard prefix and the binary carries no RPATH, so the loader
# needs LD_LIBRARY_PATH to find them at runtime. PATH/GSETTINGS_SCHEMA_DIR point
# at the same prefix so we run this build's mutter and its bundled schemas.
export LD_LIBRARY_PATH="${PREFIX}/lib:${PREFIX}/lib/mutter-18${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export PATH="${PREFIX}/bin:${PATH}"
export GSETTINGS_SCHEMA_DIR="${PREFIX}/share/glib-2.0/schemas"
export MUTTER_RDP="${MUTTER_RDP:-1}"
export G_MESSAGES_DEBUG="${G_MESSAGES_DEBUG:-all}"

# When running under WSLg, WSLGd (with WSLG_USE_MUTTER=1) publishes the RDP
# transport it reserved (and handed to msrdc) to this data-only env file. Source
# it to pick up MUTTER_RDP_VSOCK_PORT (the vsock port to bind) and, when shared
# memory is available, WSLG_SHARED_MEMORY_VIRTIO_TAG (the virtiofs tag to mount).
# If the file is absent we fall back to whatever transport env is already set
# (MUTTER_RDP_VSOCK_PORT / USE_VSOCK / MUTTER_RDP_PORT for TCP debugging).
MUTTER_RDP_ENV_FILE="${MUTTER_RDP_ENV_FILE:-/mnt/wslg/mutter-rdp.env}"
if [ -r "${MUTTER_RDP_ENV_FILE}" ]; then
  # shellcheck disable=SC1090
  . "${MUTTER_RDP_ENV_FILE}"
  export MUTTER_RDP_VSOCK_PORT
fi

# WSLGd mounts the shared-memory DAX share only in the system-distro mount
# namespace (/mnt/shared_memory), which is invisible here. If a virtiofs tag was
# published, mount the same VM-wide share ourselves at a user-distro path. Only
# the mount/mkdir/chmod need root, so scope sudo to those; mutter runs as us.
SHARED_MEMORY_MOUNT_POINT="${SHARED_MEMORY_MOUNT_POINT:-/mnt/wslg-shared-memory}"
if [ -n "${WSLG_SHARED_MEMORY_VIRTIO_TAG:-}" ]; then
  if ! mountpoint -q "${SHARED_MEMORY_MOUNT_POINT}"; then
    sudo mkdir -p "${SHARED_MEMORY_MOUNT_POINT}"
    sudo mount -t virtiofs -o dax "${WSLG_SHARED_MEMORY_VIRTIO_TAG}" "${SHARED_MEMORY_MOUNT_POINT}"
    sudo chmod 0777 "${SHARED_MEMORY_MOUNT_POINT}"
  fi
  export WSL2_SHARED_MEMORY_MOUNT_POINT="${SHARED_MEMORY_MOUNT_POINT}"
fi

exec "${PREFIX}/bin/mutter" \
  --headless \
  --virtual-monitor 1920x1080 \
  --wayland-display wayland-rdp \
  "$@"
