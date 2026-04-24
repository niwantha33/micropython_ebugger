#!/usr/bin/env bash
# Patch 0005 — Breakpoints must not be skipped during mute
#
# The mute flag is used by the pump thread to avoid re-tracing its own
# work. But BP checks are critical for correctness and must fire every
# opcode regardless. Split the check:
#   - macro always calls hook when BPs are set
#   - mute only gates trace emission, inside the hook function

set -euo pipefail

MPY_DIR="${MPY_DIR:-$HOME/micropython}"

# ---- 1. Fix the macro in moddbg.h ------------------------------------------
python3 - <<'PY'
import os
p = os.path.expanduser(os.environ.get("MPY_DIR", "~/micropython")) + "/py/moddbg.h"
src = open(p).read()
old = '''#define MP_DBG_HOOK(ip, code_state) do { \\
    if (mp_dbg_trace_enabled || mp_dbg_bp_count) { \\
        if (!mp_dbg_muted) mp_dbg_hook(ip, code_state); \\
    } \\
} while (0)'''
new = '''#define MP_DBG_HOOK(ip, code_state) do { \\
    if ((mp_dbg_trace_enabled && !mp_dbg_muted) || mp_dbg_bp_count) { \\
        mp_dbg_hook(ip, code_state); \\
    } \\
} while (0)'''
if old not in src:
    raise SystemExit("FAIL: macro pattern not found in moddbg.h")
open(p, "w").write(src.replace(old, new))
PY

# ---- 2. Add mute check to trace emission inside moddbg.c -------------------
python3 - <<'PY'
import os
p = os.path.expanduser(os.environ.get("MPY_DIR", "~/micropython")) + "/py/moddbg.c"
src = open(p).read()
old = "    if (mp_dbg_trace_enabled) {"
new = "    if (mp_dbg_trace_enabled && !mp_dbg_muted) {"
if old not in src:
    raise SystemExit("FAIL: trace_enabled check not found in moddbg.c")
open(p, "w").write(src.replace(old, new, 1))
PY

echo "    0005 applied OK"
