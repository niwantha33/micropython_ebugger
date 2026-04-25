#!/usr/bin/env bash
# Apply every numbered patch in this directory in order.
#
# Usage:
#   export MPY_DIR=$HOME/micropython   # default if unset
#   bash apply_all.sh
#
# Idempotent: each patch script checks before re-applying.

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
export MPY_DIR="${MPY_DIR:-$HOME/micropython}"

if [ ! -d "$MPY_DIR/py" ]; then
    echo "ERROR: \$MPY_DIR=$MPY_DIR does not look like a MicroPython source tree."
    echo "       Set MPY_DIR or clone first:"
    echo "         git clone --recursive https://github.com/micropython/micropython.git \$HOME/micropython"
    exit 1
fi

echo "Applying patches to $MPY_DIR ..."
for p in "$DIR"/0*.sh; do
    name="$(basename "$p")"
    echo ">> $name"
    bash "$p"
done
echo "All patches applied."
echo
echo "Now build:"
echo "  cd \$MPY_DIR/ports/rp2 && make BOARD=RPI_PICO2_W -j4"
echo "  Output: build-RPI_PICO2_W/firmware.uf2"
