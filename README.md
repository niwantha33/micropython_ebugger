# MicroPython Live Debugger

A live, bytecode-level debugger for MicroPython on the Raspberry Pi Pico 2 W.
Set breakpoints, step through code, inspect named locals, view the call stack,
and use **conditional breakpoints** — all on a running board, over USB, with a
VS Code UI.

No JTAG. No `sys.settrace`. No print-debugging.

## Features

- **Breakpoints** — click in the gutter, just like a real debugger
- **Step over / step in / step out / continue**
- **Named locals** — see `x = 32, y = 30, z = 62` not raw stack slots
- **Call stack** with function names, click a frame to jump to source
- **Conditional breakpoints** — `b > 1`, supports Python `and / or / not`
- **Live line highlight** of the paused line
- **Auto-upload** of debugger files via "Start Debug" button
- **Robust port handling** — friendly errors when COM port is busy
- **Two USB CDCs** — debugger frames on CDC1, REPL stays untouched on CDC0

## Target hardware

**Raspberry Pi Pico 2 W (RP2350).** Dual USB-CDC built in.

ESP32-S3 port planned for v0.2.

## Quick start

### 1. Flash the firmware

1. Hold **BOOTSEL**, plug Pico USB in — it appears as `RP2350` drive
2. Drag `firmware.uf2` onto it
3. Pico reboots automatically

### 2. Install the VS Code extension

```
code --install-extension micropython-studio-1.0.0.vsix
```

Or in VS Code: `Ctrl+Shift+P` → **Install from VSIX**.

### 3. First debug session

1. Open a `.py` file with a function (`def foo(): ...`)
2. Click the **▶ Start Debug** button in the status bar
3. Click in the gutter to set a breakpoint
4. In the REPL: `import yourfile; yourfile.foo()`
5. Execution pauses at your breakpoint. The panel shows locals + call stack.

## How it works

We patch the MicroPython VM (`py/vm.c`) with a one-line hook in the bytecode
dispatch loop. The hook calls into a new module `moddbg.c` which:

- Holds the breakpoint table (slot → ip) and stepping flags
- Snapshots a shadow call stack at pause time
- Exposes `dbg.set_bp / clear_bp / locals / frame_info / call_stack / resume / step / step_in / step_out` to Python

A Python-side **trace pump** (`trace_pump.py`) runs in a second thread, drains
debug frames from the C ring buffer to a dedicated USB-CDC interface, and
parses commands from the host.

The VS Code extension talks to that CDC port via `dbg_bridge.py` (pyserial),
parses event frames (`bp_hit`, `reply`), and renders the UI. Conditional
breakpoints are evaluated **client-side in the extension** — when a BP fires
with a condition, the extension fetches locals, evaluates `b > 1` in JS, and
either pauses or silently resumes.

## Building from source

Requires WSL (or Linux/macOS) with the Pico SDK toolchain installed.

```bash
git clone --recursive https://github.com/niwantha33/micropython_live_debugger
cd micropython-debugger
export MPY_DIR=$HOME/micropython
git clone --recursive https://github.com/micropython/micropython.git $MPY_DIR

# Apply all patches
for p in firmware/patches/0*.sh; do bash "$p"; done

# Build
cd $MPY_DIR/ports/rp2
make BOARD=RPI_PICO2_W -j4
# Output: build-RPI_PICO2_W/firmware.uf2
```

## Repo layout

```
firmware/
  patches/         16 numbered .sh patches that fork MicroPython
host/
  trace_pump.py    Runs on the Pico, pumps debug frames over CDC1
  dbgref.py        Holds reference to CDC1 device
target/
  nested.py        Test program (3-level call stack)
protocol/          Wire format spec
micropythondebugger/   VS Code extension source (mirror)
firmware.uf2       Pre-built firmware for Pico 2 W
```

## Wire protocol

Frames are `[0xAA][type][len][payload]`.

| Type | Direction   | Meaning           |
|------|-------------|-------------------|
| 0x01 | board → pc  | trace event       |
| 0x02 | board → pc  | bp_hit            |
| 0x03 | board → pc  | reply text        |
| 0x10 | pc → board  | continue          |
| 0x11 | pc → board  | step              |
| 0x12 | pc → board  | locals            |
| 0x13 | pc → board  | step_in           |
| 0x14 | pc → board  | step_out          |
| 0x15 | pc → board  | set_bp_line       |
| 0x16 | pc → board  | clear_bp          |
| 0x17 | pc → board  | call_stack        |

## Status

**v1.0.1 — bugfix release.** Stable end-to-end on Raspberry Pi Pico 2 W.

### v1.0.1 changes
- Upload corruption fixed (raw-paste flow control)
- Download corruption fixed (HEXLEN/HEXSTART markers + chunked print)
- Single-file and folder uploads now share the reliable one-shot path
- mip PC-side fallback works again on devices without WiFi
- Shell terminal no longer leaks venv-activate text into the REPL

Verified working with:
- Synchronous code (loops, function calls, recursion)
- **Async code** — breakpoints hit inside `asyncio` coroutines
- Multi-frame call stacks (3+ levels deep)
- Conditional breakpoints with Python operators

Known limitations:
- Step-in across function boundaries doesn't update the source highlight
  (only known BP locations are mapped to lines)
- BPs are limited by firmware slot count (default 8)
- No watch expressions yet
- Only one breakpoint condition at a time (no hit-counts)
- VS Code Python extension auto-activates venv into terminals — disabled
  workspace setting on first run

## Roadmap

See [ROADMAP.md](ROADMAP.md). Next:
- ESP32-S3 port
- Watch expressions
- Persistent device console (one port owner, no contention)
- Variable edit (poke value into running program)

## License

MIT — see [LICENSE](LICENSE).

If you make changes or derivative work, please let me know:
- Email: niwantha33@gmail.com
- Repo: https://github.com/niwantha33/micropython_live_debugger

So improvements can be folded back upstream.

## Credits

Built on MicroPython by Damien George and contributors.
