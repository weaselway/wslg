#!/usr/bin/env bash
# Launch an application inside the running mutter compositor (started via
# ./run-vsock.sh). Wayland-native apps connect to the "wayland-rdp" display;
# X11 apps go through the Xwayland instance mutter spawns (run-vsock.sh must NOT
# pass --no-x11 for that).
#
# Usage:
#   ./exec.sh foot                 # Wayland app
#   ./exec.sh xterm                # X11 app (auto-detects Xwayland DISPLAY)

set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <application> [args...]" >&2
  exit 1
fi

# Match run-vsock.sh: same XDG_RUNTIME_DIR so we find its sockets.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/mutter-xdg-runtime}"

# mutter's Wayland socket. Hardcoded to match run-vsock.sh --wayland-display.
export WAYLAND_DISPLAY=wayland-rdp

WAYLAND_SOCKET="${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}"
if [ ! -S "${WAYLAND_SOCKET}" ]; then
  echo "error: Wayland socket ${WAYLAND_SOCKET} not found." >&2
  echo "       Is mutter running? Start it with ./run-vsock.sh first." >&2
  exit 1
fi

# Discover the DISPLAY of the Xwayland instance mutter spawned. mutter picks the
# first free display number, so scan the X11 sockets and probe each until one
# accepts a connection over our Wayland session.
find_display() {
  local dir=/tmp/.X11-unix sock n
  [ -d "${dir}" ] || return 1
  for sock in "${dir}"/X*; do
    [ -e "${sock}" ] || continue
    n="${sock##*/X}"
    case "${n}" in
      ''|*[!0-9]*) continue ;;
    esac
    echo ":${n}"
    return 0
  done
  return 1
}

if DISPLAY_CANDIDATE="$(find_display)"; then
  export DISPLAY="${DISPLAY_CANDIDATE}"

  # Xwayland requires the auth cookie mutter generated. mutter writes it to
  # ${XDG_RUNTIME_DIR}/.mutter-Xwaylandauth.XXXXXX and passes it to its own
  # children via XAUTHORITY; since we launch from a separate shell we must point
  # at it ourselves, otherwise X11 clients get
  # "authentication required but no authorization protocols specified" or
  # "Invalid MIT-MAGIC-COOKIE-1 key" (stale cookie from a previous run).
  #
  # Read the exact -auth path from the running Xwayland's command line so we
  # never pick a stale file; fall back to the newest matching file.
  if [ -z "${XAUTHORITY:-}" ]; then
    auth=""
    for pid_cmdline in /proc/[0-9]*/cmdline; do
      # Only consider Xwayland processes.
      pid_comm="${pid_cmdline%/cmdline}/comm"
      [ -r "${pid_comm}" ] || continue
      read -r comm < "${pid_comm}" || continue
      [ "${comm}" = "Xwayland" ] || continue
      # cmdline is NUL-separated; grab the arg after "-auth".
      prev=""
      while IFS= read -r -d '' arg; do
        if [ "${prev}" = "-auth" ]; then
          auth="${arg}"
          break
        fi
        prev="${arg}"
      done < "${pid_cmdline}"
      [ -n "${auth}" ] && break
    done

    if [ -z "${auth}" ]; then
      # Fall back to the most recently modified cookie file.
      for f in "${XDG_RUNTIME_DIR}"/.mutter-Xwaylandauth.*; do
        [ -f "${f}" ] || continue
        if [ -z "${auth}" ] || [ "${f}" -nt "${auth}" ]; then
          auth="${f}"
        fi
      done
    fi

    [ -n "${auth}" ] && export XAUTHORITY="${auth}"
  fi
fi

export GALLIUM_DRIVER=d3d12
export MESA_D3D12_DEFAULT_ADAPTER_NAME=nvidia

# Prefer the Wayland backends by default; toolkits that can't will still fall
# back to Xwayland via DISPLAY/XAUTHORITY set above.
export GDK_BACKEND="${GDK_BACKEND:-wayland}"
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland}"
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-wayland}"
export CLUTTER_BACKEND="${CLUTTER_BACKEND:-wayland}"
export MOZ_ENABLE_WAYLAND="${MOZ_ENABLE_WAYLAND:-1}"
export XDG_SESSION_TYPE="${XDG_SESSION_TYPE:-wayland}"
export _JAVA_AWT_WM_NONREPARENTING="${_JAVA_AWT_WM_NONREPARENTING:-1}"

echo "exec.sh: WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>} DISPLAY=${DISPLAY:-<unset>} XAUTHORITY=${XAUTHORITY:-<unset>}" >&2
exec "$@"
