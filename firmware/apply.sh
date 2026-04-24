#!/usr/bin/env bash
# Reset the MicroPython tree and apply all patches/hooks in firmware/patches/.
# Patch files (*.patch) are applied with `git apply`.
# Shell hooks (*.sh) are executed — useful for adding new files.
# Items are processed in filename order, so prefix with NNNN- to control order.

set -euo pipefail

MPY_DIR="${MPY_DIR:-$HOME/micropython}"
PATCH_DIR="$(cd "$(dirname "$0")" && pwd)/patches"

echo "==> Resetting $MPY_DIR to clean state"
cd "$MPY_DIR"
git checkout . >/dev/null
# Keep build-* dirs and lib/ so we don't re-fetch submodules / rebuild from scratch
git clean -fd -e 'build-*' -e 'lib/' >/dev/null

shopt -s nullglob
items=("$PATCH_DIR"/*.patch "$PATCH_DIR"/*.sh)
# Filter out non-existent glob expansions and sort
items=($(printf '%s\n' "${items[@]}" | sort))

if [ ${#items[@]} -eq 0 ]; then
    echo "==> No patches/hooks — tree left vanilla"
    exit 0
fi

echo "==> Applying patches/hooks from $PATCH_DIR"
for p in "${items[@]}"; do
    case "$p" in
        *.patch)
            echo "    [patch] $(basename "$p")"
            git apply --whitespace=nowarn "$p"
            ;;
        *.sh)
            echo "    [hook]  $(basename "$p")"
            MPY_DIR="$MPY_DIR" bash "$p"
            ;;
    esac
done

echo "==> Done"
