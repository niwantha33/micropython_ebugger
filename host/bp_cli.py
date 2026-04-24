# bp_cli.py — host-side CLI for the debugger pump.
#
# Commands:
#   python bp_cli.py COM3 continue
#   python bp_cli.py COM3 ping      (sends nothing, opens/closes port)

import sys
import time
import serial


def open_port(port):
    # timeout lets reads not hang forever.
    # dtr/rts defaults sometimes toggle reset on CDC; set explicitly.
    ser = serial.Serial(
        port, 115200, timeout=0.2, write_timeout=1.0,
        dsrdtr=False, rtscts=False,
    )
    # Some Windows CDC stacks eat the first bytes after open. Small settle.
    time.sleep(0.1)
    return ser


def send_frame(port, cmd_type, name=None):
    ser = open_port(port)
    frame = bytes([0xAA, cmd_type, 0x00])
    for _ in range(3):
        ser.write(frame)
        ser.flush()
        time.sleep(0.02)
    time.sleep(0.2)
    ser.close()
    print(f"sent: {name or hex(cmd_type)} (x3)")


def send_continue(port):
    send_frame(port, 0x10, "continue")


def main():
    if len(sys.argv) < 3:
        print("usage: python bp_cli.py <COMx> <continue|step|ping>")
        sys.exit(1)
    port, cmd = sys.argv[1], sys.argv[2]
    if cmd == "continue":
        send_continue(port)
    elif cmd == "step":
        send_frame(port, 0x11)
    elif cmd == "ping":
        ser = open_port(port)
        time.sleep(0.1)
        ser.close()
        print("port ok")
    else:
        print(f"unknown command: {cmd}")
        sys.exit(1)


if __name__ == "__main__":
    main()
