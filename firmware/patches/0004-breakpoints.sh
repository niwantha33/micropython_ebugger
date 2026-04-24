#!/usr/bin/env bash
# Patch 0004 — Breakpoints + framed wire protocol
#
# Wire format changes:
#   Every event is framed:  [0xAA sync] [type] [len] [payload(len)...]
#     type 0x01 = trace event    payload [ip_lo, ip_hi, op]       (3 B)
#     type 0x02 = bp_hit event   payload [ip_lo, ip_hi]           (2 B)
#   (Command type 0x10 = continue — host→board, handled Python-side.)
#
# New API:
#   dbg.set_bp(fun, ip_off) -> int slot
#   dbg.clear_bp(slot)
#   dbg.list_bp() -> list of (slot, fun_bc_ptr, ip_off, active)
#   dbg.is_paused() -> bool
#   dbg.paused_info() -> (fun_bc_ptr, ip_off) or None
#   dbg.resume()

set -euo pipefail

MPY_DIR="${MPY_DIR:-$HOME/micropython}"

# ---- 1. moddbg.h (add public state) -----------------------------------------
cat > "$MPY_DIR/py/moddbg.h" <<'EOF'
// moddbg.h — live debugger hook interface (Phase 4)
#ifndef MICROPY_INCLUDED_PY_MODDBG_H
#define MICROPY_INCLUDED_PY_MODDBG_H

#include "py/mpconfig.h"
#include "py/bc.h"
#include <stdint.h>

extern volatile uint8_t mp_dbg_trace_enabled;
extern volatile uint8_t mp_dbg_muted;
extern volatile uint8_t mp_dbg_bp_count;
extern volatile uint8_t mp_dbg_paused;
extern const void *mp_dbg_target_fun_bc;

void mp_dbg_hook(const byte *ip, const mp_code_state_t *code_state);

#define MP_DBG_HOOK(ip, code_state) do { \
    if (mp_dbg_trace_enabled || mp_dbg_bp_count) { \
        if (!mp_dbg_muted) mp_dbg_hook(ip, code_state); \
    } \
} while (0)

#endif // MICROPY_INCLUDED_PY_MODDBG_H
EOF

# ---- 2. moddbg.c ------------------------------------------------------------
cat > "$MPY_DIR/py/moddbg.c" <<'EOF'
// moddbg.c — live debugger module (Phase 4)

#include "py/obj.h"
#include "py/runtime.h"
#include "py/objfun.h"
#include "py/mphal.h"
#include "py/moddbg.h"

#define DBG_RING_SIZE 4096
#define MAX_BPS 16

static uint8_t dbg_ring[DBG_RING_SIZE];
static volatile uint16_t dbg_head = 0;
static volatile uint16_t dbg_tail = 0;
static volatile uint32_t dbg_lost = 0;

volatile uint8_t mp_dbg_trace_enabled = 0;
volatile uint8_t mp_dbg_muted = 0;
volatile uint8_t mp_dbg_bp_count = 0;
volatile uint8_t mp_dbg_paused = 0;
const void *mp_dbg_target_fun_bc = NULL;

typedef struct {
    const void *fun_bc;
    uint16_t ip_off;
    uint8_t active;
} bp_entry_t;

static bp_entry_t bp_table[MAX_BPS];
static uint16_t paused_ip_off = 0;
static const void *paused_fun_bc = NULL;

static inline void dbg_push(uint8_t b) {
    uint16_t next = (uint16_t)((dbg_head + 1) % DBG_RING_SIZE);
    if (next == dbg_tail) { dbg_lost++; return; }
    dbg_ring[dbg_head] = b;
    dbg_head = next;
}

static inline void emit_trace(uint16_t ip_off, uint8_t op) {
    dbg_push(0xAA); dbg_push(0x01); dbg_push(3);
    dbg_push((uint8_t)(ip_off & 0xFF));
    dbg_push((uint8_t)(ip_off >> 8));
    dbg_push(op);
}

static inline void emit_bp_hit(uint16_t ip_off) {
    dbg_push(0xAA); dbg_push(0x02); dbg_push(2);
    dbg_push((uint8_t)(ip_off & 0xFF));
    dbg_push((uint8_t)(ip_off >> 8));
}

