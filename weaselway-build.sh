#!/usr/bin/env bash
# Builds WSLGd and rdpapplist, without installing anything. See WEASELWAY.md.
# Runs itself inside `nix develop` (clang, as in the Dockerfile) if not already there.
#
#   ./weaselway-build.sh                      configure on first run, then compile
#   BUILDTYPE=release ./weaselway-build.sh    (only applies when configuring)
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${IN_NIX_SHELL:-}" ]; then
    exec nix develop "${SOURCE_DIR}" -c "$0" "$@"
fi

BUILDTYPE="${BUILDTYPE:-debug}"

for project in WSLGd rdpapplist; do
    build_dir="${SOURCE_DIR}/build/${project}"
    if [ ! -f "${build_dir}/build.ninja" ]; then
        meson setup "${build_dir}" "${SOURCE_DIR}/${project}" --buildtype="${BUILDTYPE}"
    fi
    meson compile -C "${build_dir}"
done
