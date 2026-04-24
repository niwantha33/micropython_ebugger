#!/usr/bin/env bash
# Patch 0001 — Debug hook + `dbg` module
#
# Adds:
#   - py/moddbg.h, py/moddbg.c   (new files: ring buffer + Python API)
#   - One line in py/vm.c's DISPATCH macro to call the hook
#   - One line in py/py.cmake to compile moddbg.c
#
# After this patch, the `dbg` module is built into MicroPython with:
#   dbg.trace_on()
#   dbg.trace_off()
#   dbg.read_trace(n) -> bytes    (up to n bytes, each trace event is 3 bytes)
#   dbg.lost_count() -> int
#
# Trace event format (3 bytes per opcode): [ip_low_byte, opcode, 0xFF]
# This is crude — Phase 3 uses it just to prove the hook fires.

set -euo pipefail

MPY_DIR="${MPY_DIR:-$HOME/micropython}"

# ---- 1. Write py/moddbg.h ---------------------------------------------------
cat > "$MPY_DIR/py/moddbg.h" <<'EOF'
// moddbg.h — live debugger hook interface (Phase 3)
#ifndef MICROPY_INCLUDED_PY_MODDBG_H
#define MICROPY_INCLUDED_PY_MODDBG_H

#include "py/mpconfig.h"
#include <stdint.h>

extern volatile uint8_t mp_dbg_trace_enabled;

void mp_dbg_hook(const byte *ip);

#define MP_DBG_HOOK(ip) do { \
    if (mp_dbg_trace_enabled) mp_dbg_hook(ip); \
} while (0)

#endif // MICROPY_INCLUDED_PY_MODDBG_H
EOF

# ---- 2. Write py/moddbg.c ---------------------------------------------------
cat > "$MPY_DIR/py/moddbg.c" <<'EOF'
// moddbg.c — live debugger module (Phase 3)
//
// Exposes a small C ring buffer to Python. VM's DISPATCH macro pushes
// a 3-byte event per opcode when tracing is on. Python drains via
// dbg.read_trace(n).

#include "py/obj.h"
#include "py/runtime.h"
#include "py/moddbg.h"

#define DBG_RING_SIZE 4096
static uint8_t dbg_ring[DBG_RING_SIZE];
static volatile uint16_t dbg_head = 0;
static volatile uint16_t dbg_tail = 0;
static volatile uint32_t dbg_lost = 0;

volatile uint8_t mp_dbg_trace_enabled = 0;

static inline void dbg_push(uint8_t b) {
    uint16_t next = (uint16_t)((dbg_head + 1) % DBG_RING_SIZE);
    if (next == dbg_tail) {
        dbg_lost++;
        return;
    }
    dbg_ring[dbg_head] = b;
    dbg_head = next;
}

void mp_dbg_hook(const byte *ip) {
    // 3-byte event: [ip & 0xFF, opcode, 0xFF sentinel]
    // Real encoding will come in a later patch.
    dbg_push((uint8_t)((uintptr_t)ip & 0xFF));
    dbg_push(*ip);
    dbg_push(0xFF);
}

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

static const mp_rom_map_elem_t dbg_module_globals_table[] = {
    { MP_ROM_QSTR(MP_QSTR___name__),    MP_ROM_QSTR(MP_QSTR_dbg) },
    { MP_ROM_QSTR(MP_QSTR_trace_on),    MP_ROM_PTR(&mod_dbg_trace_on_obj) },
    { MP_ROM_QSTR(MP_QSTR_trace_off),   MP_ROM_PTR(&mod_dbg_trace_off_obj) },
    { MP_ROM_QSTR(MP_QSTR_read_trace),  MP_ROM_PTR(&mod_dbg_read_trace_obj) },
    { MP_ROM_QSTR(MP_QSTR_lost_count),  MP_ROM_PTR(&mod_dbg_lost_count_obj) },
};
static MP_DEFINE_CONST_DICT(dbg_module_globals, dbg_module_globals_table);

const mp_obj_module_t mp_module_dbg = {
    .base = { &mp_type_module },
    .globals = (mp_obj_dict_t *)&dbg_module_globals,
};

MP_REGISTER_MODULE(MP_QSTR_dbg, mp_module_dbg);
EOF

# ---- 3. Edit py/vm.c — add include + hook call in DISPATCH macro ------------
VM_C="$MPY_DIR/py/vm.c"

# 3a. Add #include "py/moddbg.h" after the first existing py/ include.
if ! grep -q '"py/moddbg.h"' "$VM_C"; then
    # Insert after the #include "py/runtime.h" line (stable anchor).
    sed -i '0,/#include "py\/runtime\.h"/{s|#include "py/runtime\.h"|#include "py/runtime.h"\n#include "py/moddbg.h"|}' "$VM_C"
fi

# 3b. Insert MP_DBG_HOOK(ip) at the top of the computed-goto DISPATCH macro.
#     We find the line `        TRACE(ip); \` that is inside DISPATCH and
#     insert our hook line above it. The DISPATCH macro is the first
#     occurrence of that pattern in the file.
if ! grep -q 'MP_DBG_HOOK(ip)' "$VM_C"; then
    # Use awk for a single targeted insertion on the first matching TRACE(ip) line.
    awk '
        !done && /^        TRACE\(ip\); \\$/ {
            print "        MP_DBG_HOOK(ip); \\";
            done = 1;
        }
        { print }
    ' "$VM_C" > "$VM_C.tmp" && mv "$VM_C.tmp" "$VM_C"
fi

# ---- 4. Add moddbg.c to py/py.cmake -----------------------------------------
PY_CMAKE="$MPY_DIR/py/py.cmake"
if ! grep -q 'moddbg\.c' "$PY_CMAKE"; then
    # Insert moddbg.c alphabetically near modmath.c (stable neighbour).
    sed -i 's|    \${MICROPY_PY_DIR}/modmath\.c|    ${MICROPY_PY_DIR}/moddbg.c\n    ${MICROPY_PY_DIR}/modmath.c|' "$PY_CMAKE"
fi

# ---- 5. Sanity checks -------------------------------------------------------
grep -q 'MP_DBG_HOOK(ip)' "$VM_C"              || { echo "FAIL: DISPATCH edit"; exit 1; }
grep -q '"py/moddbg.h"' "$VM_C"                || { echo "FAIL: vm.c include"; exit 1; }
grep -q 'moddbg\.c' "$PY_CMAKE"                || { echo "FAIL: py.cmake edit"; exit 1; }
test -f "$MPY_DIR/py/moddbg.c"                 || { echo "FAIL: moddbg.c missing"; exit 1; }
test -f "$MPY_DIR/py/moddbg.h"                 || { echo "FAIL: moddbg.h missing"; exit 1; }
echo "    0001 applied OK"
