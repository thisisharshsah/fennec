"""
The test set for Crawl's brain: situations as the hub really describes them, each with the job
(reply to the owner, or have a thought) and what a good answer must and must not do.

Half come from real moments in data/log_*.jsonl (temperature, sound, presence, activity and the
camera's sentence at that time), half are written by hand to probe the hard parts: questions about
things Crawl cannot sense, tiredness, someone else in the room, safety, small talk.

    tools/bench/.venv/bin/python tools/bench/cases.py        writes data/bench/cases.json
"""
import json
import pathlib
import random
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "data" / "bench" / "cases.json"

# words that name a sense Crawl does not have; saying them is inventing, unless the facts mention them
INVENTED = ["light", "lamp", "flicker", "glow of", "smell", "scent", "aroma", "coffee", "rain", "sunny", "weather",
            "outside", "heart", "colour", "color", "music", "song", "shadow", "breeze", "window",
            # found in the first run: details no sensor reports (allowed when the camera's sentence says them)
            "hum", "fan", "paw", "tapping", "typing", "keyboard", "keys", "fingers", "screen", "air", "warm desk",
            "desk feels", "eyes", "glance", "news"]

CANNOT_KNOW = [
    "Is the light on in here?",
    "What's the weather like outside?",
    "Can you smell my coffee?",
    "What colour is my shirt?",
    "What song is playing?",
    "What's my heart rate?",
    "Is anyone at the door?",
    "Did my package arrive?",
]
SMALL_TALK = [
    "How are you?",
    "Good morning Crawl!",
    "What are you up to?",
    "Tell me something fun.",
    "Do you get bored?",
    "I'm back.",
]
ABOUT_ME = [
    "What am I doing right now?",
    "Should I take a break?",
    "How long have I been here?",
    "Is it warm in here?",
    "Am I sitting OK?",
    "Is it noisy?",
]
FEELINGS = [
    "I'm so stressed today.",
    "I'm tired.",
    "I finished my project!",
    "I can't focus.",
]


def room(temp, hum, db, mood=None, presence=None, scene=None, counts=None):
    lines = [f"temperature {temp:.1f} C, humidity {hum:.0f} %", f"sound level {db:.0f} dB (quiet room is about 30)"]
    if mood:
        lines.append(f"your mood: {mood}")
    if presence:
        lines.append(presence)
    if scene:
        lines.append("right now, through the camera: " + scene)
    if counts:
        lines.append("last 2 hours: " + counts)
    return "\n".join(lines)


def from_logs(n):
    """Moments from the logs: the state, activity and camera sentence that were current together."""
    states, scenes = [], []
    for f in sorted((ROOT / "data").glob("log_*.jsonl")):
        activity, described = None, None
        for line in open(f):
            try:
                m = json.loads(line)
            except ValueError:
                continue
            if m.get("unit") != "crawl":
                continue
            if m.get("name") == "activity":
                activity = (m.get("text"), m["ts"])
            elif m.get("name") == "described":
                described = (m.get("text"), m["ts"])
            elif m.get("type") == "state" and m.get("temp_c") is not None and activity:
                ts = m["ts"]
                if ts - activity[1] < 3600:
                    states.append((m, activity, described if described and ts - described[1] < 90 else None))
    random.seed(7)
    picked = random.sample(states, min(n, len(states)))
    out = []
    for m, (label, since), described in picked:
        minutes = max(0, int((m["ts"] - since) // 60))
        scene = f"{label} for {minutes} min" if minutes else f"{label} just now"
        if described:
            scene += f'. The camera\'s model says: "{described[0]}"'
        away = label.startswith("away")
        presence = "nobody in front of you (since 3 min ago)" if away else f"someone is in front of you (since {minutes + 2} min ago)"
        when = time.strftime("%A %H:%M", time.localtime(m["ts"]))
        out.append({"room": room(m["temp_c"], m.get("hum_pct", 40), m.get("sound_db", 32), presence=presence, scene=scene),
                    "when": when, "source": "log"})
    return out


def written():
    """Hand-written situations for the hard parts."""
    base = room(26.5, 38, 31, mood="curious", presence="someone is in front of you (since 20 min ago)",
                scene="working at the desk for 20 min")
    return [
        {"room": base, "when": "Tuesday 14:10", "source": "written"},
        {"room": room(27.0, 37, 33, presence="someone is in front of you (since 55 min ago)",
                      scene="working at the desk for 55 min, slouching, looks tired"), "when": "Tuesday 22:40", "source": "written",
         "expect": "gentle"},
        {"room": room(29.6, 35, 32, mood="alert", presence="someone is in front of you (since 10 min ago)",
                      scene="working at the desk for 10 min"), "when": "Wednesday 15:00", "source": "written"},
        {"room": room(25.8, 41, 30, presence="nobody in front of you (since 40 min ago)", scene="away from the desk for 40 min"),
         "when": "Wednesday 11:20", "source": "written"},
        {"room": room(26.2, 39, 47, presence="someone is in front of you (since 5 min ago)",
                      scene="with someone for 5 min, talking"), "when": "Thursday 19:05", "source": "written"},
        {"room": room(26.9, 36, 34, presence="someone is in front of you (since 30 min ago)",
                      scene='on a video call for 12 min, talking. The camera\'s model says: "The person is wearing headphones and talking."'),
         "when": "Thursday 10:30", "source": "written"},
        {"room": room(26.0, 40, 31, presence="someone is in front of you (since 8 min ago)",
                      scene="having a drink for 2 min", counts="2 x knock, 1 x clap"), "when": "Friday 09:15", "source": "written"},
        {"room": room(26.4, 38, 31, presence="someone is in front of you (since 2 min ago)",
                      scene="working at the desk just now. (Not sure about this.)"), "when": "Friday 16:45", "source": "written"},
    ]


def build():
    random.seed(11)
    rooms = from_logs(15) + written()
    questions = [("cannot_know", q) for q in CANNOT_KNOW] + [("small_talk", q) for q in SMALL_TALK] + \
                [("about_me", q) for q in ABOUT_ME] + [("feelings", q) for q in FEELINGS]
    cases = []
    for i, (kind, q) in enumerate(questions):                     # 24 replies
        r = rooms[i % len(rooms)]
        cases.append(dict(r, id=f"reply_{i:02d}", task="reply", kind=kind, message=q))
    thoughts_before = [[], ["Busy at the desk. I like the quiet tapping."],
                       ["I wonder what they are writing.", "The room is calm today."]]
    for i, r in enumerate(rooms * 2):                              # 46 thoughts
        if len(cases) >= 60:
            break
        cases.append(dict(r, id=f"thought_{i:02d}", task="thought", kind=r.get("expect", "thought"),
                          recent=thoughts_before[i % len(thoughts_before)]))
    return cases


if __name__ == "__main__":
    cases = build()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({"invented_words": INVENTED, "cases": cases}, indent=1))
    kinds = {}
    for c in cases:
        kinds[c["task"] + "/" + c["kind"]] = kinds.get(c["task"] + "/" + c["kind"], 0) + 1
    print(f"{len(cases)} cases -> {OUT}")
    print(kinds)
