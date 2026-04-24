# trace_pump.py — runs on the Pico.
#
# Bidirectional:
#   - Drains the C ring buffer to dbg_cdc (trace + bp_hit events).
#   - Reads commands from dbg_cdc.
#         0xAA 0x10 0x00  = continue (resume from bp pause)
#
# Diagnostic counters (readable from REPL):
#   trace_pump.bytes_in     how many bytes read from cdc total
#   trace_pump.cmds         how many command frames parsed
#   trace_pump.continues    how many continue commands applied

import _thread
import time
import dbg

_running = False
bytes_in = 0
cmds = 0
continues = 0


def _pump():
    global _running, bytes_in, cmds, continues
    import builtins
    cdc = builtins.dbg_cdc
    cmd_buf = bytearray()

    while _running:
        dbg.mute()

        while True:
            data = dbg.read_trace(256)
            if not data:
                break
            try:
                cdc.write(data)
            except Exception:
                pass

        try:
            inc = cdc.read(64)
        except Exception:
            inc = None
        if inc:
            bytes_in += len(inc)
            cmd_buf.extend(inc)

        while len(cmd_buf) >= 3 and cmd_buf[0] == 0xAA:
            cmd_len = cmd_buf[2]
            total = 3 + cmd_len
            if len(cmd_buf) < total:
                break
            cmd_type = cmd_buf[1]
            cmds += 1
            if cmd_type == 0x10:
                dbg.resume()
                continues += 1
            cmd_buf[:] = cmd_buf[total:]
        while cmd_buf and cmd_buf[0] != 0xAA:
            cmd_buf.pop(0)

        dbg.unmute()
        time.sleep_ms(5)


def start():
    global _running
    if _running:
        print("trace_pump: already running")
        return
    _running = True
    _thread.start_new_thread(_pump, ())
    print("trace_pump: started")


def stop():
    global _running
    _running = False
    print("trace_pump: stopping")


def stats():
    print("bytes_in =", bytes_in, "cmds =", cmds, "continues =", continues)
