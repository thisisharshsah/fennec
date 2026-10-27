#!/usr/bin/env python3
"""
Exercise a creature's Bluetooth setup mode from the Mac (no phone needed):
find it, read its network list, make it identify, optionally try credentials.

    bridge/.venv/bin/python tools/ble_setup_test.py                 # scan, list networks, identify
    bridge/.venv/bin/python tools/ble_setup_test.py -s X -k Y -b 192.168.1.92:8778

Put the unit in setup mode first: {"cmd":"provision"} over the bridge, or
hold the blue button for 3 s during a reset.
"""
import argparse
import asyncio
import sys

from bleak import BleakClient, BleakScanner

SVC = "00467768-6228-2272-4663-277478268000"
CH = {k: f"00467768-6228-2272-4663-27747826{v}" for k, v in
      dict(state="8001", error="8002", rpc="8003", result="8004", caps="8005",
           ncount="8010", nindex="8011", nentry="8012", bridge="8013").items()}


def packet(cmd, data=b""):
    body = bytes([cmd, len(data)]) + data
    return body + bytes([sum(body) & 0xFF])


async def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-s", dest="ssid"); ap.add_argument("-k", dest="password", default=""); ap.add_argument("-b", dest="bridge")
    ap.add_argument("-t", dest="timeout", type=float, default=15)
    args = ap.parse_args()

    print("scanning for creature-* ...")
    found = None
    def cb(d, adv):
        nonlocal found
        if found is None and ((adv.local_name or "").startswith("creature-") or SVC in [u.lower() for u in adv.service_uuids]):
            found = d
    scanner = BleakScanner(cb)
    await scanner.start()
    for _ in range(int(args.timeout * 10)):
        if found: break
        await asyncio.sleep(0.1)
    await scanner.stop()
    if not found:
        sys.exit("no creature in setup mode found")
    print("found", found.name, found.address)

    async with BleakClient(found, timeout=20) as c:
        state = (await c.read_gatt_char(CH["state"]))[0]
        caps = (await c.read_gatt_char(CH["caps"]))[0]
        print(f"state 0x{state:02x} caps 0x{caps:02x}")
        n = (await c.read_gatt_char(CH["ncount"]))[0]
        print("networks:", n)
        for i in range(n):
            await c.write_gatt_char(CH["nindex"], bytes([i]), response=True)
            e = (await c.read_gatt_char(CH["nentry"])).decode(errors="replace")
            print("  ", e)
        events = []
        def on_notify(_, data): events.append(bytes(data))
        await c.start_notify(CH["state"], on_notify)
        await c.start_notify(CH["error"], on_notify)
        await c.start_notify(CH["result"], on_notify)
        print("identify ->"); await c.write_gatt_char(CH["rpc"], packet(0x02), response=True)
        await asyncio.sleep(2)
        if args.ssid:
            if args.bridge:
                await c.write_gatt_char(CH["bridge"], args.bridge.encode(), response=True)
            s, p = args.ssid.encode(), args.password.encode()
            await c.write_gatt_char(CH["rpc"], packet(0x01, bytes([len(s)]) + s + bytes([len(p)]) + p), response=True)
            print("credentials sent; waiting up to 25 s ...")
            for _ in range(50):
                await asyncio.sleep(0.5)
                st = (await c.read_gatt_char(CH["state"]))[0]
                er = (await c.read_gatt_char(CH["error"]))[0]
                if st == 0x04 or er:
                    break
            print(f"final state 0x{st:02x} error {er}")
            if st == 0x04:
                print("result:", (await c.read_gatt_char(CH["result"]))[3:-1].decode(errors="replace"))
        print("notifications:", [e.hex() for e in events][:6])


if __name__ == "__main__":
    asyncio.run(main())
