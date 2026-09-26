#!/usr/bin/env bash

# Development shortcut: connect sdl-freerdp.exe from the current directory to
# the session. weaselway's start-viewer.sh is the maintained version.

set -eu -o pipefail

# Same port as run.sh; the share's NT path is named after the VM.
PORT="${MUTTER_RDP_VSOCK_PORT:-3389}"
VM_ID="$(exec -a wslinfo /init --vm-id -n)"

./sdl-freerdp.exe /u:dummy /d:dummy /p:dummy \
    /v:vsock://"$VM_ID":"$PORT" \
    /wslgsharedmemorypath:"WSL\\${VM_ID^^}\\wslg" \
    /cert:ignore \
    /dynamic-resolution \
    /w:1280 \
    /kbd:layout:German \
    /log-level:warn \
    "$@"
