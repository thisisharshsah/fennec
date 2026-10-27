#!/usr/bin/env python3
"""
Sanity check that the board's log-mel features match ml/features.py:
plays a steady tone, records a clip through the board, asks the board for
its latest live frame, and compares it with the Python features of the clip.

    bridge/.venv/bin/python ml/check_features.py
"""
import asyncio
import json
import pathlib
import subprocess
import sys
import time

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import features as F  # noqa: E402
from collect_auto import write_noise, TMP  # noqa: E402
from record import grab  # noqa: E402


async def main():
    import websockets
    TMP.mkdir(parents=True, exist_ok=True)
    tone = TMP / "tone_check.wav"
    write_noise(tone, "tone", seconds=4)
    subprocess.run(["osascript", "-e", "set volume output volume 55"])
    proc = subprocess.Popen(["afplay", str(tone)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    async with websockets.connect("ws://localhost:8777/", open_timeout=3, max_size=4_000_000) as ws:
        await ws.recv(); await ws.recv()
        await asyncio.sleep(0.8)
        pcm, rate = await grab(ws, "desk", 1000)
        await ws.send(json.dumps({"cmd": "features", "unit": "desk", "frame": 63}))
        board = None
        deadline = time.time() + 5
        while time.time() < deadline and board is None:
            m = json.loads(await asyncio.wait_for(ws.recv(), 5))
            if m.get("type") == "features":
                board = np.array(m["mel"], dtype=np.float32)
    proc.wait()
    subprocess.run(["osascript", "-e", "set volume output volume 30"])
    if pcm is None or board is None:
        sys.exit("no clip or no features reply")
    x = np.frombuffer(pcm, dtype=np.int16)
    py = F.logmel(x)[-1]
    diff = board - py
    print("python last frame :", np.round(py, 2))
    print("board  last frame :", np.round(board, 2))
    print(f"mean abs diff {np.abs(diff).mean():.3f}, max {np.abs(diff).max():.3f}  (frames are not time-aligned; shapes should agree, peak band should match)")
    print("peak band python", int(py.argmax()), " board", int(board.argmax()))


if __name__ == "__main__":
    asyncio.run(main())
