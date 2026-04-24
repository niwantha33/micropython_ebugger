# bp_test.py — run FROM THE PICO REPL.
#
# Sets a breakpoint inside target(), calls it, VM pauses, you send
# `continue` from Windows, execution resumes and prints the result.
#
# Usage:
#   1. On the board:
#         >>> import trace_pump; trace_pump.start()
#         >>> import bp_test
#         >>> bp_test.run()
#      (The board will PAUSE. REPL looks frozen — it's waiting.)
#
#   2. On Windows, in a second terminal:
#         python bp_cli.py COM3 continue
#
#   3. The board resumes and prints "target returned: 8".

import dbg


def helper(a):
    return a + 1


def target():
    x = 1 + 2
    y = helper(x)
    z = y - 1
    return z


def run():
    # set bp at the first opcode inside target() — ip offset 0x0008 per the
    # earlier trace run. Adjust if your bytecode layout differs.
    slot = dbg.set_bp(target, 0x0008)
    print("bp slot:", slot, "list:", dbg.list_bp())
    print("calling target() — should pause at first opcode ...")
    result = target()
    print("target returned:", result)
    dbg.clear_bp(slot)
