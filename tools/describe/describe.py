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
import concurrent.futures
import io
import json
import os
import re
import time

import websockets
from PIL import Image
from mlx_vlm import generate, load
from mlx_vlm.prompt_utils import apply_chat_template

HUB = os.environ.get("ROOM_BRIDGE_URL", "ws://127.0.0.1:8777/")
MODEL = os.environ.get("FENNEC_VLM", "mlx-community/Qwen2.5-VL-7B-Instruct-4bit")
INTERVAL_S = 20
# A small model grabs a ready-made answer when offered one ("Nobody is at the desk"), so it is only
# offered when the eye itself sees no face; otherwise the question is about the person it can see.
# No list of examples: a small model picks from a list it is given even when it sees none of it.
PERSON_QUESTION = ("In one short sentence, say what the person in this picture is doing and what is in their "
                   "hands. Only say what you can clearly see; if you are not sure, say less. "
                   "Do not guess who anyone is.")
OPEN_QUESTION = ("Is there a person in this picture? If yes, in one short sentence say what they are doing and "
                 "what they are holding. If no, answer: no person.")


# MLX keeps its GPU stream per thread: the model must be loaded and used on the same one.
MODEL_THREAD = concurrent.futures.ThreadPoolExecutor(max_workers=1)


async def on_model_thread(fn, *args):
    return await asyncio.get_running_loop().run_in_executor(MODEL_THREAD, fn, *args)


def log(text):
    print(time.strftime("%H:%M:%S"), text, flush=True)


class Describer:
    def __init__(self):
        started = time.time()
        self.model, self.processor = load(MODEL)
        self.prompts = {seen: apply_chat_template(self.processor, self.model.config, q, num_images=1)
                        for seen, q in ((True, PERSON_QUESTION), (False, OPEN_QUESTION))}
        log(f"model {MODEL} ready in {time.time() - started:.0f} s")

    def describe(self, jpeg, face_seen):
        image = Image.open(io.BytesIO(jpeg)).convert("RGB")
        out = generate(self.model, self.processor, self.prompts[face_seen], [image], max_tokens=48, verbose=False)
        text = getattr(out, "text", out).strip().split("\n")[0]
        if text.lower().rstrip(".").startswith("no person"):
            return "Nobody is at the desk."
        text = re.sub(r"^(?:yes[,.]?\s*)?(?:there is (?:a|one) person in (?:the|this) picture\.?\s*)?", "", text,
                      flags=re.IGNORECASE)
        return (text[:1].upper() + text[1:])[:300]


async def main():
    describer = await on_model_thread(Describer)
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
    face_seen = False
    async for text in ws:
        msg = json.loads(text)
        kind = msg.get("type")
        now = time.time()
        if kind == "vision":
            face_seen = bool(msg.get("faces"))
            if msg.get("present"):
                someone_at = now
        elif kind == "picture" and msg.get("jpeg"):
            started = time.time()
            sentence = await on_model_thread(describer.describe, base64.b64decode(msg["jpeg"]), face_seen)
            seconds = round(time.time() - started, 1)
            log(f"{seconds} s: {sentence}")
            await ws.send(json.dumps({"cmd": "described", "text": sentence, "seconds": seconds}))
        if now - asked_at >= INTERVAL_S and now - someone_at < 5:
            asked_at = now
            await ws.send(json.dumps({"cmd": "snapshot"}))


if __name__ == "__main__":
    asyncio.run(main())
