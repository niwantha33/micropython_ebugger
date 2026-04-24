# trace_reader.py — runs on WINDOWS. Parses framed events from CDC1.
#
# Frame: [0xAA, type, len, payload(len)...]
#   type 0x01 trace    payload = [ip_lo, ip_hi, op]
#   type 0x02 bp_hit   payload = [ip_lo, ip_hi]
#
# Usage: python trace_reader.py COM3

import sys
import serial


def main():
    if len(sys.argv) != 2:
        print("usage: python trace_reader.py <COMx>")
        sys.exit(1)

    ser = serial.Serial(sys.argv[1], 115200, timeout=0.1)
    print(f"Reading from {sys.argv[1]}. Ctrl-C to stop.")

    buf = bytearray()
    try:
        while True:
            chunk = ser.read(512)
            if chunk:
                buf.extend(chunk)

            while True:
                # sync
                while buf and buf[0] != 0xAA:
                    buf.pop(0)
                if len(buf) < 3:
                    break
                tlen = buf[2]
                if len(buf) < 3 + tlen:
                    break
                ttype = buf[1]
                payload = bytes(buf[3:3 + tlen])
                del buf[:3 + tlen]

                if ttype == 0x01 and len(payload) == 3:
                    ip = payload[0] | (payload[1] << 8)
                    op = payload[2]
                    print(f"TRACE  ip=0x{ip:04x}  op={op}")
                elif ttype == 0x02 and len(payload) == 2:
                    ip = payload[0] | (payload[1] << 8)
                    print(f"BP_HIT ip=0x{ip:04x}  <<< VM paused; send continue >>>")
                else:
                    print(f"unknown type=0x{ttype:02x} len={tlen} payload={payload.hex()}")
    except KeyboardInterrupt:
        print("\nstopped")
    finally:
        ser.close()


if __name__ == "__main__":
    main()
