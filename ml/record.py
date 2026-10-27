#!/usr/bin/env python3
"""
Record labelled one-second clips through the creature's own microphone.

    bridge/.venv/bin/python ml/record.py creature -c 30     # say "creature" each time it prompts
    bridge/.venv/bin/python ml/record.py clap -c 30
    bridge/.venv/bin/python ml/record.py quiet -c 20 -a  # no prompt, back to back

Clips land in ml/data/<label>/<timestamp>.wav (16-bit mono, the board's
20 kHz). The board streams each clip over its serial link in about 4 s.
"""
import argparse
import asyncio
import base64
import json
import pathlib
import sys
import time
import wave

WS_URL = "ws://localhost:8777/"
HERE = pathlib.Path(__file__).resolve().parent


async def grab(ws, unit, ms, timeout=15):
    await ws.send(json.dumps({"cmd": "record", "unit": unit, "ms": ms}))
    chunks, of, rate = {}, None, 20000
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            m = json.loads(await asyncio.wait_for(ws.recv(), max(0.1, deadline - time.time())))
        except asyncio.TimeoutError:
            break
        if m.get("type") == "audio" and m.get("unit") == unit:
            chunks[m["seq"]] = base64.b64decode(m["b64"])
            of, rate = m["of"], m.get("rate", rate)
            if len(chunks) == of:
                return b"".join(chunks[i] for i in range(of)), rate
        elif m.get("type") == "event" and m.get("name") == "error" and "record" in m.get("what", ""):
            print("unit says:", m["what"])
            return None, rate
    return None, rate


def save(label, pcm, rate):
    d = HERE / "data" / label
    d.mkdir(parents=True, exist_ok=True)
    path = d / f"{time.strftime('%Y%m%d_%H%M%S')}_{int(time.time() * 1000) % 1000:03d}.wav"
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)
    return path


async def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("label")
    ap.add_argument("-c", dest="count", type=int, default=10)
    ap.add_argument("-m", dest="ms", type=int, default=1000)
    ap.add_argument("-u", dest="unit", default="desk")
    ap.add_argument("-a", dest="auto", action="store_true", help="no prompt between clips")
    ap.add_argument("-g", dest="gap", type=float, default=0.5, help="seconds between clips with -a")
    args = ap.parse_args()

    import websockets
    async with websockets.connect(WS_URL, open_timeout=3, max_size=4_000_000) as ws:
        await ws.recv()
        await ws.recv()
        n = 0
        failures = 0
        while n < args.count:
            if failures >= 3:
                sys.exit("three recordings in a row failed; check the bridge log (data/bridge.log)")
            if not args.auto:
                input(f"[{n + 1}/{args.count}] press Enter, then make the sound '{args.label}' ")
                await asyncio.sleep(0.3)
            pcm, rate = await grab(ws, args.unit, args.ms)
            if pcm is None:
                failures += 1
                print("no clip (is the unit on the cable and the bridge running?)")
                await asyncio.sleep(1)
                continue
            failures = 0
            path = save(args.label, pcm, rate)
            n += 1
            print(f"  saved {path.relative_to(HERE.parent)}  ({len(pcm) // 2} samples @ {rate} Hz)")
            if args.auto:
                await asyncio.sleep(args.gap)
    print(f"done: {n} clips of '{args.label}' in ml/data/{args.label}/")


if __name__ == "__main__":
    asyncio.run(main())
