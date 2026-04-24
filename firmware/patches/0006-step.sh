#!/usr/bin/env bash
# Patch 0006 — Single-step (next opcode)
#
# Adds:
#   dbg.step()        — resume, then pause at next opcode
#   volatile mp_dbg_stepping flag in moddbg.{c,h}
#   Hook macro fires while stepping (same gate as bp_count)
#
# Wire cmd 0x11 = step (handled host-side in trace_pump.py).

set -euo pipefail
MPY_DIR="${MPY_DIR:-$HOME/micropython}"

# ---- 1. moddbg.h — extern + macro gate -------------------------------------
python3 - <<'PY'
import os
p = os.path.expanduser(os.environ.get("MPY_DIR", "~/micropython")) + "/py/moddbg.h"
s = open(p).read()

old_ext = "extern volatile uint8_t mp_dbg_paused;"
new_ext = "extern volatile uint8_t mp_dbg_paused;\nextern volatile uint8_t mp_dbg_stepping;"
if old_ext not in s: raise SystemExit("FAIL: paused extern not found")
s = s.replace(old_ext, new_ext, 1)

old_macro = "if ((mp_dbg_trace_enabled && !mp_dbg_muted) || mp_dbg_bp_count)"
new_macro = "if ((mp_dbg_trace_enabled && !mp_dbg_muted) || mp_dbg_bp_count || mp_dbg_stepping)"
if old_macro not in s: raise SystemExit("FAIL: macro cond not found")
s = s.replace(old_macro, new_macro, 1)

open(p, "w").write(s)
PY

# ---- 2. moddbg.c — flag, step handling, python binding ---------------------
python3 - <<'PY'
import os
p = os.path.expanduser(os.environ.get("MPY_DIR", "~/micropython")) + "/py/moddbg.c"
s = open(p).read()

# add flag definition next to mp_dbg_paused
old_def = "volatile uint8_t mp_dbg_paused = 0;"
new_def = "volatile uint8_t mp_dbg_paused = 0;\nvolatile uint8_t mp_dbg_stepping = 0;"
if old_def not in s: raise SystemExit("FAIL: paused def not found")
s = s.replace(old_def, new_def, 1)

# insert step handling after the bp for-loop block, before end of hook
old_hook_end = "    }\n}\n\n// ---- Python API"
new_hook_end = """    }

    // --- single-step ---
    if (mp_dbg_stepping && (const void *)code_state->fun_bc == paused_fun_bc) {
        mp_dbg_stepping = 0;
        paused_fun_bc = (const void *)code_state->fun_bc;
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
if old_hook_end not in s: raise SystemExit("FAIL: hook tail not found")
s = s.replace(old_hook_end, new_hook_end, 1)

# add m_step + binding
old_resume = """static mp_obj_t m_resume(void) { mp_dbg_paused = 0; return mp_const_none; }
static MP_DEFINE_CONST_FUN_OBJ_0(m_resume_obj, m_resume);"""
new_resume = """static mp_obj_t m_resume(void) { mp_dbg_paused = 0; return mp_const_none; }
static MP_DEFINE_CONST_FUN_OBJ_0(m_resume_obj, m_resume);

static mp_obj_t m_step(void) {
    mp_dbg_stepping = 1;
    mp_dbg_paused = 0;
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_0(m_step_obj, m_step);"""
if old_resume not in s: raise SystemExit("FAIL: resume block not found")
s = s.replace(old_resume, new_resume, 1)

# register step in module dict
old_reg = "    { MP_ROM_QSTR(MP_QSTR_resume),       MP_ROM_PTR(&m_resume_obj) },"
new_reg = old_reg + "\n    { MP_ROM_QSTR(MP_QSTR_step),         MP_ROM_PTR(&m_step_obj) },"
if old_reg not in s: raise SystemExit("FAIL: resume reg not found")
s = s.replace(old_reg, new_reg, 1)

open(p, "w").write(s)
PY

# ---- 3. sanity -------------------------------------------------------------
grep -q 'mp_dbg_stepping' "$MPY_DIR/py/moddbg.h" || { echo "FAIL: stepping extern"; exit 1; }
grep -q 'm_step_obj'     "$MPY_DIR/py/moddbg.c" || { echo "FAIL: m_step"; exit 1; }
echo "    0006 applied OK"
