#!/bin/sh

source /mnt/wslg/mutter-rdp.env

./sdl-freerdp.exe /u:dummy /d:dummy /p:dummy \
    /v:vsock://$WSLG_VM_ID:1024 \
    /wslgsharedmemorypath:"$WSLG_SHARED_MEMORY_OB_DIRECTORY" \
    /cert:ignore \
    /dynamic-resolution \
    /w:1280 \
    /kbd:layout:German \
    /log-level:warn
