"""
Fennec's describer (test rig): a local vision-language model that puts the desk scene into one
sentence, so the creature can know what its fixed detectors cannot see (a video call, writing on
paper, a game). Runs on this Mac only; the hub starts and stops it with the eye.

Every INTERVAL_S, while the eye sees someone, it asks the hub for one picture (cmd "snapshot"),
describes it, and sends back only the sentence (cmd "described"). Pictures stay in memory and are
never written to disk.

    tools/describe/.venv/bin/python tools/describe/describe.py
    FENNEC_VLM=<model id> to try another MLX model
"""
import asyncio
import base64
import io
import json
import os
import time

import websockets
from PIL import Image
from mlx_vlm import generate, load
from mlx_vlm.prompt_utils import apply_chat_template

HUB = os.environ.get("ROOM_BRIDGE_URL", "ws://127.0.0.1:8777/")
MODEL = os.environ.get("FENNEC_VLM", "mlx-community/Qwen2.5-VL-3B-Instruct-4bit")
INTERVAL_S = 20
QUESTION = ("You are the eyes of a small desk companion robot. In one short sentence, say what the person "
            "at the desk is doing right now and what is in their hands or in front of them, for example "
            "typing, on a video call, reading, eating, drinking, on their phone, writing on paper, playing "
            "a game or watching a video. If nobody is there, say: Nobody is at the desk. "
            "Do not guess who anyone is.")


def log(text):
    print(time.strftime("%H:%M:%S"), text, flush=True)


class Describer:
    def __init__(self):
        started = time.time()
        self.model, self.processor = load(MODEL)
        self.prompt = apply_chat_template(self.processor, self.model.config, QUESTION, num_images=1)
        log(f"model {MODEL} ready in {time.time() - started:.0f} s")

    def describe(self, jpeg):
        image = Image.open(io.BytesIO(jpeg)).convert("RGB")
        out = generate(self.model, self.processor, self.prompt, [image], max_tokens=48, verbose=False)
        text = getattr(out, "text", out).strip().split("\n")[0]
        return text[:300]


async def main():
    describer = await asyncio.to_thread(Describer)
    while True:
        try:
            async with websockets.connect(HUB, open_timeout=5, max_size=4 * 1024 * 1024) as ws:
                await session(ws, describer)
        except Exception as e:  # the hub restarted or is not up yet
            log(f"hub not reachable ({e}); retrying")
        await asyncio.sleep(3)


async def session(ws, describer):
    someone_at = 0.0                  # when the eye last saw someone
    asked_at = 0.0
    async for text in ws:
        msg = json.loads(text)
        kind = msg.get("type")
        now = time.time()
        if kind == "vision" and msg.get("present"):
            someone_at = now
        elif kind == "picture" and msg.get("jpeg"):
            started = time.time()
            sentence = await asyncio.to_thread(describer.describe, base64.b64decode(msg["jpeg"]))
            seconds = round(time.time() - started, 1)
            log(f"{seconds} s: {sentence}")
            await ws.send(json.dumps({"cmd": "described", "text": sentence, "seconds": seconds}))
        if now - asked_at >= INTERVAL_S and now - someone_at < 5:
            asked_at = now
            await ws.send(json.dumps({"cmd": "snapshot"}))


if __name__ == "__main__":
    asyncio.run(main())
