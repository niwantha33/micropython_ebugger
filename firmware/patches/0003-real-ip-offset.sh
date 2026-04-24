#!/usr/bin/env bash
# Patch 0003 — Real ip offset + target metadata
#
# Event format changes from 3 bytes to 4 bytes:
#   [ip_lo, ip_hi, opcode, 0xFF]
#
# ip_lo/ip_hi is a 16-bit offset from the CURRENT function's bytecode start
# (code_state->fun_bc->bytecode). This is what a real disassembler / GUI
# needs to highlight a line.
#
# New API:
#   dbg.target_info()  -> dict with bytecode address and source info
#                         (None if no target set)

set -euo pipefail

MPY_DIR="${MPY_DIR:-$HOME/micropython}"

# ---- 1. Rewrite py/moddbg.c -------------------------------------------------
cat > "$MPY_DIR/py/moddbg.c" <<'EOF'
// moddbg.c — live debugger module (Phase 3d)

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
    // Scope filter
    if (mp_dbg_target_fun_bc != NULL
        && (const void *)code_state->fun_bc != mp_dbg_target_fun_bc) {
        return;
    }

    // ip offset relative to the current function's bytecode start.
    // 16 bits is plenty for any realistic MicroPython function.
    const byte *bc_start = code_state->fun_bc->bytecode;
    uint32_t off = (uint32_t)(ip - bc_start);
    uint16_t off16 = (off > 0xFFFF) ? 0xFFFF : (uint16_t)off;

    dbg_push((uint8_t)(off16 & 0xFF));
    dbg_push((uint8_t)(off16 >> 8));
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
        mp_dbg_target_fun_bc = (const void *)MP_OBJ_TO_PTR(fun_in);
    }
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_1(mod_dbg_trace_func_obj, mod_dbg_trace_func);

static mp_obj_t mod_dbg_target_info(void) {
    if (mp_dbg_target_fun_bc == NULL) {
        return mp_const_none;
    }
    const mp_obj_fun_bc_t *fun = (const mp_obj_fun_bc_t *)mp_dbg_target_fun_bc;
    // Expose the bytecode pointer and the fun_bc pointer as ints so the host
    // has stable handles. More fields (source file, line table) will follow.
    mp_obj_t items[2] = {
        mp_obj_new_int_from_uint((uintptr_t)fun),
        mp_obj_new_int_from_uint((uintptr_t)fun->bytecode),
    };
    mp_obj_t d = mp_obj_new_dict(2);
    mp_obj_dict_store(d, MP_ROM_QSTR(MP_QSTR_fun_bc), items[0]);
    mp_obj_dict_store(d, MP_ROM_QSTR(MP_QSTR_bytecode), items[1]);
    return d;
}
static MP_DEFINE_CONST_FUN_OBJ_0(mod_dbg_target_info_obj, mod_dbg_target_info);

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
    { MP_ROM_QSTR(MP_QSTR___name__),     MP_ROM_QSTR(MP_QSTR_dbg) },
    { MP_ROM_QSTR(MP_QSTR_trace_on),     MP_ROM_PTR(&mod_dbg_trace_on_obj) },
    { MP_ROM_QSTR(MP_QSTR_trace_off),    MP_ROM_PTR(&mod_dbg_trace_off_obj) },
    { MP_ROM_QSTR(MP_QSTR_trace_func),   MP_ROM_PTR(&mod_dbg_trace_func_obj) },
    { MP_ROM_QSTR(MP_QSTR_target_info),  MP_ROM_PTR(&mod_dbg_target_info_obj) },
    { MP_ROM_QSTR(MP_QSTR_mute),         MP_ROM_PTR(&mod_dbg_mute_obj) },
    { MP_ROM_QSTR(MP_QSTR_unmute),       MP_ROM_PTR(&mod_dbg_unmute_obj) },
    { MP_ROM_QSTR(MP_QSTR_read_trace),   MP_ROM_PTR(&mod_dbg_read_trace_obj) },
    { MP_ROM_QSTR(MP_QSTR_lost_count),   MP_ROM_PTR(&mod_dbg_lost_count_obj) },
    { MP_ROM_QSTR(MP_QSTR_reset_lost),   MP_ROM_PTR(&mod_dbg_reset_lost_obj) },
};
static MP_DEFINE_CONST_DICT(dbg_module_globals, dbg_module_globals_table);

const mp_obj_module_t mp_module_dbg = {
    .base = { &mp_type_module },
    .globals = (mp_obj_dict_t *)&dbg_module_globals,
};

MP_REGISTER_MODULE(MP_QSTR_dbg, mp_module_dbg);
EOF

# ---- 2. Sanity checks -------------------------------------------------------
grep -q 'target_info' "$MPY_DIR/py/moddbg.c"   || { echo "FAIL: moddbg.c missing target_info"; exit 1; }
grep -q 'off16' "$MPY_DIR/py/moddbg.c"         || { echo "FAIL: moddbg.c missing 16-bit offset"; exit 1; }
echo "    0003 applied OK"
