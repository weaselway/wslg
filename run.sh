#!/usr/bin/env bash

set -xeuo pipefail

# remove symlink if it exists
if [ -L /tmp/.X11-unix  ] ; then
    sudo rm -f /tmp/.X11-unix
fi

if ! [ -e /usr/lib64/libedit.so.2 ] && [ -e /usr/lib64/libedit.so.0 ] ; then
    echo "Linking libedit to make intel gpu driver work"
    sudo ln -s /usr/lib64/libedit.so /usr/lib64/libedit.so.2
fi

# we want gpu acceleration
export GALLIUM_DRIVER=d3d12
export MESA_D3D12_DEFAULT_ADAPTER_NAME=${MESA_D3D12_DEFAULT_ADAPTER_NAME:-intel}

# vulkan is experimental with d3d12/dzn
export GSK_RENDERER=gl

export XDG_CURRENT_DESKTOP=GNOME
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

systemctl --user set-environment GSK_RENDERER="$GSK_RENDERER"
systemctl --user set-environment GALLIUM_DRIVER="$GALLIUM_DRIVER"
systemctl --user set-environment MESA_D3D12_DEFAULT_ADAPTER_NAME="$MESA_D3D12_DEFAULT_ADAPTER_NAME"
systemctl --user set-environment XDG_CURRENT_DESKTOP="$XDG_CURRENT_DESKTOP"

# A fixed vsock port; viewer.sh connects to the same one.
export MUTTER_RDP_VSOCK_PORT="${MUTTER_RDP_VSOCK_PORT:-3389}"

# The shared-memory share WSL creates as virtiofs tag "wslg" when a system
# distro is configured. Nothing mounts it for us, and without it mutter only
# sends its error frame. Only the mount/mkdir/chmod need root, so scope sudo to
# those; mutter runs as us.
SHARED_MEMORY_MOUNT_POINT="${SHARED_MEMORY_MOUNT_POINT:-/mnt/wslg-shared-memory}"
if ! mountpoint -q "${SHARED_MEMORY_MOUNT_POINT}"; then
  sudo mkdir -p "${SHARED_MEMORY_MOUNT_POINT}"
  sudo mount -t virtiofs -o dax wslg "${SHARED_MEMORY_MOUNT_POINT}"
  sudo chmod 0777 "${SHARED_MEMORY_MOUNT_POINT}"
fi
export WSL2_SHARED_MEMORY_MOUNT_POINT="${SHARED_MEMORY_MOUNT_POINT}"

exec gnome-shell \
  --headless \
  --virtual-monitor 1920x1080 \
  --wayland-display wayland-rdp \
  "$@"
