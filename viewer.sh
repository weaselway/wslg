#!/usr/bin/env bash

# Development shortcut: connect sdl-freerdp.exe from the current directory to
# the session. weaselway's start-viewer.sh is the maintained version.

set -eu -o pipefail

source /mnt/wslg/mutter-rdp.env

SHARED_MEMORY_ARGS=()
if [ -n "${WSLG_SHARED_MEMORY_OB_DIRECTORY:-}" ]; then
    SHARED_MEMORY_ARGS=(/wslgsharedmemorypath:"$WSLG_SHARED_MEMORY_OB_DIRECTORY")
fi

./sdl-freerdp.exe /u:dummy /d:dummy /p:dummy \
    /v:vsock://"$WSLG_VM_ID":"$MUTTER_RDP_VSOCK_PORT" \
    "${SHARED_MEMORY_ARGS[@]}" \
    /cert:ignore \
    /dynamic-resolution \
    /w:1280 \
    /kbd:layout:German \
    /log-level:warn \
    "$@"
