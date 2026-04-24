#!/usr/bin/env bash
# Patch 0014 — busy-wait must service USB.
#
# mp_hal_delay_us() does not poll TinyUSB, so while the target thread is
# paused in mp_dbg_hook's busy-wait, USB RX stops and commands from the
# host queue up at OS level, never reaching the pump. Using mp_hal_delay_ms
# ensures the USB task is polled every ms.

set -euo pipefail
MPY_DIR="${MPY_DIR:-$HOME/micropython}"

python3 - <<'PY'
import os
p = os.path.expanduser(os.environ.get("MPY_DIR", "~/micropython")) + "/py/moddbg.c"
s = open(p).read()
new = s.replace("mp_hal_delay_us(200)", "mp_hal_delay_ms(1)")
if new == s:
    raise SystemExit("FAIL: no mp_hal_delay_us(200) found")
open(p, "w").write(new)
PY

grep -q 'mp_hal_delay_ms(1)' "$MPY_DIR/py/moddbg.c" || { echo "FAIL"; exit 1; }
echo "    0014 applied OK"
