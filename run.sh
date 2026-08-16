#!/usr/bin/env bash

set -xeuo pipefail

# build.sh installs mutter straight over the distro packages in /usr, so there is
# exactly one libmutter-18 / libmutter-cogl-18 / ... on the system and nothing
# here needs LD_LIBRARY_PATH, GI_TYPELIB_PATH, PATH or GSETTINGS_SCHEMA_DIR
# overrides. Two copies of those libraries cannot coexist in one process: they
# share a SONAME but not an inode, so ld.so maps both, and the second one to run
# its constructors fails to register its GTypes (CoglColor et al), which took
# gnome-shell down at startup.

# we want gpu acceleration
export GALLIUM_DRIVER=d3d12
export MESA_D3D12_DEFAULT_ADAPTER_NAME=${MESA_D3D12_DEFAULT_ADAPTER_NAME:-nvidia}

# vulkan is not supported with d3d12 afaik
export GSK_RENDERER=gl

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/mutter-xdg-runtime}"
mkdir -p "${XDG_RUNTIME_DIR}"

export MUTTER_RDP="${MUTTER_RDP:-1}"

# Start Xwayland eagerly instead of on first X11 connection. Launched from an
# interactive shell we'd otherwise get the ON_DEMAND policy, where mutter owns
# the X sockets and spawns Xwayland from the main loop -- and gnome-shell's
# startup JS blocks that same main loop on a synchronous xcb_connect() to it
# (Gvc.MixerControl -> PulseAudio -> X11 root window probe). See the comment in
# meta_context_main_get_x11_display_policy(); this env var is our patch.
export MUTTER_X11_MANDATORY=1
export G_MESSAGES_DEBUG="${G_MESSAGES_DEBUG:-all}"


if [[ ${USE_TCP:-} != "1" ]] ; then
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


# gnome-shell links against libmutter, so it picks up our backend just by being
# the installed one; it takes the same MetaContext options as the mutter binary.
# Set BARE_MUTTER=1 to run mutter alone (no shell UI) for isolating backend bugs.
if [[ ${BARE_MUTTER:-} == "1" ]]; then
  exec mutter \
    --headless \
    --virtual-monitor 1920x1080 \
    --wayland-display wayland-rdp \
    "$@"
fi

gnome-shell \
  --headless \
  --virtual-monitor 1920x1080 \
  --wayland-display wayland-rdp \
  "$@" 2>&1 | tee gnome.log