void mp_dbg_hook(const byte *ip, const mp_code_state_t *code_state) {
    const byte *bc_start = code_state->fun_bc->bytecode;
    uint32_t off = (uint32_t)(ip - bc_start);
    uint16_t off16 = (off > 0xFFFF) ? 0xFFFF : (uint16_t)off;

    // --- trace ---
    if (mp_dbg_trace_enabled) {
        int in_scope = (mp_dbg_target_fun_bc == NULL)
            || ((const void *)code_state->fun_bc == mp_dbg_target_fun_bc);
        if (in_scope) emit_trace(off16, *ip);
    }

    // --- breakpoints ---
    if (mp_dbg_bp_count > 0) {
        for (int i = 0; i < MAX_BPS; i++) {
            if (bp_table[i].active
                && bp_table[i].fun_bc == (const void *)code_state->fun_bc
                && bp_table[i].ip_off == off16) {
                paused_fun_bc = (const void *)code_state->fun_bc;
                paused_ip_off = off16;
                emit_bp_hit(off16);
                mp_dbg_paused = 1;
                // Busy-wait; pump thread on the other core will flip the flag.
                while (mp_dbg_paused) {
                    mp_hal_delay_us(200);
                    // allow Ctrl-C / other pending events
                    mp_handle_pending(true);
                }
                break;
            }
        }
    }
}

// ---- Python API ------------------------------------------------------------

static mp_obj_t m_trace_on(void)  { mp_dbg_trace_enabled = 1; return mp_const_none; }
static mp_obj_t m_trace_off(void) { mp_dbg_trace_enabled = 0; return mp_const_none; }
static mp_obj_t m_mute(void)      { mp_dbg_muted = 1; return mp_const_none; }
static mp_obj_t m_unmute(void)    { mp_dbg_muted = 0; return mp_const_none; }
static MP_DEFINE_CONST_FUN_OBJ_0(m_trace_on_obj,  m_trace_on);
static MP_DEFINE_CONST_FUN_OBJ_0(m_trace_off_obj, m_trace_off);
static MP_DEFINE_CONST_FUN_OBJ_0(m_mute_obj,      m_mute);
static MP_DEFINE_CONST_FUN_OBJ_0(m_unmute_obj,    m_unmute);

