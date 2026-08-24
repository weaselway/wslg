#!/usr/bin/env sh

# No LD_PRELOAD and no --render-node-override: the dxgdrm module
# (kernel/dxgdrm) provides a real /dev/dri/renderD128 that answers
# drmGetVersion(), so Chromium's own drmGetDevices2() discovery finds it.
exec chromium-browser \
    --gtk-version=3 \
    --ozone-platform=wayland \
    --disable-features=Vulkan \
    "$@"
