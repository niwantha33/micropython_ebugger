# MicroPython Live Debugger

A live, bytecode-level debugger for MicroPython — set breakpoints, step, inspect
variables on a running board, the way GDB works for C or pdb works for CPython.

## Why this exists

Stock MicroPython has no real debugger. `sys.settrace` is slow and limited.
JTAG debugs the C layer but is blind to Python-level state (frames, locals,
opcodes). This project fills that gap by patching the MicroPython VM itself.

## How it works (one paragraph)

We fork MicroPython and add a tiny hook inside the bytecode dispatch loop
(`py/vm.c`). Breakpoints are set by overwriting one byte of bytecode in RAM
with a new `MP_BC_TRAP_BP` opcode; when the VM hits it, the firmware sends a
frame to the host over a dedicated USB-CDC channel and blocks until the host
says "continue" or "step". The REPL keeps running on its own CDC channel,
untouched.

## Status

**Phase 0 — scaffolding.** No code that runs yet. See [ROADMAP.md](ROADMAP.md).

## Target hardware

- **v1**: Raspberry Pi Pico 2 W (RP2350). Dual USB-CDC built in, so no
  external hardware needed for the first proof of concept.
- **Later**: ESP32, STM32, and a dedicated USB bridge tool.

## Repo layout

```
firmware/    MicroPython submodule + our patches
host/        PC-side client (Python) that talks to the board
protocol/    Wire-format spec — single source of truth
ROADMAP.md   Phased plan, checkbox-style
```

## Design decisions (locked for v1)

| Decision        | Choice                          | Why                                      |
|-----------------|---------------------------------|------------------------------------------|
| Fork strategy   | Submodule + patch files         | Easy to rebase on upstream MicroPython   |
| Wire protocol   | JSON lines (one JSON per line)  | Human-readable during bring-up           |
| Transport       | Second USB-CDC interface        | REPL stays untouched on CDC0             |
| First target    | Pico 2 W only                   | No hardware tool needed to validate      |

These will change later (binary protocol, hardware bridge, more boards) but
not until v1 works end to end.
