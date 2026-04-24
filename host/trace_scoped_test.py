# trace_scoped_test.py — run from the Pico REPL.
#
# Usage at the Pico's REPL (>>>):
#     import trace_pump; trace_pump.start()
#     import trace_scoped_test
#     trace_scoped_test.run()

import dbg


def target():
    x = 1 + 2
    y = x * 3
    z = y - 1
    return z


def run():
    dbg.reset_lost()
    dbg.trace_func(target)

    info = dbg.target_info()
    print("target_info:", info)

    dbg.trace_on()
    result = target()
    dbg.trace_off()
    dbg.trace_func(None)

    print("target returned:", result)
    print("lost:", dbg.lost_count())
    print("watch the trace_reader window — ip offsets should grow from 0.")
