#!/usr/bin/env python3
"""
Centre and orient the creature's servos, one joint at a time.

    bridge/.venv/bin/python bridge/calibrate.py            # interactive, through the running bridge
    bridge/.venv/bin/python bridge/calibrate.py -s     # just print the stored calibration

For each joint (ear_l, ear_r, pan, tilt, tail) the script holds the servo at
its centre pulse so you can fit the horn straight, then lets you nudge the
centre and flip the direction until the joint matches the drawing:
ears positive = perked forward, pan positive = turn right (creature's
right), tilt positive = up, tail positive = right.

Keys:  +/-  nudge centre by 10 us    </>  nudge by 50 us    i  invert direction
       t    test: sweep the joint -30..+30 degrees through the engine
       s    save this joint and go to the next   q  quit (unsaved nudges are dropped)
"""
import argparse
import asyncio
import json
import sys
import termios
import tty

WS_URL = "ws://localhost:8777/"
JOINTS = ["ear_l", "ear_r", "pan", "tilt", "tail"]
CHANNEL = {"ear_l": 0, "ear_r": 1, "pan": 2, "tilt": 3, "tail": 4}


def getch():
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        return sys.stdin.read(1)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


async def request(ws, cmd, unit, wait_type=None, timeout=4):
    await ws.send(json.dumps(dict(cmd, unit=unit)))
    if not wait_type:
        return None
    try:
        while True:
            m = json.loads(await asyncio.wait_for(ws.recv(), timeout))
            if m.get("type") == wait_type and m.get("unit") == unit:
                return m
    except asyncio.TimeoutError:
        return None


async def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-u", dest="unit", default="desk")
    ap.add_argument("-s", dest="show", action="store_true")
    args = ap.parse_args()

    import websockets
    async with websockets.connect(WS_URL, open_timeout=3) as ws:
        await ws.recv()
        await ws.recv()
        calib = await request(ws, {"cmd": "calib"}, args.unit, "calib")
        if not calib:
            sys.exit("no calib reply: is the unit on the cable (or on Wi-Fi) and the bridge running?")
        print("stored:", {k: calib[k] for k in ("servos", "trim", "invert", "cheek_invert")})
        if args.show:
            return
        if not calib["servos"]:
            print("no servo driver found at 0x40 on the header I2C bus; trims can still be stored")

        for joint in JOINTS:
            ch = CHANNEL[joint]
            trim = calib["trim"][ch]
            invert = bool(calib["invert"][ch])
            print(f"\n== {joint} (channel {ch})  centre {1500 + trim} us  invert {invert}")
            print("   fit the horn so the joint is straight at this pulse, then nudge with +/- < > , i to invert, t to test, s to save")
            while True:
                await request(ws, {"cmd": "servo", "ch": ch, "us": 1500 + trim}, args.unit)
                print(f"\r   centre {1500 + trim:4d} us  invert {int(invert)}   ", end="", flush=True)
                k = getch()
                if k in "+=":
                    trim += 10
                elif k in "-_":
                    trim -= 10
                elif k in ">.":
                    trim += 50
                elif k in "<,":
                    trim -= 50
                elif k == "i":
                    invert = not invert
                elif k == "t":
                    await request(ws, {"cmd": "trim", "joint": joint, "us": trim, "invert": int(invert)}, args.unit, "calib")
                    await request(ws, {"cmd": "servo", "ch": ch, "us": 0}, args.unit)
                    for pan, tilt in ((-30, 0), (30, 0), (0, 0)) if joint in ("pan",) else ((0, -30), (0, 30), (0, 0)) if joint == "tilt" else ():
                        await request(ws, {"cmd": "look_at", "pan": pan, "tilt": tilt}, args.unit)
                        await asyncio.sleep(1.2)
                    if joint.startswith("ear"):
                        await request(ws, {"cmd": "gesture", "name": "perk"}, args.unit)
                        await asyncio.sleep(1.5)
                        await request(ws, {"cmd": "gesture", "name": "droop"}, args.unit)
                        await asyncio.sleep(1.5)
                    if joint == "tail":
                        await request(ws, {"cmd": "gesture", "name": "wag"}, args.unit)
                        await asyncio.sleep(2)
                    print("\n   did it move the right way? (i flips it)")
                elif k == "s":
                    r = await request(ws, {"cmd": "trim", "joint": joint, "us": trim, "invert": int(invert)}, args.unit, "calib")
                    await request(ws, {"cmd": "servo", "ch": ch, "us": 0}, args.unit)
                    print("\n   saved:", r["trim"][ch], "us, invert", bool(r["invert"][ch]))
                    break
                elif k in ("q", "\x03"):
                    await request(ws, {"cmd": "servo", "ch": ch, "us": 0}, args.unit)
                    print("\nquit")
                    return
        print("\nall joints saved. The engine is back in control; try: express pleased, gesture wag.")


if __name__ == "__main__":
    asyncio.run(main())
