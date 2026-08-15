#!/usr/bin/env bash
# Build the Microsoft FreeRDP fork (working branch, FreeRDP 2.4.0) into our
# install prefix. This matches the FreeRDP that WSLg's Dockerfile builds:
# WITH_SERVER + gfxredir server channel (the VAIL fast path), no client.
#
# Idempotent: skips the whole build if the marker file is already present.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/vendor/FreeRDP"
BUILD_DIR="${SCRIPT_DIR}/build/freerdp"
PREFIX="${SCRIPT_DIR}/_install"

if [ -f "${PREFIX}/lib/pkgconfig/freerdp2.pc" ]; then
  echo "FreeRDP already installed in ${PREFIX} (freerdp2.pc present); skipping."
  exit 0
fi

if [ ! -d "${SRC_DIR}/.git" ] && [ ! -f "${SRC_DIR}/CMakeLists.txt" ]; then
  echo "error: ${SRC_DIR} not found. Clone microsoft/FreeRDP-mirror (working branch) there first:" >&2
  echo "  git clone --depth 1 --branch working https://github.com/microsoft/FreeRDP-mirror.git vendor/FreeRDP" >&2
  exit 1
fi

cmake -G Ninja \
  -B "${BUILD_DIR}" \
  -S "${SRC_DIR}" \
  -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
  -DCMAKE_INSTALL_LIBDIR="${PREFIX}/lib" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DWITH_ICU=ON \
  -DWITH_SERVER=ON \
  -DWITH_CHANNEL_GFXREDIR=ON \
  -DWITH_CHANNEL_RDPAPPLIST=ON \
  -DWITH_CLIENT=OFF \
  -DWITH_CLIENT_COMMON=OFF \
  -DWITH_CLIENT_CHANNELS=OFF \
  -DWITH_CLIENT_INTERFACE=OFF \
  -DWITH_LIBSYSTEMD=OFF \
  -DWITH_WAYLAND=OFF \
  -DWITH_X11=OFF \
  -DWITH_PROXY=OFF \
  -DWITH_SHADOW=OFF \
  -DWITH_SAMPLE=OFF

ninja -C "${BUILD_DIR}" install
echo "FreeRDP installed into ${PREFIX}"
