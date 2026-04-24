# Wire Protocol — v0.2 (as implemented)

Binary framed protocol between **firmware** (MicroPython on the board) and
**host** (Python client on PC) over a dedicated USB-CDC interface (CDC1).
REPL stays on CDC0, untouched.

## Transport

- USB-CDC, 115200/8N1 (baud rate is ignored — CDC is framed).
- No JSON. Raw binary frames.

## Frame format

Every frame:

```
[0xAA]  [type]  [len]  [payload(len) ...]
```

- `0xAA` — sync byte; host/firmware resync by scanning for it.
- `type` — 1 byte.
- `len`  — 1 byte, 0..255 payload length.

## Firmware → Host (events)

| type | name      | payload                             |
|------|-----------|-------------------------------------|
| 0x01 | trace     | `ip_lo ip_hi op`  (3B)              |
| 0x02 | bp_hit    | `ip_lo ip_hi`     (2B)              |
| 0x03 | reply     | ASCII text (response to query cmd)  |

`bp_hit` is also used for step pauses — semantically "VM paused at ip".

## Host → Firmware (commands)

| type | name            | payload |
|------|-----------------|---------|
| 0x10 | continue        | —       |
| 0x11 | step (over)     | —       |
| 0x12 | get_locals      | —       |
| 0x13 | step_in         | —       |
| 0x14 | step_out        | —       |

Commands currently have 0-length payload. `get_locals` returns a 0x03 reply
frame with `repr()`-formatted locals + frame_info.

## Firmware Python API (`import dbg`)

Exposed by the custom firmware:

- `dbg.trace_on() / trace_off()`
- `dbg.trace_func(fn)` — scope trace to one function (pass `None` to clear)
- `dbg.target_info()` — fun_bc + bytecode pointers of current trace target
- `dbg.mute() / unmute()` — suppress trace (used by host pump to avoid self-trace)
- `dbg.read_trace(n)` — pop up to n bytes from ring
- `dbg.lost_count() / reset_lost()`
- `dbg.set_bp(fn, ip_off) -> slot`
- `dbg.clear_bp(slot)`
- `dbg.list_bp()` — `[(slot, fun_bc, ip_off), ...]`
- `dbg.is_paused()` — bool
- `dbg.paused_info()` — `(fun_bc, ip_off)` or `None`
- `dbg.resume()` — continue
- `dbg.step()` — single-step in same frame (step-over)
- `dbg.step_in()` — single-step into any frame
- `dbg.step_out()` — run until we leave current frame
- `dbg.locals()` — list of `state[]` of paused frame, or `None`
- `dbg.frame_info()` — `(n_state, sp_off, ip_off)` or `None`

## Lifecycle

```
board boot
   │
   ▼ boot.py installs 2nd CDC as dbgref.cdc
   │
   ▼ user starts trace_pump — pump thread on core1 drains ring → CDC
   │   and reads commands from CDC
   │
   ▼ user sets BPs, runs target
   │
   ▼ BP fires inside VM on core0 → busy-wait on mp_dbg_paused
   │   evt.bp_hit sent to host
   │
   ▼ host sends cmd.continue/step/step_in/step_out/get_locals
   │   pump (core1) processes → flips flags
   │
   ▼ VM busy-wait exits, execution resumes
```

## Design notes

- **Pending/arm pattern** for step-in: pump sets `stepping_in_pending`,
  core0's busy-wait exit promotes it to `stepping_in`. Prevents the pump
  thread from catching its own stepping flag.
- **Mute gate** on step-in and step-out: pump's own bytecode runs muted,
  so it never triggers a stepping pause.
- **Step-over** uses `fun_bc == paused_fun_bc` filter — implicitly mute-safe.

## Open questions

- Named locals (decode bytecode prelude) — deferred.
- Multi-function tracing (tag events with func id) — deferred.
- Host-side bytecode disassembly (port showbc.c logic) — deferred until GUI.
- Binary encoding of locals (instead of repr text) — deferred.
