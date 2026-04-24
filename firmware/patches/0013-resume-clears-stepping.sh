#!/usr/bin/env bash
# Patch 0013 — dbg.resume() must clear all stepping flags.
#
# Otherwise a prior `step` leaves mp_dbg_stepping=1, so after Continue the
# very next opcode re-pauses, making the target look stuck.

set -euo pipefail
MPY_DIR="${MPY_DIR:-$HOME/micropython}"

python3 - <<'PY'
import os
p = os.path.expanduser(os.environ.get("MPY_DIR", "~/micropython")) + "/py/moddbg.c"
s = open(p).read()
old = "static mp_obj_t m_resume(void) { mp_dbg_paused = 0; return mp_const_none; }"
new = ("static mp_obj_t m_resume(void) {\n"
       "    mp_dbg_stepping = 0;\n"
       "    mp_dbg_stepping_in = 0;\n"
       "    mp_dbg_stepping_in_pending = 0;\n"
       "    mp_dbg_stepping_out = 0;\n"
       "    mp_dbg_paused = 0;\n"
       "    return mp_const_none;\n"
       "}")
if old not in s:
    raise SystemExit("FAIL: m_resume not in expected form")
open(p, "w").write(s.replace(old, new, 1))
PY

grep -q 'mp_dbg_stepping_out = 0;' "$MPY_DIR/py/moddbg.c" || { echo "FAIL"; exit 1; }
echo "    0013 applied OK"
