#!/usr/bin/env bash
# Patch 0009 — step-in (step into called function)
#
# Design: pump calls dbg.step_in() which sets a PENDING flag.
# The hook promotes pending -> stepping_in only when core0 exits a
# busy-wait (i.e., after BP pause or step-over pause). This ensures
# the pump's own opcodes never catch stepping_in and freeze the pump.

set -euo pipefail
MPY_DIR="${MPY_DIR:-$HOME/micropython}"

# ---- moddbg.h ---------------------------------------------------------------
python3 - <<'PY'
import os
p = os.path.expanduser(os.environ.get("MPY_DIR", "~/micropython")) + "/py/moddbg.h"
s = open(p).read()

old_ext = "extern volatile uint8_t mp_dbg_stepping;"
new_ext = old_ext + ("\nextern volatile uint8_t mp_dbg_stepping_in;"
                     "\nextern volatile uint8_t mp_dbg_stepping_in_pending;")
if old_ext not in s: raise SystemExit("FAIL: stepping extern")
s = s.replace(old_ext, new_ext, 1)

old_macro = "|| mp_dbg_bp_count || mp_dbg_stepping)"
new_macro = "|| mp_dbg_bp_count || mp_dbg_stepping || mp_dbg_stepping_in)"
if old_macro not in s: raise SystemExit("FAIL: macro cond")
s = s.replace(old_macro, new_macro, 1)

open(p, "w").write(s)
PY

# ---- moddbg.c ---------------------------------------------------------------
python3 - <<'PY'
import os
p = os.path.expanduser(os.environ.get("MPY_DIR", "~/micropython")) + "/py/moddbg.c"
s = open(p).read()

# 1) flag definitions
old_def = "volatile uint8_t mp_dbg_stepping = 0;"
new_def = old_def + ("\nvolatile uint8_t mp_dbg_stepping_in = 0;"
                    "\nvolatile uint8_t mp_dbg_stepping_in_pending = 0;")
if old_def not in s: raise SystemExit("FAIL: stepping def")
s = s.replace(old_def, new_def, 1)

# 2) promote pending after BP busy-wait exit
old_bp = """                while (mp_dbg_paused) {
                    mp_hal_delay_us(200);
                    // allow Ctrl-C / other pending events
                    mp_handle_pending(true);
                }
                break;"""
new_bp = """                while (mp_dbg_paused) {
                    mp_hal_delay_us(200);
                    // allow Ctrl-C / other pending events
                    mp_handle_pending(true);
                }
                if (mp_dbg_stepping_in_pending) { mp_dbg_stepping_in = 1; mp_dbg_stepping_in_pending = 0; }
                break;"""
if old_bp not in s: raise SystemExit("FAIL: bp busy-wait")
s = s.replace(old_bp, new_bp, 1)

# 3) promote pending after step-over busy-wait exit; also insert step-in block
old_tail = """        while (mp_dbg_paused) {
            mp_hal_delay_us(200);
            mp_handle_pending(true);
        }
    }
}

// ---- Python API"""
new_tail = """        while (mp_dbg_paused) {
            mp_hal_delay_us(200);
            mp_handle_pending(true);
        }
        if (mp_dbg_stepping_in_pending) { mp_dbg_stepping_in = 1; mp_dbg_stepping_in_pending = 0; }
    }

    // --- step-in (any frame, armed only after a core0 busy-wait exit) ---
    if (mp_dbg_stepping_in && !mp_dbg_muted) {
        mp_dbg_stepping_in = 0;
        paused_fun_bc = (const void *)code_state->fun_bc;
        paused_code_state = code_state;
        paused_ip_off = off16;
        emit_bp_hit(off16);
        mp_dbg_paused = 1;
        while (mp_dbg_paused) {
            mp_hal_delay_us(200);
            mp_handle_pending(true);
        }
        if (mp_dbg_stepping_in_pending) { mp_dbg_stepping_in = 1; mp_dbg_stepping_in_pending = 0; }
    }
}

// ---- Python API"""
if old_tail not in s: raise SystemExit("FAIL: step-over tail not found")
s = s.replace(old_tail, new_tail, 1)

# 4) m_step_in API (sets PENDING)
old_step_api = """static mp_obj_t m_step(void) {
    mp_dbg_stepping = 1;
    mp_dbg_paused = 0;
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_0(m_step_obj, m_step);"""
new_step_api = old_step_api + """

static mp_obj_t m_step_in(void) {
    mp_dbg_stepping_in_pending = 1;
    mp_dbg_paused = 0;
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_0(m_step_in_obj, m_step_in);"""
if old_step_api not in s: raise SystemExit("FAIL: m_step not found")
s = s.replace(old_step_api, new_step_api, 1)

# 5) register m_step_in
old_reg = "    { MP_ROM_QSTR(MP_QSTR_step),         MP_ROM_PTR(&m_step_obj) },"
new_reg = old_reg + "\n    { MP_ROM_QSTR(MP_QSTR_step_in),      MP_ROM_PTR(&m_step_in_obj) },"
if old_reg not in s: raise SystemExit("FAIL: step reg")
s = s.replace(old_reg, new_reg, 1)

open(p, "w").write(s)
PY

grep -q 'mp_dbg_stepping_in_pending' "$MPY_DIR/py/moddbg.c" || { echo "FAIL"; exit 1; }
echo "    0009 applied OK"
