#!/usr/bin/env bash
# Patch 0008 — Frame info for paused state
#
# Adds:
#   dbg.frame_info() -> (n_state, sp_off, ip_off) or None
#     n_state : size of state[] array
#     sp_off  : sp - state  (index into state[] of top-of-stack)
#     ip_off  : ip offset within bytecode
#
# Locals live at state[n_state - 1 - i] (LOAD_FAST order).
# Value stack lives below the locals, tracked by sp.

set -euo pipefail
MPY_DIR="${MPY_DIR:-$HOME/micropython}"

python3 - <<'PY'
import os
p = os.path.expanduser(os.environ.get("MPY_DIR", "~/micropython")) + "/py/moddbg.c"
s = open(p).read()

# Add m_frame_info after m_locals
old = """static MP_DEFINE_CONST_FUN_OBJ_0(m_locals_obj, m_locals);"""
new = old + """

static mp_obj_t m_frame_info(void) {
    if (!mp_dbg_paused || paused_code_state == NULL) return mp_const_none;
    const mp_code_state_t *cs = paused_code_state;
    mp_int_t sp_off = (cs->sp >= cs->state) ? (mp_int_t)(cs->sp - cs->state) : -1;
    mp_obj_t t[3] = {
        mp_obj_new_int_from_uint(cs->n_state),
        mp_obj_new_int(sp_off),
        mp_obj_new_int(paused_ip_off),
    };
    return mp_obj_new_tuple(3, t);
}
static MP_DEFINE_CONST_FUN_OBJ_0(m_frame_info_obj, m_frame_info);"""
if old not in s: raise SystemExit("FAIL: locals anchor missing")
s = s.replace(old, new, 1)

# Register
old_reg = "    { MP_ROM_QSTR(MP_QSTR_locals),       MP_ROM_PTR(&m_locals_obj) },"
new_reg = old_reg + "\n    { MP_ROM_QSTR(MP_QSTR_frame_info),   MP_ROM_PTR(&m_frame_info_obj) },"
if old_reg not in s: raise SystemExit("FAIL: locals reg not found")
s = s.replace(old_reg, new_reg, 1)

open(p, "w").write(s)
PY

grep -q 'm_frame_info_obj' "$MPY_DIR/py/moddbg.c" || { echo "FAIL: frame_info missing"; exit 1; }
echo "    0008 applied OK"
