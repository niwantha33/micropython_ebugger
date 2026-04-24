#!/usr/bin/env bash
# Patch 0002 — Scope tracing to a single Python function
#
# Adds:
#   - dbg.trace_func(fun)   — only trace opcodes while inside `fun`
#   - dbg.trace_func(None)  — trace everything (previous default)
#   - dbg.mute() / dbg.unmute() — temporary off switch (pump uses this)
#
# Changes hook signature: MP_DBG_HOOK(ip, code_state).
# The hook compares code_state->fun_bc against the target.

set -euo pipefail

MPY_DIR="${MPY_DIR:-$HOME/micropython}"

# ---- 1. Rewrite py/moddbg.h -------------------------------------------------
cat > "$MPY_DIR/py/moddbg.h" <<'EOF'
// moddbg.h — live debugger hook interface (Phase 3c)
#ifndef MICROPY_INCLUDED_PY_MODDBG_H
#define MICROPY_INCLUDED_PY_MODDBG_H

#include "py/mpconfig.h"
#include "py/bc.h"
#include <stdint.h>

extern volatile uint8_t mp_dbg_trace_enabled;
extern volatile uint8_t mp_dbg_muted;
extern const void *mp_dbg_target_fun_bc;   // NULL = trace any function

void mp_dbg_hook(const byte *ip, const mp_code_state_t *code_state);

#define MP_DBG_HOOK(ip, code_state) do { \
    if (mp_dbg_trace_enabled && !mp_dbg_muted) mp_dbg_hook(ip, code_state); \
} while (0)

#endif // MICROPY_INCLUDED_PY_MODDBG_H
EOF

# ---- 2. Rewrite py/moddbg.c -------------------------------------------------
cat > "$MPY_DIR/py/moddbg.c" <<'EOF'
// moddbg.c — live debugger module (Phase 3c)

#include "py/obj.h"
#include "py/runtime.h"
#include "py/objfun.h"
#include "py/moddbg.h"

#define DBG_RING_SIZE 4096
static uint8_t dbg_ring[DBG_RING_SIZE];
static volatile uint16_t dbg_head = 0;
static volatile uint16_t dbg_tail = 0;
static volatile uint32_t dbg_lost = 0;

volatile uint8_t mp_dbg_trace_enabled = 0;
volatile uint8_t mp_dbg_muted = 0;
const void *mp_dbg_target_fun_bc = NULL;

static inline void dbg_push(uint8_t b) {
    uint16_t next = (uint16_t)((dbg_head + 1) % DBG_RING_SIZE);
    if (next == dbg_tail) { dbg_lost++; return; }
    dbg_ring[dbg_head] = b;
    dbg_head = next;
}

void mp_dbg_hook(const byte *ip, const mp_code_state_t *code_state) {
    // Scope: if a target is set, only emit when we're inside it.
    if (mp_dbg_target_fun_bc != NULL
        && (const void *)code_state->fun_bc != mp_dbg_target_fun_bc) {
        return;
    }
    // 3-byte event: [ip_low, opcode, sentinel]
    dbg_push((uint8_t)((uintptr_t)ip & 0xFF));
    dbg_push(*ip);
    dbg_push(0xFF);
}

// ---- Python API ------------------------------------------------------------