static mp_obj_t m_trace_func(mp_obj_t fun_in) {
    mp_dbg_target_fun_bc = (fun_in == mp_const_none) ? NULL : (const void *)MP_OBJ_TO_PTR(fun_in);
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_1(m_trace_func_obj, m_trace_func);

static mp_obj_t m_target_info(void) {
    if (mp_dbg_target_fun_bc == NULL) return mp_const_none;
    const mp_obj_fun_bc_t *fun = (const mp_obj_fun_bc_t *)mp_dbg_target_fun_bc;
    mp_obj_t d = mp_obj_new_dict(2);
    mp_obj_dict_store(d, MP_ROM_QSTR(MP_QSTR_fun_bc),   mp_obj_new_int_from_uint((uintptr_t)fun));
    mp_obj_dict_store(d, MP_ROM_QSTR(MP_QSTR_bytecode), mp_obj_new_int_from_uint((uintptr_t)fun->bytecode));
    return d;
}
static MP_DEFINE_CONST_FUN_OBJ_0(m_target_info_obj, m_target_info);

static mp_obj_t m_read_trace(mp_obj_t n_in) {
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
static MP_DEFINE_CONST_FUN_OBJ_1(m_read_trace_obj, m_read_trace);

static mp_obj_t m_lost_count(void)  { return mp_obj_new_int(dbg_lost); }
static mp_obj_t m_reset_lost(void)  { dbg_lost = 0; return mp_const_none; }
static MP_DEFINE_CONST_FUN_OBJ_0(m_lost_count_obj, m_lost_count);
static MP_DEFINE_CONST_FUN_OBJ_0(m_reset_lost_obj, m_reset_lost);

static mp_obj_t m_set_bp(mp_obj_t fun_in, mp_obj_t ip_in) {
    const void *fb = (const void *)MP_OBJ_TO_PTR(fun_in);
    uint16_t ipo = (uint16_t)mp_obj_get_int(ip_in);
    for (int i = 0; i < MAX_BPS; i++) {
        if (!bp_table[i].active) {
            bp_table[i].fun_bc = fb;
            bp_table[i].ip_off = ipo;
            bp_table[i].active = 1;
            mp_dbg_bp_count++;
            return mp_obj_new_int(i);
        }
    }
    mp_raise_msg(&mp_type_RuntimeError, MP_ERROR_TEXT("bp table full"));
}
static MP_DEFINE_CONST_FUN_OBJ_2(m_set_bp_obj, m_set_bp);

static mp_obj_t m_clear_bp(mp_obj_t slot_in) {
    int s = mp_obj_get_int(slot_in);
    if (s < 0 || s >= MAX_BPS) mp_raise_ValueError(MP_ERROR_TEXT("slot"));
    if (bp_table[s].active) {
        bp_table[s].active = 0;
        if (mp_dbg_bp_count > 0) mp_dbg_bp_count--;
    }
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_1(m_clear_bp_obj, m_clear_bp);

static mp_obj_t m_list_bp(void) {
    mp_obj_t list = mp_obj_new_list(0, NULL);
    for (int i = 0; i < MAX_BPS; i++) {
        if (bp_table[i].active) {
            mp_obj_t t[3] = {
                mp_obj_new_int(i),
                mp_obj_new_int_from_uint((uintptr_t)bp_table[i].fun_bc),
                mp_obj_new_int(bp_table[i].ip_off),
            };
            mp_obj_list_append(list, mp_obj_new_tuple(3, t));
        }
    }
    return list;
}
static MP_DEFINE_CONST_FUN_OBJ_0(m_list_bp_obj, m_list_bp);

static mp_obj_t m_is_paused(void) { return mp_obj_new_bool(mp_dbg_paused); }
static MP_DEFINE_CONST_FUN_OBJ_0(m_is_paused_obj, m_is_paused);

static mp_obj_t m_paused_info(void) {
    if (!mp_dbg_paused) return mp_const_none;
    mp_obj_t t[2] = {
        mp_obj_new_int_from_uint((uintptr_t)paused_fun_bc),
        mp_obj_new_int(paused_ip_off),
    };
    return mp_obj_new_tuple(2, t);
}
static MP_DEFINE_CONST_FUN_OBJ_0(m_paused_info_obj, m_paused_info);

static mp_obj_t m_resume(void) { mp_dbg_paused = 0; return mp_const_none; }
static MP_DEFINE_CONST_FUN_OBJ_0(m_resume_obj, m_resume);

static const mp_rom_map_elem_t dbg_module_globals_table[] = {
    { MP_ROM_QSTR(MP_QSTR___name__),     MP_ROM_QSTR(MP_QSTR_dbg) },
    { MP_ROM_QSTR(MP_QSTR_trace_on),     MP_ROM_PTR(&m_trace_on_obj) },
    { MP_ROM_QSTR(MP_QSTR_trace_off),    MP_ROM_PTR(&m_trace_off_obj) },
    { MP_ROM_QSTR(MP_QSTR_trace_func),   MP_ROM_PTR(&m_trace_func_obj) },
    { MP_ROM_QSTR(MP_QSTR_target_info),  MP_ROM_PTR(&m_target_info_obj) },
    { MP_ROM_QSTR(MP_QSTR_mute),         MP_ROM_PTR(&m_mute_obj) },
    { MP_ROM_QSTR(MP_QSTR_unmute),       MP_ROM_PTR(&m_unmute_obj) },
    { MP_ROM_QSTR(MP_QSTR_read_trace),   MP_ROM_PTR(&m_read_trace_obj) },
    { MP_ROM_QSTR(MP_QSTR_lost_count),   MP_ROM_PTR(&m_lost_count_obj) },
    { MP_ROM_QSTR(MP_QSTR_reset_lost),   MP_ROM_PTR(&m_reset_lost_obj) },
    { MP_ROM_QSTR(MP_QSTR_set_bp),       MP_ROM_PTR(&m_set_bp_obj) },
    { MP_ROM_QSTR(MP_QSTR_clear_bp),     MP_ROM_PTR(&m_clear_bp_obj) },
    { MP_ROM_QSTR(MP_QSTR_list_bp),      MP_ROM_PTR(&m_list_bp_obj) },
    { MP_ROM_QSTR(MP_QSTR_is_paused),    MP_ROM_PTR(&m_is_paused_obj) },
    { MP_ROM_QSTR(MP_QSTR_paused_info),  MP_ROM_PTR(&m_paused_info_obj) },
    { MP_ROM_QSTR(MP_QSTR_resume),       MP_ROM_PTR(&m_resume_obj) },
};
static MP_DEFINE_CONST_DICT(dbg_module_globals, dbg_module_globals_table);

const mp_obj_module_t mp_module_dbg = {
    .base = { &mp_type_module },
    .globals = (mp_obj_dict_t *)&dbg_module_globals,
};

MP_REGISTER_MODULE(MP_QSTR_dbg, mp_module_dbg);
EOF

# ---- 3. Sanity checks -------------------------------------------------------
grep -q 'set_bp' "$MPY_DIR/py/moddbg.c"        || { echo "FAIL: set_bp missing"; exit 1; }
grep -q 'emit_bp_hit' "$MPY_DIR/py/moddbg.c"   || { echo "FAIL: emit_bp_hit missing"; exit 1; }
grep -q 'mp_dbg_bp_count' "$MPY_DIR/py/moddbg.h" || { echo "FAIL: bp_count decl missing"; exit 1; }
echo "    0004 applied OK"
