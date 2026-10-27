#!/usr/bin/env python3
"""
Collect the classes that need no human: quiet, speech (Mac voices), noise
and alert sounds, played through the Mac speaker while the board records.

    bridge/.venv/bin/python ml/collect_auto.py -n 25
"""
import argparse
import asyncio
import json
import math
import pathlib
import random
import struct
import subprocess
import sys
import wave

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from record import grab, save  # noqa: E402

HERE = pathlib.Path(__file__).resolve().parent
TMP = HERE / "data" / "_tmp"
VOICES = ["Samantha", "Alex", "Daniel", "Karen", "Moira", "Rishi", "Tessa", "Fred"]
PHRASES = ["what is the temperature in here", "turn the lights down a little", "did anyone come by today",
           "good morning, how did you sleep", "remind me to call back at five", "it is getting warm in this room",
           "can you hear me from over here", "let's go for a walk later", "the meeting starts in ten minutes",
           "I think the kettle is boiling"]
ALERTS = ["/System/Library/Sounds/Glass.aiff", "/System/Library/Sounds/Ping.aiff", "/System/Library/Sounds/Sosumi.aiff",
          "/System/Library/Sounds/Hero.aiff", "/System/Library/Sounds/Funk.aiff", "/System/Library/Sounds/Submarine.aiff",
          "/System/Library/Sounds/Blow.aiff", "/System/Library/Sounds/Basso.aiff"]


def write_noise(path, kind, seconds=1.6, rate=44100):
    n = int(seconds * rate)
    frames = bytearray()
    state = 0.0
    phase = 0.0
    f0 = random.uniform(200, 2000)
    for i in range(n):
        if kind == "white":
            v = random.uniform(-1, 1)
        elif kind == "brown":
            state = max(-1.0, min(1.0, state + random.uniform(-0.05, 0.05)))
            v = state * 3
        else:  # tone / hum
            phase += 2 * math.pi * f0 / rate
            v = 0.6 * math.sin(phase) + 0.2 * math.sin(3 * phase)
        frames += struct.pack("<h", int(max(-1, min(1, v)) * 20000))
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate); w.writeframes(bytes(frames))


async def play_and_record(ws, unit, cmd, label, lead=0.15):
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    await asyncio.sleep(lead)
    pcm, rate = await grab(ws, unit, 1000)
    proc.wait(timeout=20)
    if pcm:
        p = save(label, pcm, rate)
        print(f"  {label}: {p.name}")
        return True
    print(f"  {label}: no clip")
    return False


async def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-n", dest="per_class", type=int, default=25)
    ap.add_argument("-u", dest="unit", default="desk")
    ap.add_argument("-V", dest="volume", type=int, default=60)
    args = ap.parse_args()
    TMP.mkdir(parents=True, exist_ok=True)
    subprocess.run(["osascript", "-e", f"set volume output volume {args.volume}"])

    import websockets
    async with websockets.connect("ws://localhost:8777/", open_timeout=3, max_size=4_000_000) as ws:
        await ws.recv(); await ws.recv()
        n = args.per_class
        print("quiet")
        for i in range(n):
            pcm, rate = await grab(ws, args.unit, 1000)
            if pcm: save("quiet", pcm, rate)
            await asyncio.sleep(0.3)
        print("speech")
        for i in range(n):
            voice = VOICES[i % len(VOICES)]
            phrase = random.choice(PHRASES)
            rate_wpm = random.choice([150, 175, 200])
            await play_and_record(ws, args.unit, ["say", "-v", voice, "-r", str(rate_wpm), phrase], "speech", lead=random.uniform(0.1, 0.6))
        print("noise")
        for i in range(n):
            kind = ["white", "brown", "tone"][i % 3]
            path = TMP / f"noise_{kind}.wav"
            write_noise(path, kind)
            await play_and_record(ws, args.unit, ["afplay", "-v", str(random.choice([0.3, 0.6, 1.0])), str(path)], "noise")
        print("alert")
        for i in range(n):
            snd = ALERTS[i % len(ALERTS)]
            await play_and_record(ws, args.unit, ["afplay", str(snd)], "alert", lead=random.uniform(0.0, 0.3))
    subprocess.run(["osascript", "-e", "set volume output volume 30"])
    for label in ("quiet", "speech", "noise", "alert"):
        print(label, len(list((HERE / "data" / label).glob("*.wav"))))


if __name__ == "__main__":
    asyncio.run(main())
