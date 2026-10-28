"""
Fine tuning Crawl's small brain: today's brain (gpt-oss-20b, Apache 2.0) answers many varied
situations with the hub's own prompts, only answers that pass every benchmark check are kept, and
small models learn from them with LoRA on the Mac. The benchmark's 60 situations are never trained on.

    tools/bench/.venv/bin/python tools/bench/train.py data 1200       teacher answers (resumable)
    tools/bench/.venv/bin/python tools/bench/train.py prepare         filter, split into train and valid
    tools/bench/.venv/bin/python tools/bench/train.py lora mlx-community/Qwen3.5-4B-4bit
    tools/bench/.venv/bin/python tools/bench/bench.py run mlx-community/Qwen3.5-4B-4bit data/train/adapters/Qwen3.5-4B-4bit

Everything is written to data/train/.
"""
import json
import pathlib
import random
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import bench  # noqa: E402
import cases as test_cases  # noqa: E402

OUT = ROOT / "data" / "train"
RAW = OUT / "teacher.jsonl"

# Messages unlike the benchmark's own wording, in the same kinds.
CANNOT_KNOW = [
    "Is it raining?", "Is the sun out?", "What am I wearing?", "Can you see my face clearly?", "What's for dinner?",
    "Who just texted me?", "What time does the shop close?", "Is my laptop charging?", "How many tabs do I have open?",
    "Is the window open?", "Do you like the smell of this candle?", "What's on my screen?", "Is it cold outside?",
    "Is the TV on?", "What colour are my eyes?", "Did someone ring the bell?", "How is the traffic?",
    "Is my phone on silent?", "Can you hear the birds?", "What's the news today?", "Is the oven still on?",
    "How bright is it in here?", "What am I eating?", "Is the kettle boiling?",
]
SMALL_TALK = [
    "Hey Crawl.", "Hello little one.", "Good night Crawl.", "What's new?", "Are you awake?", "Do you dream?",
    "What do you like?", "Miss me?", "Do you like it here?", "Say something nice.", "Are you happy?",
    "What should we call your tail?", "Do you have a favourite time of day?", "Hi there!", "Long day, huh?",
    "Do you ever sleep?", "Is it fun being on a desk?", "What did you notice today?",
]
ABOUT_ME = [
    "How am I doing?", "Have I been sitting long?", "Is the room too warm?", "Am I slouching?", "Was it loud earlier?",
    "Do I look tired?", "Am I alone?", "Should I get some water?", "How's the air in here?", "Did I stretch today?",
    "Is anyone else here?", "Was I on the phone a lot?", "Is it quiet now?", "How humid is it?", "Did you see me leave?",
    "What time is it?", "Is it too dry in here?", "Am I working too much?",
]
FEELINGS = [
    "Ugh, today is rough.", "I'm happy today!", "I'm bored.", "I feel lonely.", "That meeting was awful.",
    "I'm excited about tomorrow.", "I'm hungry.", "I can't sleep.", "I'm nervous about my exam.",
    "I got the job!", "My head hurts.", "I'm cold.",
]
ACTIVITIES = ["working at the desk", "on the phone", "on a video call", "having a drink", "eating", "reading",
              "writing on paper", "watching a video", "stretching", "with someone", "away from the desk"]
EXTRAS = ["slouching", "looks tired", "leaning close to the screen", "voices in the room", "talking", "holding a drink",
          "the room is loud", "I was just moved", "a cat in view"]
MOODS = [None, None, "neutral", "curious", "pleased", "sleepy", "alert", "listening"]
DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
COUNTS = [None, None, None, "1 x clap", "2 x knock", "3 x someone in front", "1 x moved, 2 x knock", "4 x looked at"]


def camera_sentences():
    """What the describer really said, from the logs: the only things a room may mention beyond sensors."""
    seen = []
    for f in sorted((ROOT / "data").glob("log_*.jsonl")):
        for line in open(f):
            if '"described"' not in line:
                continue
            try:
                text = json.loads(line).get("text", "")
            except ValueError:
                continue
            if text and "Nobody" not in text and text not in seen:
                seen.append(text)
    return seen


def random_room(rng, sentences):
    activity = rng.choice(ACTIVITIES)
    away = activity.startswith("away")
    minutes = rng.choice([0, 1, 2, 4, 8, 15, 25, 40, 55, 70, 95])
    scene = activity + (f" for {minutes} min" if minutes else " just now")
    if not away:
        extras = rng.sample(EXTRAS, rng.choice([0, 0, 1, 1, 2]))
        if extras:
            scene += ", " + ", ".join(extras)
        if sentences and rng.random() < 0.4:
            scene += f'. The camera\'s model says: "{rng.choice(sentences)}"'
        if rng.random() < 0.1:
            scene += ". (Not sure about this.)"
    presence = (f"nobody in front of you (since {minutes + 1} min ago)" if away
                else f"someone is in front of you (since {minutes + rng.choice([1, 3, 10])} min ago)")
    temp = round(rng.uniform(17.5, 32.5), 1)
    return test_cases.room(temp, rng.uniform(22, 68), rng.uniform(28, 72), mood=rng.choice(MOODS),
                           presence=presence if rng.random() < 0.9 else None,
                           scene=scene if rng.random() < 0.85 else None, counts=rng.choice(COUNTS))


