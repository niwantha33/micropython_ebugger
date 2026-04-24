# echo_on_board.py — run this FROM THE REPL on the Pico 2 W.
#
# Usage at the Pico's REPL (>>>):
#     import echo_on_board
#     echo_on_board.run()

import time


def run():
    cdc = dbg_cdc  # comes from builtins, set by boot.py
    print("Echo server running on CDC1. Ctrl-C to stop.")
    while True:
        data = cdc.read(64)
        if data:
            cdc.write(b"echo: " + data)
        time.sleep_ms(10)
