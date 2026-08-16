#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# RELEASE=1 builds -O3 with assertions and debug info off Each buildtype gets
# its own build dir: meson only configures once (see the okay marker below), so
# sharing one directory would silently keep whichever buildtype was configured
# first.
BUILD_TYPE=debugoptimized
NDEBUG=false
if [[ ${RELEASE:-} == "1" ]]; then
  BUILD_TYPE=release
  NDEBUG=true
fi
BUILD_DIR="${SCRIPT_DIR}/build/mutter-${BUILD_TYPE}"

# Install straight over the distro's mutter packages. gnome-shell hardcodes
# /usr/lib64/mutter-18 as a typelib search path (it wins over GI_TYPELIB_PATH)
# and GIRepository dlopens each shared library from the typelib's own directory,
# so a build installed anywhere else gets loaded *alongside* the packaged one:
# same SONAME, different inode, both mapped, duplicate GType registration, dead
# shell. One prefix is the only way to keep a single copy in the process.
#
# Fedora's layout, hence lib64. Restore the distro build with:
#   sudo dnf reinstall mutter
PREFIX=/usr
LIBDIR=lib64

if [ ! -f "${BUILD_DIR}/okay" ]; then
  meson setup "${BUILD_DIR}" "${SCRIPT_DIR}/vendor/mutter" \
    -Dprefix="${PREFIX}" \
    -Dlibdir="${LIBDIR}" \
    -Dbuildtype="${BUILD_TYPE}" \
    -Db_ndebug="${NDEBUG}" \
    -Dudev_dir="${PREFIX}/lib/udev" \
    -Drdp=enabled \
    -Dtests=disabled \
    -Ddocs=false \
    -Dprofiler=false \
    -Dcogl_tests=false \
    -Dclutter_tests=false \
    -Dmutter_tests=false \
    -Dinstalled_tests=false \
    -Dintrospection=true

  touch "${BUILD_DIR}/okay"
fi

echo "build.sh: ${BUILD_TYPE} build (b_ndebug=${NDEBUG}) in ${BUILD_DIR}"

# Compile as us, install as root: only the install step touches /usr.
meson compile -C "${BUILD_DIR}"
sudo meson install -C "${BUILD_DIR}" --no-rebuild 2>&1 | grep -v Installing