def situations(n, seed=101):
    rng = random.Random(seed)
    sentences = camera_sentences()
    test_rooms = {c["room"] for c in json.loads((bench.DATA / "cases.json").read_text())["cases"]}
    kinds = [("cannot_know", CANNOT_KNOW), ("small_talk", SMALL_TALK), ("about_me", ABOUT_ME), ("feelings", FEELINGS)]
    recents = [[], [], ["The room is calm."], ["I wonder what they're working on.", "It's warmer than this morning."]]
    out = []
    while len(out) < n:
        room = random_room(rng, sentences)
        if room in test_rooms:
            continue
        when = f"{rng.choice(DAYS)} {rng.randrange(6, 24):02d}:{rng.randrange(60):02d}"
        if rng.random() < 0.55:
            kind, pool = rng.choices(kinds, weights=[3, 2, 2, 1])[0]
            out.append({"id": f"t{len(out):05d}", "task": "reply", "kind": kind, "message": rng.choice(pool),
                        "room": room, "when": when})
        else:
            out.append({"id": f"t{len(out):05d}", "task": "thought", "kind": "thought", "recent": rng.choice(recents),
                        "room": room, "when": when})
    return out


def data(n):
    """Today's brain answers each situation once; resumes where it stopped."""
    OUT.mkdir(parents=True, exist_ok=True)
    done = set()
    if RAW.exists():
        done = {json.loads(l)["id"] for l in open(RAW)}
    client, model = bench.gateway()
    todo = [s for s in situations(n) if s["id"] not in done]
    print(f"{len(done)} done, {len(todo)} to go", flush=True)
    with open(RAW, "a") as f:
        for s in todo:
            msgs = bench.messages(s)
            for _ in range(2):
                try:
                    r = client.messages.create(model=model, max_tokens=1024, system=msgs[0]["content"], messages=msgs[1:])
                    break
                except Exception as e:  # noqa: BLE001
                    print("retry:", e, flush=True)
                    time.sleep(5)
            else:
                continue
            text = bench.clean(" ".join(b.text for b in r.content if b.type == "text"))
            f.write(json.dumps(dict(s, answer=text)) + "\n")
            f.flush()
            print(f"{s['id']} {s['task']:7} {text[:80]}", flush=True)


def prepare():
    """Keep only answers that pass every check, then a 90/10 split in the chat format MLX trains on."""
    _, invented_words = bench.load_cases()
    rows = [json.loads(l) for l in open(RAW)]
    kept, why = [], {}
    for r in rows:
        result, _ = bench.checks(r, r["answer"], invented_words)
        failed = [k for k, v in result.items() if not v]
        if failed:
            for k in failed:
                why[k] = why.get(k, 0) + 1
            continue
        kept.append(r)
    rng = random.Random(5)
    rng.shuffle(kept)
    cut = max(1, len(kept) // 10)
    for name, part in (("valid", kept[:cut]), ("train", kept[cut:])):
        with open(OUT / f"{name}.jsonl", "w") as f:
            for r in part:
                f.write(json.dumps({"messages": bench.messages(r) + [{"role": "assistant", "content": r["answer"]}]}) + "\n")
    tasks = {}
    for r in kept:
        tasks[r["task"] + "/" + r["kind"]] = tasks.get(r["task"] + "/" + r["kind"], 0) + 1
    print(f"{len(rows)} answers, kept {len(kept)} ({len(kept) / max(1, len(rows)):.0%}); dropped for: {why}")
    print(f"train {len(kept) - cut}, valid {cut}; {tasks}")


def lora(model_id, iters=None):
    """LoRA on the Mac. Settings go in a YAML file so the command needs only short options."""
    slug = bench.slug(model_id)
    train_n = sum(1 for _ in open(OUT / "train.jsonl"))
    # batch 1 with 4 steps of accumulation: the same effective batch in a quarter of the memory, which a
    # large vocabulary (Qwen) needs while the gateway's model and the describer also sit on the GPU
    iters = iters or max(200, int(train_n * 3 / 4))                    # about three passes
    config = OUT / f"lora_{slug}.yaml"
    config.write_text("\n".join([
        f"model: {model_id}", "train: true", f"data: {OUT}", f"adapter_path: {OUT / 'adapters' / slug}",
        "fine_tune_type: lora", "batch_size: 1", "grad_accumulation_steps: 4", f"iters: {iters * 4}",
        "learning_rate: 1.0e-4", "num_layers: 8",
        "steps_per_report: 80", "steps_per_eval: 400", "save_every: 800", "max_seq_length: 1024", "mask_prompt: true",
        "grad_checkpoint: true", "seed: 3",
    ]) + "\n")
    print(f"training {model_id} for {iters} steps on {train_n} examples", flush=True)
    started = time.time()
    subprocess.run([sys.executable, "-m", "mlx_lm", "lora", "-c", str(config)], check=True)
    print(f"trained in {(time.time() - started) / 60:.0f} min", flush=True)


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "data":
        data(int(sys.argv[2]) if len(sys.argv) > 2 else 1200)
    elif cmd == "prepare":
        prepare()
    elif cmd == "lora":
        lora(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else None)
