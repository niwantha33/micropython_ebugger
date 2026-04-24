#!/usr/bin/env bash
# Patch 0015 — dbg.call_stack() via shadow frame stack
#
# We maintain a small stack of (fun_bc, last_ip) tuples in moddbg.c. On every
# hook call we compare the current code_state pointer against the top of our
# shadow: if it differs, we either popped (frame address found deeper) or
# pushed (frame is new).
#
# This avoids needing MICROPY_PY_SYS_SETTRACE / STACKLESS.

set -euo pipefail
MPY_DIR="${MPY_DIR:-$HOME/micropython}"

python3 - <<'PY'
import os, re
p = os.path.expanduser(os.environ.get("MPY_DIR", "~/micropython")) + "/py/moddbg.c"
s = open(p).read()

# Defensive: strip any previous call_stack attempt
s = re.sub(r'\n*static mp_obj_t m_call_stack.*?MP_DEFINE_CONST_FUN_OBJ_0\(m_call_stack_obj, m_call_stack\);\n', '\n', s, flags=re.DOTALL)
s = s.replace('    { MP_ROM_QSTR(MP_QSTR_call_stack),   MP_ROM_PTR(&m_call_stack_obj) },\n', '')

# 1) shadow stack state — put after paused_code_state declaration
shadow_state = """
// ---- shadow call stack -----------------------------------------------------
#define MP_DBG_SHADOW_MAX 32
typedef struct { const void *cs; const void *fun_bc; uint16_t ip_off; } shadow_frame_t;
static shadow_frame_t shadow[MP_DBG_SHADOW_MAX];
static uint8_t shadow_top = 0;
"""

anchor = "static const void *paused_fun_bc = NULL;"
if anchor not in s: raise SystemExit("FAIL: paused_fun_bc anchor")
s = s.replace(anchor, anchor + shadow_state, 1)

# 2) update shadow at top of mp_dbg_hook (after the bc_start/off computations)
update_snippet = """    // --- shadow stack update ---
    {
        const void *cur_cs = (const void *)code_state;
        int found = -1;
        for (int i = shadow_top - 1; i >= 0; i--) {
            if (shadow[i].cs == cur_cs) { found = i; break; }
        }
        if (found >= 0) {
            shadow_top = (uint8_t)(found + 1);
        } else if (shadow_top < MP_DBG_SHADOW_MAX) {
            shadow[shadow_top].cs = cur_cs;
            shadow[shadow_top].fun_bc = (const void *)code_state->fun_bc;
            shadow_top++;
        }
        if (shadow_top > 0) shadow[shadow_top - 1].ip_off = off16;
    }
"""

hook_anchor = "    uint16_t off16 = (off > 0xFFFF) ? 0xFFFF : (uint16_t)off;"
if hook_anchor not in s: raise SystemExit("FAIL: hook off16 anchor")
s = s.replace(hook_anchor, hook_anchor + "\n" + update_snippet, 1)

# 3) expose dbg.call_stack()
helper = """
static mp_obj_t m_call_stack(void) {
    mp_obj_t list = mp_obj_new_list(0, NULL);
    // Innermost first
    for (int i = shadow_top - 1; i >= 0; i--) {
        mp_obj_t t[2] = {
            mp_obj_new_int_from_uint((uintptr_t)shadow[i].fun_bc),
            mp_obj_new_int(shadow[i].ip_off),
        };
        mp_obj_list_append(list, mp_obj_new_tuple(2, t));
    }
    return list;
}
static MP_DEFINE_CONST_FUN_OBJ_0(m_call_stack_obj, m_call_stack);
"""

g_anchor = "static const mp_rom_map_elem_t dbg_module_globals_table[] = {"
if g_anchor not in s: raise SystemExit("FAIL: globals anchor")
s = s.replace(g_anchor, helper + "\n" + g_anchor, 1)

old_reg = "    { MP_ROM_QSTR(MP_QSTR_paused_info),  MP_ROM_PTR(&m_paused_info_obj) },"
new_reg = old_reg + "\n    { MP_ROM_QSTR(MP_QSTR_call_stack),   MP_ROM_PTR(&m_call_stack_obj) },"
if old_reg not in s: raise SystemExit("FAIL: paused_info reg")
s = s.replace(old_reg, new_reg, 1)

open(p, "w").write(s)
PY

grep -q 'm_call_stack_obj' "$MPY_DIR/py/moddbg.c" || { echo "FAIL"; exit 1; }
echo "    0015 applied OK"
