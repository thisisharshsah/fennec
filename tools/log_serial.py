#!/usr/bin/env python3
"""
Log the bedsense serial stream to a CSV file.

    python tools/log_serial.py                 # auto-detects the ST-LINK port
    python tools/log_serial.py -p /dev/cu.usbmodem1103 -o data/night1.csv

While logging, press Enter to drop a marker row (type a label first, e.g.
"roll" then Enter, to name it). Ctrl-C stops and closes the file cleanly.
"""
import argparse
import datetime as dt
import pathlib
import queue
import sys
import threading
import time

import serial
import serial.tools.list_ports

ST_VID = 0x0483  # STMicroelectronics (ST-LINK virtual COM port)


def find_port():
    ports = list(serial.tools.list_ports.comports())
    for p in ports:
        if p.vid == ST_VID:
            return p.device
    for p in ports:
        if "usbmodem" in p.device or "ttyACM" in p.device:
            return p.device
    return None


def stdin_reader(q):
    for line in sys.stdin:
        q.put(line.strip() or "mark")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-p", dest="port", help="serial port (default: auto-detect ST-LINK)")
    ap.add_argument("-b", dest="baud", type=int, default=115200)
    ap.add_argument("-o", dest="out", help="CSV path (default: data/session_<timestamp>.csv)")
    args = ap.parse_args()

    port = args.port or find_port()
    if not port:
        sys.exit("No ST-LINK serial port found. Is the board plugged into the ST-LINK USB port?")

    out = pathlib.Path(args.out) if args.out else pathlib.Path("data") / f"session_{dt.datetime.now():%Y%m%d_%H%M%S}.csv"
    out.parent.mkdir(parents=True, exist_ok=True)

    marks = queue.Queue()
    threading.Thread(target=stdin_reader, args=(marks,), daemon=True).start()

    print(f"Logging {port} @ {args.baud} -> {out}")
    print("Press Enter to add a marker (type a label first to name it). Ctrl-C to stop.\n")

    n = 0
    t0 = time.time()
    last_status = t0
    pending = None
    skipped_first = False

    with serial.Serial(port, args.baud, timeout=1) as ser, open(out, "w", buffering=1) as f:
        f.write("t_ms,ax,ay,az,gx,gy,gz,marker\n")
        ser.reset_input_buffer()
        try:
            while True:
                raw = ser.readline()
                if not raw:
                    continue
                if not skipped_first:          # first line may be a partial one
                    skipped_first = True
                    continue
                line = raw.decode("ascii", errors="replace").strip()
                if not line:
                    continue

                try:
                    pending = marks.get_nowait()
                except queue.Empty:
                    pass

                if line.startswith("#"):
                    # event lines from the firmware become markers in the CSV
                    if line == "#MARK":
                        pending = "button"
                    elif line.startswith("#TURN"):
                        pending = "dev-turn"
                        print("\nboard:", line[1:].strip())
                    elif line.startswith("#SHIFT"):
                        pending = "dev-shift"
                    elif line.startswith("#OVERDUE"):
                        pending = "dev-overdue"
                        print("\nboard:", line[1:].strip())
                    else:
                        print("board:", line[1:].strip())
                    continue

                parts = line.split(",")
                if len(parts) != 7:
                    continue
                try:
                    [int(p) for p in parts]
                except ValueError:
                    continue

                f.write(line + "," + (pending or "") + "\n")
                if pending:
                    print(f"  marker '{pending}' at sample {n}")
                    pending = None
                n += 1

                now = time.time()
                if now - last_status >= 2.0:
                    el = now - t0
                    print(f"\r{n:7d} samples  {el:6.0f} s  {n / el:5.1f} Hz   ", end="", flush=True)
                    last_status = now
        except KeyboardInterrupt:
            pass

    el = time.time() - t0
    print(f"\n\nSaved {n} samples ({el:.0f} s, {n / max(el, 1e-9):.1f} Hz) to {out}")
    print(f"Plot it with:  python tools/plot_session.py {out}")


if __name__ == "__main__":
    main()
