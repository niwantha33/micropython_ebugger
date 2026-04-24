#!/usr/bin/env bash
# Patch 0007 — Inspect locals while paused
#
# Adds:
#   dbg.locals()  -> list of objects (state[] of the paused frame)
#                    returns None if not paused
#
# Captures code_state pointer when paused, so Python can walk it.

set -euo pipefail
MPY_DIR="${MPY_DIR:-$HOME/micropython}"

# ---- 1. moddbg.c -----------------------------------------------------------
python3 - <<'PY'
import os
p = os.path.expanduser(os.environ.get("MPY_DIR", "~/micropython")) + "/py/moddbg.c"
s = open(p).read()

# Add a file-scope pointer next to the paused metadata
old_state = "static const void *paused_fun_bc = NULL;"
new_state = "static const void *paused_fun_bc = NULL;\nstatic const mp_code_state_t *paused_code_state = NULL;"
if old_state not in s: raise SystemExit("FAIL: paused_fun_bc decl not found")
s = s.replace(old_state, new_state, 1)

# Capture code_state in BP block
old_bp = """                paused_fun_bc = (const void *)code_state->fun_bc;
                paused_ip_off = off16;
                emit_bp_hit(off16);"""
new_bp = """                paused_fun_bc = (const void *)code_state->fun_bc;
                paused_code_state = code_state;
                paused_ip_off = off16;
                emit_bp_hit(off16);"""
if old_bp not in s: raise SystemExit("FAIL: bp capture block not found")
s = s.replace(old_bp, new_bp, 1)

# Capture code_state in step block
old_step = """        mp_dbg_stepping = 0;
        paused_fun_bc = (const void *)code_state->fun_bc;
        paused_ip_off = off16;"""
new_step = """        mp_dbg_stepping = 0;
        paused_fun_bc = (const void *)code_state->fun_bc;
        paused_code_state = code_state;
        paused_ip_off = off16;"""
if old_step not in s: raise SystemExit("FAIL: step capture block not found")
s = s.replace(old_step, new_step, 1)

# Add m_locals + binding
old_resume = """static mp_obj_t m_resume(void) { mp_dbg_paused = 0; return mp_const_none; }
static MP_DEFINE_CONST_FUN_OBJ_0(m_resume_obj, m_resume);"""
new_resume = """static mp_obj_t m_resume(void) { mp_dbg_paused = 0; return mp_const_none; }
static MP_DEFINE_CONST_FUN_OBJ_0(m_resume_obj, m_resume);

static mp_obj_t m_locals(void) {
    if (!mp_dbg_paused || paused_code_state == NULL) return mp_const_none;
    size_t n = paused_code_state->n_state;
    mp_obj_t list = mp_obj_new_list(0, NULL);
    for (size_t i = 0; i < n; i++) {
        mp_obj_t v = paused_code_state->state[i];
        if (v == MP_OBJ_NULL) v = mp_const_none;
        mp_obj_list_append(list, v);
    }
    return list;
}
static MP_DEFINE_CONST_FUN_OBJ_0(m_locals_obj, m_locals);"""
if old_resume not in s: raise SystemExit("FAIL: resume block not found")
s = s.replace(old_resume, new_resume, 1)

# Register m_locals
old_reg = "    { MP_ROM_QSTR(MP_QSTR_resume),       MP_ROM_PTR(&m_resume_obj) },"
new_reg = old_reg + "\n    { MP_ROM_QSTR(MP_QSTR_locals),       MP_ROM_PTR(&m_locals_obj) },"
if old_reg not in s: raise SystemExit("FAIL: resume reg not found")
s = s.replace(old_reg, new_reg, 1)

open(p, "w").write(s)
PY

grep -q 'm_locals_obj' "$MPY_DIR/py/moddbg.c" || { echo "FAIL: m_locals missing"; exit 1; }
echo "    0007 applied OK"
