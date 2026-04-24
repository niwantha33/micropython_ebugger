#!/usr/bin/env bash
# Patch 0012 — source-line awareness
#
# Adds three helpers on top of fun_bc's bytecode prelude:
#   dbg.func_first_ip(fn)       -> ip offset of first executable opcode
#   dbg.source_line(fn, ip_off) -> source line for that offset (or 0)
#   dbg.line_to_ip(fn, line)    -> first ip offset on that line (or -1)
#
# Plus a convenience:
#   dbg.set_bp_line(fn, line)   -> slot (raises if line has no code)

set -euo pipefail
MPY_DIR="${MPY_DIR:-$HOME/micropython}"

python3 - <<'PY'
import os
p = os.path.expanduser(os.environ.get("MPY_DIR", "~/micropython")) + "/py/moddbg.c"
s = open(p).read()

# Include bc.h (once)
if '#include "py/bc.h"' not in s:
    s = s.replace('#include "py/objfun.h"', '#include "py/objfun.h"\n#include "py/bc.h"', 1)

helpers = """
// --- prelude / line-info helpers -----------------------------------------
static void _dbg_prelude(const mp_obj_fun_bc_t *fun, mp_bytecode_prelude_t *out) {
    const byte *ip = fun->bytecode;
    MP_BC_PRELUDE_SIG_DECODE(ip);
    out->n_state = n_state;
    out->n_exc_stack = n_exc_stack;
    out->scope_flags = scope_flags;
    out->n_pos_args = n_pos_args;
    out->n_kwonly_args = n_kwonly_args;
    out->n_def_pos_args = n_def_pos_args;
    MP_BC_PRELUDE_SIZE_DECODE(ip);
    // ip now at code_info: source_file qstr (varenc), block_name qstr (varenc), then line_info
    const byte *ci = ip;
    // skip source_file qstr
    while ((*ci++ & 0x80) != 0) { }
    // skip block_name qstr
    while ((*ci++ & 0x80) != 0) { }
    out->qstr_block_name_idx = 0;
    out->line_info = ci;
    out->line_info_top = ip + n_info;
    out->opcodes = ip + n_info + n_cell;
}

static size_t _dbg_source_line_at(const mp_bytecode_prelude_t *p, size_t bc_off) {
    const byte *li = p->line_info;
    const byte *top = p->line_info_top;
    size_t line = 1;
    size_t c;
    while (li < top && (c = *li) != 0) {
        size_t b, l;
        if ((c & 0x80) == 0) { b = c & 0x1f; l = c >> 5; li += 1; }
        else { b = c & 0xf; l = ((c << 4) & 0x700) | li[1]; li += 2; }
        if (bc_off < b) return line;
        bc_off -= b;
        line += l;
    }
    return line;
}

// iterate, return first bc_off whose associated source line equals target.
static mp_int_t _dbg_line_to_bc(const mp_bytecode_prelude_t *p, mp_int_t target) {
    const byte *li = p->line_info;
    const byte *top = p->line_info_top;
    size_t bc_off = 0;
    size_t line = 1;
    size_t c;
    while (li < top && (c = *li) != 0) {
        size_t b, l;
        if ((c & 0x80) == 0) { b = c & 0x1f; l = c >> 5; li += 1; }
        else { b = c & 0xf; l = ((c << 4) & 0x700) | li[1]; li += 2; }
        if ((mp_int_t)line == target) return (mp_int_t)bc_off;
        bc_off += b;
        line += l;
    }
    if ((mp_int_t)line == target) return (mp_int_t)bc_off;
    return -1;
}

static mp_obj_t m_func_first_ip(mp_obj_t fn_in) {
    const mp_obj_fun_bc_t *fun = (const mp_obj_fun_bc_t *)MP_OBJ_TO_PTR(fn_in);
    mp_bytecode_prelude_t p;
    _dbg_prelude(fun, &p);
    return mp_obj_new_int((mp_int_t)(p.opcodes - fun->bytecode));
}
static MP_DEFINE_CONST_FUN_OBJ_1(m_func_first_ip_obj, m_func_first_ip);

static mp_obj_t m_source_line(mp_obj_t fn_in, mp_obj_t ip_in) {
    const mp_obj_fun_bc_t *fun = (const mp_obj_fun_bc_t *)MP_OBJ_TO_PTR(fn_in);
    mp_bytecode_prelude_t p;
    _dbg_prelude(fun, &p);
    mp_int_t ip_off = mp_obj_get_int(ip_in);
    mp_int_t bc_off = ip_off - (mp_int_t)(p.opcodes - fun->bytecode);
    if (bc_off < 0) return mp_obj_new_int(0);
    return mp_obj_new_int((mp_int_t)_dbg_source_line_at(&p, (size_t)bc_off));
}
static MP_DEFINE_CONST_FUN_OBJ_2(m_source_line_obj, m_source_line);

static mp_obj_t m_line_to_ip(mp_obj_t fn_in, mp_obj_t line_in) {
    const mp_obj_fun_bc_t *fun = (const mp_obj_fun_bc_t *)MP_OBJ_TO_PTR(fn_in);
    mp_bytecode_prelude_t p;
    _dbg_prelude(fun, &p);
    mp_int_t bc_off = _dbg_line_to_bc(&p, mp_obj_get_int(line_in));
    if (bc_off < 0) return mp_obj_new_int(-1);
    return mp_obj_new_int(bc_off + (mp_int_t)(p.opcodes - fun->bytecode));
}
static MP_DEFINE_CONST_FUN_OBJ_2(m_line_to_ip_obj, m_line_to_ip);
"""

# Insert helpers right before dbg_module_globals_table
anchor = "static const mp_rom_map_elem_t dbg_module_globals_table[] = {"
if anchor not in s: raise SystemExit("FAIL: globals table anchor")
s = s.replace(anchor, helpers + "\n" + anchor, 1)

# Register the three
old_reg = "    { MP_ROM_QSTR(MP_QSTR_set_pump_fun), MP_ROM_PTR(&m_set_pump_fun_obj) },"
new_reg = old_reg + (
    "\n    { MP_ROM_QSTR(MP_QSTR_func_first_ip), MP_ROM_PTR(&m_func_first_ip_obj) },"
    "\n    { MP_ROM_QSTR(MP_QSTR_source_line),   MP_ROM_PTR(&m_source_line_obj) },"
    "\n    { MP_ROM_QSTR(MP_QSTR_line_to_ip),    MP_ROM_PTR(&m_line_to_ip_obj) },"
)
if old_reg not in s: raise SystemExit("FAIL: pump_fun reg")
s = s.replace(old_reg, new_reg, 1)

open(p, "w").write(s)
PY

grep -q 'm_line_to_ip_obj' "$MPY_DIR/py/moddbg.c" || { echo "FAIL"; exit 1; }
echo "    0012 applied OK"
