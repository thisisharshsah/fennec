#!/usr/bin/env python3
"""
Give a unit its Wi-Fi details (and optionally a fixed bridge address or a name).

    bridge/.venv/bin/python bridge/setup_unit.py -s "MyNetwork"          # asks for the password; also
                                                                             # tells the unit this Mac's address
    bridge/.venv/bin/python bridge/setup_unit.py -H 192.168.1.92  # just (re)set the bridge address
    bridge/.venv/bin/python bridge/setup_unit.py -n shelf
    bridge/.venv/bin/python bridge/setup_unit.py -S

The unit must be on the serial cable. Commands go through the running bridge
(so nothing fights over the port); if no bridge is running the serial port is
opened directly. Settings are stored in the unit's flash.
"""
import argparse
import asyncio
import getpass
import json
import sys
import time

WS_URL = "ws://localhost:8777/"


def lan_ip():
    sys.path.insert(0, __file__.rsplit("/", 1)[0])
    from bridge import lan_ip as f
    return f()


async def via_bridge(cmds, wait_s, auto_bridge):
    import websockets
    async with websockets.connect(WS_URL, open_timeout=2) as ws:
        hello = json.loads(await ws.recv())
        if auto_bridge:
            cmds.append({"cmd": "bridge", "unit": auto_bridge, "host": hello.get("lan_ip", lan_ip()),
                         "port": hello.get("unit_port", 8778)})
        for c in cmds:
            await ws.send(json.dumps(c))
        deadline = time.time() + wait_s
        while time.time() < deadline:
            try:
                m = json.loads(await asyncio.wait_for(ws.recv(), timeout=max(0.1, deadline - time.time())))
            except asyncio.TimeoutError:
                break
            if m.get("type") in ("status", "hello"):
                print(json.dumps({k: v for k, v in m.items() if k not in ("ts", "t", "type", "link")}, indent=1))
            elif m.get("type") == "event" and m.get("name", "").startswith("wifi_"):
                print("event:", m["name"])


def via_serial(cmds, wait_s, auto_bridge):
    import serial
    sys.path.insert(0, __file__.rsplit("/", 1)[0])
    from bridge import find_port
    if auto_bridge:
        cmds.append({"cmd": "bridge", "unit": auto_bridge, "host": lan_ip(), "port": 8778})
    port = find_port()
    if not port:
        sys.exit("no bridge running and no ST-LINK serial port found")
    with serial.Serial(port, 921600, timeout=1) as ser:
        for c in cmds:
            ser.write((json.dumps(c) + "\n").encode())
        t0 = time.time()
        while time.time() - t0 < wait_s:
            line = ser.readline().decode("ascii", "replace").strip()
            if line.startswith("{") and ("\"status\"" in line or "\"hello\"" in line or "wifi_" in line):
                print(line)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-s", dest="ssid")
    ap.add_argument("-k", dest="password", help="omit to be prompted")
    ap.add_argument("-H", dest="bridge_host", help="bridge (this Mac's) IP; with -s it is filled in automatically")
    ap.add_argument("-P", dest="bridge_port", type=int, default=0)
    ap.add_argument("-n", dest="name", help="unit name")
    ap.add_argument("-S", dest="status", action="store_true")
    ap.add_argument("-u", dest="unit", default="desk", help="which unit (as the bridge knows it)")
    args = ap.parse_args()

    cmds = []
    if args.name:
        cmds.append({"cmd": "name", "unit": args.unit, "name": args.name})
    if args.ssid:
        pw = args.password if args.password is not None else getpass.getpass(f"password for {args.ssid}: ")
        cmds.append({"cmd": "wifi", "unit": args.unit, "ssid": args.ssid, "pass": pw})
    auto_bridge = None
    if args.bridge_host is not None:
        cmds.append({"cmd": "bridge", "unit": args.unit, "host": args.bridge_host, "port": args.bridge_port})
    elif args.ssid:
        auto_bridge = args.unit
    if args.status or not cmds:
        cmds.append({"cmd": "status", "unit": args.unit})
    wait_s = 25 if args.ssid else 4

    try:
        asyncio.run(via_bridge(cmds, wait_s, auto_bridge))
    except (OSError, ConnectionError) as e:
        print(f"(bridge not reachable: {e}; using the serial port directly)")
        via_serial(cmds, wait_s, auto_bridge)


if __name__ == "__main__":
    main()
