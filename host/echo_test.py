# echo_test.py — run this ON WINDOWS to verify the second CDC works.
#
# Requires: pip install pyserial
#
# Usage:
#     python echo_test.py COM8       (replace COM8 with the second port)

import sys
import time
import serial


def main():
    if len(sys.argv) != 2:
        print("usage: python echo_test.py <COMx>")
        sys.exit(1)

    port = sys.argv[1]
    print(f"Opening {port} ...")
    ser = serial.Serial(port, 115200, timeout=1)
    time.sleep(0.5)  # let the port settle

    msg = b"hello from PC\n"
    print(f"TX: {msg!r}")
    ser.write(msg)
    ser.flush()

    time.sleep(0.2)
    reply = ser.read(256)
    print(f"RX: {reply!r}")

    if b"echo:" in reply and b"hello from PC" in reply:
        print("PASS — second CDC works end to end.")
    else:
        print("FAIL — no echo or unexpected data. Check that echo_on_board.run() is running on the Pico.")

    ser.close()


if __name__ == "__main__":
    main()
