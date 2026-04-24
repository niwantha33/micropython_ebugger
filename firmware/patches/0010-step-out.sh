#!/usr/bin/env bash
# Patch 0010 — step-out (resume until we leave the current frame)
#
# Behavior: pause on first opcode whose fun_bc differs from the one paused at
# when step-out was requested. Limitation: if the current frame calls into
# another function first, we pause there. User can `c` to continue.
#
# Wire cmd 0x14 = step-out.

set -euo pipefail
MPY_DIR="${MPY_DIR:-$HOME/micropython}"

python3 - <<'PY'
import os
p = os.path.expanduser(os.environ.get("MPY_DIR", "~/micropython")) + "/py/moddbg.h"
s = open(p).read()
old_ext = "extern volatile uint8_t mp_dbg_stepping_in_pending;"
new_ext = old_ext + "\nextern volatile uint8_t mp_dbg_stepping_out;"
if old_ext not in s: raise SystemExit("FAIL: step_in_pending extern")
s = s.replace(old_ext, new_ext, 1)

old_macro = "|| mp_dbg_stepping || mp_dbg_stepping_in)"
new_macro = "|| mp_dbg_stepping || mp_dbg_stepping_in || mp_dbg_stepping_out)"
if old_macro not in s: raise SystemExit("FAIL: macro cond")
s = s.replace(old_macro, new_macro, 1)
open(p, "w").write(s)
PY

python3 - <<'PY'
import os
p = os.path.expanduser(os.environ.get("MPY_DIR", "~/micropython")) + "/py/moddbg.c"
s = open(p).read()

old_def = "volatile uint8_t mp_dbg_stepping_in_pending = 0;"
new_def = old_def + "\nvolatile uint8_t mp_dbg_stepping_out = 0;\nstatic const void *step_out_from = NULL;"
if old_def not in s: raise SystemExit("FAIL: pending def")
s = s.replace(old_def, new_def, 1)

# Add step-out block just before end of hook function (after step-in block).
old_tail = """        if (mp_dbg_stepping_in_pending) { mp_dbg_stepping_in = 1; mp_dbg_stepping_in_pending = 0; }
    }
}

// ---- Python API"""
new_tail = """        if (mp_dbg_stepping_in_pending) { mp_dbg_stepping_in = 1; mp_dbg_stepping_in_pending = 0; }
    }

    // --- step-out (pause when we leave step_out_from frame) ---
    if (mp_dbg_stepping_out && !mp_dbg_muted
        && (const void *)code_state->fun_bc != step_out_from) {
        mp_dbg_stepping_out = 0;
        step_out_from = NULL;
        paused_fun_bc = (const void *)code_state->fun_bc;
        paused_code_state = code_state;
        paused_ip_off = off16;
        emit_bp_hit(off16);
        mp_dbg_paused = 1;
        while (mp_dbg_paused) {
            mp_hal_delay_us(200);
            mp_handle_pending(true);
        }
    }
}

// ---- Python API"""
if old_tail not in s: raise SystemExit("FAIL: step-in tail not found")
s = s.replace(old_tail, new_tail, 1)

# m_step_out API
old_api = """static mp_obj_t m_step_in(void) {
    mp_dbg_stepping_in_pending = 1;
    mp_dbg_paused = 0;
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_0(m_step_in_obj, m_step_in);"""
new_api = old_api + """

static mp_obj_t m_step_out(void) {
    step_out_from = paused_fun_bc;
    mp_dbg_stepping_out = 1;
    mp_dbg_paused = 0;
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_0(m_step_out_obj, m_step_out);"""
if old_api not in s: raise SystemExit("FAIL: step_in api")
s = s.replace(old_api, new_api, 1)

old_reg = "    { MP_ROM_QSTR(MP_QSTR_step_in),      MP_ROM_PTR(&m_step_in_obj) },"
new_reg = old_reg + "\n    { MP_ROM_QSTR(MP_QSTR_step_out),     MP_ROM_PTR(&m_step_out_obj) },"
if old_reg not in s: raise SystemExit("FAIL: step_in reg")
s = s.replace(old_reg, new_reg, 1)

open(p, "w").write(s)
PY

grep -q 'm_step_out_obj' "$MPY_DIR/py/moddbg.c" || { echo "FAIL"; exit 1; }
echo "    0010 applied OK"
