#!/usr/bin/env bash
# Patch 0011 — skip stepping pauses when the pump's own function is executing.
#
# Why: stepping flags are global but we only want the main/target thread to
# catch them. The mute-gate approach raced because mute toggles around I/O.
# This patch registers a "pump fun_bc" at start; hook skips step-over/in/out
# when code_state->fun_bc matches.

set -euo pipefail
MPY_DIR="${MPY_DIR:-$HOME/micropython}"

python3 - <<'PY'
import os
p = os.path.expanduser(os.environ.get("MPY_DIR", "~/micropython")) + "/py/moddbg.c"
s = open(p).read()

# Add pump_fun_bc static
old = "static const void *step_out_from = NULL;"
new = old + "\nstatic const void *pump_fun_bc = NULL;"
if old not in s: raise SystemExit("FAIL: step_out_from def")
s = s.replace(old, new, 1)

# Replace step-over gate: add `&& fun_bc != pump_fun_bc`
old_so = "if (mp_dbg_stepping && (const void *)code_state->fun_bc == paused_fun_bc)"
new_so = "if (mp_dbg_stepping && (const void *)code_state->fun_bc == paused_fun_bc && (const void *)code_state->fun_bc != pump_fun_bc)"
if old_so not in s: raise SystemExit("FAIL: step-over gate")
s = s.replace(old_so, new_so, 1)

# Replace step-in gate: drop !muted, add pump filter
old_si = "if (mp_dbg_stepping_in && !mp_dbg_muted)"
new_si = "if (mp_dbg_stepping_in && (const void *)code_state->fun_bc != pump_fun_bc)"
if old_si not in s: raise SystemExit("FAIL: step-in gate")
s = s.replace(old_si, new_si, 1)

# Replace step-out gate: drop !muted, add pump filter
old_so_o = "if (mp_dbg_stepping_out && !mp_dbg_muted\n        && (const void *)code_state->fun_bc != step_out_from)"
new_so_o = "if (mp_dbg_stepping_out && (const void *)code_state->fun_bc != step_out_from && (const void *)code_state->fun_bc != pump_fun_bc)"
if old_so_o not in s: raise SystemExit("FAIL: step-out gate")
s = s.replace(old_so_o, new_so_o, 1)

# Add set_pump_fun API
old_api = """static mp_obj_t m_step_out(void) {
    step_out_from = paused_fun_bc;
    mp_dbg_stepping_out = 1;
    mp_dbg_paused = 0;
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_0(m_step_out_obj, m_step_out);"""
new_api = old_api + """

static mp_obj_t m_set_pump_fun(mp_obj_t fn_in) {
    pump_fun_bc = (fn_in == mp_const_none) ? NULL : (const void *)MP_OBJ_TO_PTR(fn_in);
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_1(m_set_pump_fun_obj, m_set_pump_fun);"""
if old_api not in s: raise SystemExit("FAIL: step-out api")
s = s.replace(old_api, new_api, 1)

old_reg = "    { MP_ROM_QSTR(MP_QSTR_step_out),     MP_ROM_PTR(&m_step_out_obj) },"
new_reg = old_reg + "\n    { MP_ROM_QSTR(MP_QSTR_set_pump_fun), MP_ROM_PTR(&m_set_pump_fun_obj) },"
if old_reg not in s: raise SystemExit("FAIL: step_out reg")
s = s.replace(old_reg, new_reg, 1)

open(p, "w").write(s)
PY

grep -q 'pump_fun_bc' "$MPY_DIR/py/moddbg.c" || { echo "FAIL"; exit 1; }
echo "    0011 applied OK"
