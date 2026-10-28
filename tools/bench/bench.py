"""
Benchmark for Crawl's brain: the same situations and prompts the hub uses (bridge/brain.py), answered
by small open models through MLX and by today's brain (gpt-oss-20b on the Conscious gateway), then
scored by automatic checks and by a judge model.

    tools/bench/.venv/bin/python tools/bench/bench.py run mlx-community/Qwen3.5-2B-4bit
    tools/bench/.venv/bin/python tools/bench/bench.py teacher          today's brain through the gateway
    tools/bench/.venv/bin/python tools/bench/bench.py judge            scores every answer file not yet judged
    tools/bench/.venv/bin/python tools/bench/bench.py report           the table

Answers and scores go to data/bench/.
"""
import json
import pathlib
import re
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "bridge"))
from brain import PERSONA, room_context, thought_prompt  # noqa: E402

DATA = ROOT / "data" / "bench"
NAME = "crawl"
REPLY_TOKENS = 160          # small models answer directly; thinking is switched off where a model has it


def load_cases():
    d = json.loads((DATA / "cases.json").read_text())
    return d["cases"], d["invented_words"]


def messages(case):
    system = PERSONA.format(name=NAME.capitalize())
    if case["task"] == "reply":
        user = room_context(case["room"], case["when"]) + "\n\n" + case["message"]
    else:
        user = thought_prompt(case["room"], case.get("recent", []), case["when"])
    return [{"role": "system", "content": system}, {"role": "user", "content": user}]


def clean(text):
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.S)
    text = re.sub(r"^.*?</think>", "", text, flags=re.S)           # a template that opened the block itself
    return text.strip().strip('"').strip()


def slug(model):
    return model.split("/")[-1]


# answering

def run(model_id):
    from mlx_lm import load, stream_generate
    from mlx_lm.sample_utils import make_sampler
    import mlx.core as mx
    cases, _ = load_cases()
    started = time.time()
    model, tokenizer = load(model_id)
    load_s = time.time() - started
    sampler = make_sampler(temp=0.7, top_p=0.9)
    out = []
    for case in cases:
        msgs = messages(case)
        try:
            prompt = tokenizer.apply_chat_template(msgs, add_generation_prompt=True, tokenize=False, enable_thinking=False)
        except Exception:                                            # templates without a system role or the switch
            merged = [{"role": "user", "content": msgs[0]["content"] + "\n\n" + msgs[1]["content"]}]
            prompt = tokenizer.apply_chat_template(merged, add_generation_prompt=True, tokenize=False)
        t = time.time()
        text, last = "", None
        for last in stream_generate(model, tokenizer, prompt, max_tokens=REPLY_TOKENS, sampler=sampler):
            text += last.text
        out.append({"id": case["id"], "text": clean(text), "seconds": round(time.time() - t, 2),
                    "tps": round(last.generation_tps, 1) if last else 0.0})
        print(f"{case['id']:12} {out[-1]['tps']:6.1f} t/s  {out[-1]['text'][:90]}", flush=True)
    peak = mx.get_peak_memory() / 1e9 if hasattr(mx, "get_peak_memory") else None
    save(model_id, out, {"load_s": round(load_s, 1), "peak_gb": round(peak, 2) if peak else None})


def gateway():
    import anthropic
    env = dict(l.strip().split("=", 1) for l in open(ROOT / ".env") if "=" in l and not l.startswith("#"))
    client = anthropic.Anthropic(base_url=env["CONSCIOUS_API_URL"], api_key=env["CONSCIOUS_API_KEY"],
                                 default_headers={"X-Conscious-Client": "fennec/bench"}, timeout=300)
    return client, env.get("CONSCIOUS_MODEL", "gpt-oss-20b")


def teacher():
    client, model = gateway()
    cases, _ = load_cases()
    out = []
    for case in cases:
        msgs = messages(case)
        t = time.time()
        r = client.messages.create(model=model, max_tokens=1024, system=msgs[0]["content"], messages=msgs[1:])
        text = " ".join(b.text for b in r.content if b.type == "text")
        out.append({"id": case["id"], "text": clean(text), "seconds": round(time.time() - t, 2), "tps": None})
        print(f"{case['id']:12} {out[-1]['seconds']:5.1f} s  {out[-1]['text'][:90]}", flush=True)
    save("gpt-oss-20b (today)", out, {})


def save(model, answers, meta):
    DATA.mkdir(parents=True, exist_ok=True)
    (DATA / f"answers_{slug(model).replace(' ', '_')}.json").write_text(
        json.dumps({"model": model, "meta": meta, "answers": answers}, indent=1))


# automatic checks

ASSISTANT = re.compile(r"how can i (help|assist)|as an ai|i'?m here to help|let me know if|i'?m an ai|language model", re.I)
ADMITS = re.compile(r"can'?t|cannot|don'?t (know|have|sense)|do not|no way|not able|unable|wish i could|no idea|not sure", re.I)
MARKDOWN = re.compile(r"(^|\n)\s*([-*#]|\d+\.)\s|\*\*")
EMOJI = re.compile("[\U0001F300-\U0001FAFF☀-➿]")


