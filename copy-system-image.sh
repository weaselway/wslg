#!/bin/sh

# Copy a freshly built system image to Windows, by default into the Windows
# user's home directory:
#
#   ./copy-system-image.sh [destination directory]

set -ex

DEST="${1:-$(wslpath "$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')")}"

cp system_x64.vhd "${DEST}/system_x64-new.vhd"
