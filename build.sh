#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build/mutter"
PREFIX="${SCRIPT_DIR}/_install"

# Always build/link mutter's RDP backend against the Microsoft FreeRDP fork we
# install into ${PREFIX} (never nixpkgs' freerdp).
"${SCRIPT_DIR}/build-freerdp.sh"

export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"

if [ ! -f "${BUILD_DIR}/okay" ]; then
  meson setup "${BUILD_DIR}" "${SCRIPT_DIR}/vendor/mutter" \
    -Dprefix="${PREFIX}" \
    -Dlibdir=lib \
    -Dbuildtype=debugoptimized \
    -Db_ndebug=true \
    -Dudev_dir="${PREFIX}/lib/udev" \
    -Drdp=enabled \
    -Dtests=disabled \
    -Ddocs=false \
    -Dprofiler=false \
    -Dcogl_tests=false \
    -Dclutter_tests=false \
    -Dmutter_tests=false \
    -Dinstalled_tests=false \
    -Dintrospection=false

  touch "${BUILD_DIR}/okay"
fi

meson install -C "${BUILD_DIR}"