static mp_obj_t mod_dbg_trace_on(void) {
    mp_dbg_trace_enabled = 1;
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_0(mod_dbg_trace_on_obj, mod_dbg_trace_on);

static mp_obj_t mod_dbg_trace_off(void) {
    mp_dbg_trace_enabled = 0;
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_0(mod_dbg_trace_off_obj, mod_dbg_trace_off);

static mp_obj_t mod_dbg_trace_func(mp_obj_t fun_in) {
    if (fun_in == mp_const_none) {
        mp_dbg_target_fun_bc = NULL;
    } else {
        // Accept any bytecode-backed function. Closures and methods share
        // the mp_obj_fun_bc_t layout so a direct cast is OK here.
        mp_dbg_target_fun_bc = (const void *)MP_OBJ_TO_PTR(fun_in);
    }
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_1(mod_dbg_trace_func_obj, mod_dbg_trace_func);

static mp_obj_t mod_dbg_mute(void) {
    mp_dbg_muted = 1;
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_0(mod_dbg_mute_obj, mod_dbg_mute);

static mp_obj_t mod_dbg_unmute(void) {
    mp_dbg_muted = 0;
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_0(mod_dbg_unmute_obj, mod_dbg_unmute);

static mp_obj_t mod_dbg_read_trace(mp_obj_t n_in) {
    mp_int_t n = mp_obj_get_int(n_in);
    if (n < 0) n = 0;
    if (n > 512) n = 512;
    uint8_t tmp[512];
    int i = 0;
    while (i < n && dbg_tail != dbg_head) {
        tmp[i++] = dbg_ring[dbg_tail];
        dbg_tail = (uint16_t)((dbg_tail + 1) % DBG_RING_SIZE);
    }
    return mp_obj_new_bytes(tmp, i);
}
static MP_DEFINE_CONST_FUN_OBJ_1(mod_dbg_read_trace_obj, mod_dbg_read_trace);

static mp_obj_t mod_dbg_lost_count(void) {
    return mp_obj_new_int(dbg_lost);
}
static MP_DEFINE_CONST_FUN_OBJ_0(mod_dbg_lost_count_obj, mod_dbg_lost_count);

static mp_obj_t mod_dbg_reset_lost(void) {
    dbg_lost = 0;
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_0(mod_dbg_reset_lost_obj, mod_dbg_reset_lost);

static const mp_rom_map_elem_t dbg_module_globals_table[] = {
    { MP_ROM_QSTR(MP_QSTR___name__),    MP_ROM_QSTR(MP_QSTR_dbg) },
    { MP_ROM_QSTR(MP_QSTR_trace_on),    MP_ROM_PTR(&mod_dbg_trace_on_obj) },
    { MP_ROM_QSTR(MP_QSTR_trace_off),   MP_ROM_PTR(&mod_dbg_trace_off_obj) },
    { MP_ROM_QSTR(MP_QSTR_trace_func),  MP_ROM_PTR(&mod_dbg_trace_func_obj) },
    { MP_ROM_QSTR(MP_QSTR_mute),        MP_ROM_PTR(&mod_dbg_mute_obj) },
    { MP_ROM_QSTR(MP_QSTR_unmute),      MP_ROM_PTR(&mod_dbg_unmute_obj) },
    { MP_ROM_QSTR(MP_QSTR_read_trace),  MP_ROM_PTR(&mod_dbg_read_trace_obj) },
    { MP_ROM_QSTR(MP_QSTR_lost_count),  MP_ROM_PTR(&mod_dbg_lost_count_obj) },
    { MP_ROM_QSTR(MP_QSTR_reset_lost),  MP_ROM_PTR(&mod_dbg_reset_lost_obj) },
};
static MP_DEFINE_CONST_DICT(dbg_module_globals, dbg_module_globals_table);

const mp_obj_module_t mp_module_dbg = {
    .base = { &mp_type_module },
    .globals = (mp_obj_dict_t *)&dbg_module_globals,
};

MP_REGISTER_MODULE(MP_QSTR_dbg, mp_module_dbg);
EOF

# ---- 3. Update vm.c — hook now takes code_state -----------------------------
VM_C="$MPY_DIR/py/vm.c"

# Rewrite the previously-inserted line to pass code_state too.
# Patch 0001 inserted:    MP_DBG_HOOK(ip); \
# Patch 0002 rewrites to: MP_DBG_HOOK(ip, code_state); \
if ! grep -q 'MP_DBG_HOOK(ip, code_state)' "$VM_C"; then
    sed -i 's|MP_DBG_HOOK(ip); \\|MP_DBG_HOOK(ip, code_state); \\|' "$VM_C"
fi

# ---- 4. Sanity checks -------------------------------------------------------
grep -q 'MP_DBG_HOOK(ip, code_state)' "$VM_C"  || { echo "FAIL: vm.c DISPATCH rewrite"; exit 1; }
grep -q 'trace_func' "$MPY_DIR/py/moddbg.c"    || { echo "FAIL: moddbg.c missing trace_func"; exit 1; }
echo "    0002 applied OK"
