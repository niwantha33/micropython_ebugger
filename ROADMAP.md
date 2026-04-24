# Roadmap

Phased plan. Each phase ends with something testable. Don't start a phase
until the previous one is green.

## Phase 0 — Scaffolding  *(done)*

- [x] Create repo layout
- [x] Write README
- [x] Write protocol SPEC (v0 draft)
- [x] Decide on build host — WSL2 Ubuntu 24.04

## Phase 1 — Baseline firmware  *(done)*

- [x] Install WSL + RP2 build toolchain
- [x] Clone MicroPython (plain clone for now; convert to submodule in a later cleanup)
- [x] Build `RPI_PICO2_W` port unmodified
- [x] Flash to Pico 2 W, REPL confirmed working

Gotchas worth recording in `firmware/BUILD.md` later:
- Needed `PICOTOOL_FORCE_FETCH_FROM_GIT=1` — pico-sdk 2.x insists on picotool 2.1.1.
- WSL inherits Windows PATH; a Windows `picotool.exe` on `/mnt/c` was being
  picked up by CMake. Build with stripped PATH:
  `PATH=/usr/local/bin:/usr/bin:/bin PICOTOOL_FORCE_FETCH_FROM_GIT=1 make ...`

## Phase 2 — Second USB-CDC channel  *(done)*

- [x] Use `usb.device.cdc.CDCInterface` (runtime USB device) — no C patch needed
- [x] `boot.py` registers second CDC at startup
- [x] `echo_on_board.run()` echoes bytes on CDC1
- [x] `echo_test.py` from PC: PASS — round trip confirmed

Notes:
- `usb-device-cdc` package installed via `mpremote mip install` (not frozen).
- Later, to make it always-on without user setup, we'll freeze it into the
  firmware build or replace with a C-level static descriptor patch.
- Safety: boot.py has a 3s Ctrl-C window + try/except, prevents bricking.

## Phase 3 — Trace hook (read-only)

### 3a — Hook into VM  *(done)*
- [x] New module `py/moddbg.c` with ring buffer + Python API
- [x] `MP_DBG_HOOK(ip)` call added to `DISPATCH` macro in `py/vm.c`
- [x] `dbg.trace_on/off/read_trace/lost_count` exposed to Python
- [x] Test: `trace_test.run()` captures opcodes — PASS

Notes:
- Event format is crude 3 bytes `[ip&0xff, opcode, 0xff]` — sentinel will go
  when protocol stabilizes. Enough to prove the hook fires.
- Fast path when disabled: single load + branch per opcode.

### 3b — Wire to CDC1  *(done)*
- [x] `_thread` background pump drains C ring buffer → `dbg_cdc`
- [x] `trace_reader.py` on Windows parses + prints 3-byte events
- [x] End-to-end stream verified — 300k+ events captured

### 3c — Scoping  *(done)*
- [x] `dbg.trace_func(fun)` scopes tracing to one function via `code_state->fun_bc`
- [x] `dbg.mute()/unmute()` for pump re-entry
- [x] Test: `target()` traced alone, 12 events, 0 lost

### 3d — Proper encoding  *(done)*
- [x] 4-byte events: `[ip_lo, ip_hi, opcode, 0xFF]`
- [x] ip is real 16-bit offset from `code_state->fun_bc->bytecode`
- [x] `dbg.target_info()` returns fun_bc + bytecode pointers
- [x] Host reader decodes and resyncs on sentinel
- [x] Test: offsets 0x0008–0x0013, 0 lost — PASS

Deferred for later:
- Multi-function tracing (stream multiplexed with func id)
- Host-side disassembler using `showbc.c` logic (needed before a GUI can
  highlight source lines — but Phase 4 breakpoints don't need it)

## Phase 4 — Breakpoints

### 4.1 — Pause & continue  *(done)*
- [x] BP via per-opcode check in existing hook (no opcode patching yet)
- [x] Framed wire protocol: `[0xAA, type, len, payload]`
      — trace (0x01), bp_hit (0x02), continue cmd (0x10)
- [x] `dbg.set_bp / clear_bp / list_bp / is_paused / paused_info / resume`
- [x] VM busy-waits on `mp_dbg_paused`; pump on the other core flips it
- [x] `bp_cli.py continue` sends resume frame
- [x] End-to-end: bp hits, REPL freezes, host resumes — PASS

### 4.2 — Step (next)  *(impl)*
- [x] `dbg.step()` — resume and pause again at the next opcode
- [x] Host cmd 0x11 = step
- [x] State: paused → stepping → paused

### 4.3 — Opcode patching (deferred)
Upgrade to `MP_BC_TRAP_BP` opcode patching for zero-overhead when no
breakpoint is being hit. Only if profiling says we need it.

## Phase 5 — Step and inspect

- [x] Step-one-opcode (single step)
- [x] Step-over (current `step`, fun_bc-filtered)
- [x] Step-in (`step_in`, any frame)
- [x] Step-out (`step_out`, pauses when we leave current frame)
- [x] Dump locals (walk `mp_code_state_t->state`)
- [x] Dump value stack via `frame_info` (exposes n_state + sp_off)
- [ ] Named locals (decode bytecode prelude)  *(deferred)*
- [ ] Handle coroutine frames correctly (see asyncio notes)

## Phase 6 — CLI polish

- [ ] `dbg` CLI with readline
- [ ] Source-line ↔ ip_offset mapping (via `.mpy` debug info)
- [ ] Pretty-print variables using `mp_obj_print_helper`

## Phase 7 — Hardware bridge v1

Goal: a physical USB tool that sits between board and PC. Adds timestamping,
electrical isolation, and — later — JTAG passthrough.

- [ ] RP2040-based bridge design
- [ ] Firmware: pass through CDC1, add timestamp to every frame
- [ ] Enclosure

## Phase 8 — More boards

- [ ] ESP32-S3
- [ ] STM32 (one variant)

## Phase 9 — GUI

- [ ] VS Code extension using the JSON protocol
- [ ] Or standalone Tauri app

---

## Non-goals for v1

- Multi-board debugging
- Debugging native code (JTAG integration comes in Phase 7+)
- Windows-native GUI (CLI is enough to prove the concept)
- Performance tuning (correctness first)
