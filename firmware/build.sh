#!/usr/bin/env bash
# Apply patches, build firmware for Pico 2 W, copy UF2 to Windows side.
# Run from WSL.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MPY_DIR="${MPY_DIR:-$HOME/micropython}"
BOARD="RPI_PICO2_W"

# 1. Apply our patches
"$HERE/apply.sh"

# 2. Build with a sanitized PATH so Windows picotool.exe can't leak in,
#    and force the build to fetch a matching picotool version.
echo "==> Building $BOARD"
cd "$MPY_DIR/ports/rp2"
PATH=/usr/local/bin:/usr/bin:/bin \
PICOTOOL_FORCE_FETCH_FROM_GIT=1 \
    make BOARD="$BOARD" submodules

PATH=/usr/local/bin:/usr/bin:/bin \
PICOTOOL_FORCE_FETCH_FROM_GIT=1 \
    make -j"$(nproc)" BOARD="$BOARD"

# 3. Copy UF2 to the Windows side for flashing
UF2_SRC="$MPY_DIR/ports/rp2/build-$BOARD/firmware.uf2"
UF2_DST="$HERE/firmware.uf2"
cp "$UF2_SRC" "$UF2_DST"

echo "==> Done"
echo "    UF2: $UF2_DST"
echo "    Flash: hold BOOTSEL, plug USB, drag UF2 onto RP2350 drive."
