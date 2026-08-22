#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build/mesa"
PREFIX=/usr

export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"

if [ ! -f "${BUILD_DIR}/okay" ]; then
  meson setup --reconfigure "${BUILD_DIR}" "${SCRIPT_DIR}/vendor/mesa" \
    --buildtype=debug \
    -Dprefix="${PREFIX}" \
    -Dlibdir=lib64 \
    -Dglvnd=enabled \
    -Dplatforms=x11,wayland \
    -Degl-native-platform=wayland \
    -Dgallium-drivers=softpipe,d3d12 \
    -Dvulkan-drivers=swrast,microsoft-experimental \
    -Dgallium-d3d12-graphics=enabled \
    -Dgallium-d3d12-video=enabled


  touch "${BUILD_DIR}/okay"
fi

sudo meson install -C "${BUILD_DIR}"
