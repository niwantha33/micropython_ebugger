# trace_test.py — run on the Pico REPL to verify the trace hook fires.
#
# Usage at the Pico's REPL (>>>):
#     import trace_test
#     trace_test.run()

import dbg


def run():
    print("enabling trace ...")
    dbg.trace_on()

    # Do a tiny bit of work — each opcode should push 3 bytes.
    x = 1 + 2
    y = x * 3
    z = y - 1

    dbg.trace_off()

    # Drain what the hook pushed.
    total = b""
    while True:
        chunk = dbg.read_trace(256)
        if not chunk:
            break
        total += chunk

    lost = dbg.lost_count()
    events = len(total) // 3

    print("bytes captured:", len(total))
    print("events (3 bytes each):", events)
    print("lost:", lost)

    # Pretty-print first 10 events
    for i in range(min(events, 10)):
        ip_lo, op, sep = total[i*3], total[i*3 + 1], total[i*3 + 2]
        print("  ip&0xff={:02x}  op={:3d}  sep={:02x}".format(ip_lo, op, sep))

    if events > 0:
        print("PASS — hook is firing.")
    else:
        print("FAIL — no events captured.")