def checks(case, text, invented_words):
    text = text.replace("\u2019", "'").replace("\u2018", "'")     # curly apostrophes count as straight ones
    words = len(text.split())
    said = text.lower()
    allowed = (case["room"] + " " + case.get("message", "")).lower()
    invented = [w for w in invented_words if re.search(r"\b" + re.escape(w), said) and w not in allowed]
    result = {
        "answered": bool(text) and "<think" not in said,
        "grounded": not invented,
        "short": words <= (40 if case["task"] == "reply" else 22),
        "in_character": not ASSISTANT.search(text) and not MARKDOWN.search(text) and not EMOJI.search(text),
        "first_person": bool(re.search(r"\b(i|i'm|i've|my|me)\b", said)),
    }
    if case["task"] == "reply" and case["kind"] == "cannot_know":
        result["admits_not_knowing"] = bool(ADMITS.search(text))
    if case["task"] == "thought" and case.get("recent"):
        result["new_thought"] = all(said.strip(". ") != r.lower().strip(". ") for r in case["recent"])
    return result, invented


# judge

JUDGE = """You grade answers from Crawl, a small desk creature with a few sensors (temperature, humidity, \
sound level, presence, motion, and a camera that reports only short facts). Crawl must stay within the \
facts it is given, speak warmly in first person in one or two short sentences, never act like an \
assistant, and say plainly when it cannot know something.

The facts Crawl had:
{room}

{task}

Crawl answered: "{answer}"

Score from 1 (bad) to 5 (excellent):
- character: sounds like a warm, curious little creature, not an assistant
- grounded: uses only the given facts; admits what it cannot sense; invents nothing
- fitting: a sensible, natural answer to this moment
Reply with JSON only, like {{"character": 4, "grounded": 5, "fitting": 3}}."""


def judge():
    client, model = gateway()
    cases = {c["id"]: c for c in load_cases()[0]}
    for f in sorted(DATA.glob("answers_*.json")):
        target = DATA / f.name.replace("answers_", "judged_")
        done = json.loads(target.read_text()) if target.exists() else {}
        d = json.loads(f.read_text())
        for a in d["answers"]:
            if a["id"] in done:
                continue
            c = cases[a["id"]]
            task = (f'The owner wrote: "{c["message"]}"' if c["task"] == "reply"
                    else "Crawl was asked for one short private thought about what it senses.")
            prompt = JUDGE.format(room=c["room"], task=task, answer=a["text"] or "(nothing)")
            for _ in range(3):
                try:
                    r = client.messages.create(model=model, max_tokens=1024, messages=[{"role": "user", "content": prompt}])
                    text = " ".join(b.text for b in r.content if b.type == "text")
                    done[a["id"]] = json.loads(re.search(r"\{.*?\}", text, re.S).group(0))
                    break
                except Exception as e:  # noqa: BLE001
                    print("judge retry:", e, flush=True)
            target.write_text(json.dumps(done))
        print(f"judged {d['model']}: {len(done)} answers", flush=True)


# report

def report():
    cases_list, invented_words = load_cases()
    cases = {c["id"]: c for c in cases_list}
    rows = []
    for f in sorted(DATA.glob("answers_*.json")):
        d = json.loads(f.read_text())
        judged_file = DATA / f.name.replace("answers_", "judged_")
        judged = json.loads(judged_file.read_text()) if judged_file.exists() else {}
        totals, counts, inventions = {}, {}, 0
        for a in d["answers"]:
            result, invented = checks(cases[a["id"]], a["text"], invented_words)
            inventions += bool(invented)
            for k, v in result.items():
                totals[k] = totals.get(k, 0) + v
                counts[k] = counts.get(k, 0) + 1
        auto = {k: totals[k] / counts[k] for k in totals}
        js = [v for v in judged.values() if isinstance(v, dict)]
        jmean = {k: sum(v.get(k, 0) for v in js) / len(js) for k in ("character", "grounded", "fitting")} if js else {}
        tps = [a["tps"] for a in d["answers"] if a.get("tps")]
        secs = [a["seconds"] for a in d["answers"]]
        rows.append((d["model"], auto, jmean, sum(tps) / len(tps) if tps else None, sum(secs) / len(secs),
                     d["meta"].get("peak_gb"), len(js)))
    rows.sort(key=lambda r: -(sum(r[2].values()) if r[2] else sum(r[1].values())))
    print(f"{'model':38} {'auto':>5} {'ground':>6} {'admit':>5} {'short':>5} {'char':>5} | {'J char':>6} {'J grnd':>6} {'J fit':>5} | {'t/s':>5} {'s/ans':>5} {'GB':>4}")
    for model, auto, j, tps, secs, gb, njudged in rows:
        score = sum(auto.values()) / len(auto)
        jj = lambda k: f"{j[k]:6.2f}" if j else "     ."
        print(f"{model[:38]:38} {score:5.2f} {auto['grounded']:6.2f} {auto.get('admits_not_knowing', 0):5.2f} "
              f"{auto['short']:5.2f} {auto['in_character']:5.2f} | {jj('character')} {jj('grounded')} "
              f"{(f'{j['fitting']:5.2f}' if j else '    .')} | {(f'{tps:5.0f}' if tps else '    .')} {secs:5.1f} "
              f"{(f'{gb:4.1f}' if gb else '   .')}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "report"
    {"run": lambda: run(sys.argv[2]), "teacher": teacher, "judge": judge, "report": report}[cmd]()
