#!/usr/bin/env bash
# Patch 0016 — snapshot the shadow call stack at pause time.
#
# The pump thread also executes Python, so its hook invocations keep
# rewriting the shadow. We snapshot shadow -> paused_shadow the moment
# mp_dbg_paused goes non-zero, and have dbg.call_stack() return the
# snapshot while paused.

set -euo pipefail
MPY_DIR="${MPY_DIR:-$HOME/micropython}"

python3 - <<'PY'
import os, re
p = os.path.expanduser(os.environ.get("MPY_DIR", "~/micropython")) + "/py/moddbg.c"
s = open(p).read()

# 1) Add paused_shadow[] storage next to shadow[]
anchor = "static uint8_t shadow_top = 0;"
if anchor not in s: raise SystemExit("FAIL: shadow_top anchor")
add = """
static shadow_frame_t paused_shadow[MP_DBG_SHADOW_MAX];
static uint8_t paused_shadow_top = 0;
"""
if "paused_shadow[" not in s:
    s = s.replace(anchor, anchor + add, 1)

# 2) In mp_dbg_hook, just before entering the busy-wait pause loop, copy
#    shadow -> paused_shadow ONCE. Anchor on the first `while (mp_dbg_paused)`.
pause_anchor = "while (mp_dbg_paused)"
if pause_anchor not in s: raise SystemExit("FAIL: pause loop anchor")
snap = """    // snapshot shadow at pause
    paused_shadow_top = shadow_top;
    for (int _i = 0; _i < shadow_top; _i++) paused_shadow[_i] = shadow[_i];
    """
if "paused_shadow_top = shadow_top;" not in s:
    s = s.replace(pause_anchor, snap + pause_anchor, 1)

# 3) Change m_call_stack to return paused_shadow when paused.
old_fn = """static mp_obj_t m_call_stack(void) {
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
}"""
new_fn = """static mp_obj_t m_call_stack(void) {
    mp_obj_t list = mp_obj_new_list(0, NULL);
    shadow_frame_t *src = mp_dbg_paused ? paused_shadow : shadow;
    uint8_t n = mp_dbg_paused ? paused_shadow_top : shadow_top;
    for (int i = n - 1; i >= 0; i--) {
        mp_obj_t t[2] = {
            mp_obj_new_int_from_uint((uintptr_t)src[i].fun_bc),
            mp_obj_new_int(src[i].ip_off),
        };
        mp_obj_list_append(list, mp_obj_new_tuple(2, t));
    }
    return list;
}"""
if old_fn not in s: raise SystemExit("FAIL: m_call_stack anchor")
s = s.replace(old_fn, new_fn, 1)

open(p, "w").write(s)
PY

grep -q 'paused_shadow_top' "$MPY_DIR/py/moddbg.c" || { echo "FAIL"; exit 1; }
echo "    0016 applied OK"
