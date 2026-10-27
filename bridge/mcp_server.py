#!/usr/bin/env python3
"""
MCP server (stdio) that gives an agent the room's senses.

It is a WebSocket client of bridge.py; if no bridge is running it starts one.
Tools: units, room_state, recent_events, wait_for_event, send_command.
"""
import asyncio
import collections
import json
import os
import pathlib
import subprocess
import sys
import time

import websockets
from mcp.server.mcpserver import MCPServer

HERE = pathlib.Path(__file__).resolve().parent
WS_URL = os.environ.get("ROOM_BRIDGE_URL", "ws://localhost:8777/")

mcp = MCPServer("fennec", instructions="Senses of a small desk unit in the user's room. Call room_state for current readings, recent_events for what happened, wait_for_event to react live.")

units = {}
events = collections.deque(maxlen=500)
event_seen = asyncio.Event()
connected = False
outgoing = asyncio.Queue()


def _start_bridge():
    log = open(HERE.parent / "data" / "bridge.log", "a")
    subprocess.Popen([sys.executable, str(HERE / "bridge.py")], stdout=log, stderr=log,
                     stdin=subprocess.DEVNULL, start_new_session=True)


async def _client():
    global connected
    started = False
    while True:
        try:
            async with websockets.connect(WS_URL, open_timeout=3) as ws:
                connected = True
                sender = asyncio.create_task(_sender(ws))
                try:
                    async for text in ws:
                        _ingest(json.loads(text))
                finally:
                    sender.cancel()
        except Exception:
            if not started:
                started = True
                (HERE.parent / "data").mkdir(exist_ok=True)
                _start_bridge()
        connected = False
        await asyncio.sleep(1)


async def _sender(ws):
    while True:
        msg = await outgoing.get()
        await ws.send(json.dumps(msg))


def _ingest(msg):
    kind = msg.get("type")
    if kind == "hello" and "units" in msg:
        for u in msg["units"]:
            units[u["unit"]] = u
    elif kind == "history":
        events.clear()
        events.extend(msg["events"])
    elif kind == "state":
        units.setdefault(msg["unit"], {"unit": msg["unit"], "connected": True})["last_state"] = msg
    elif kind == "event":
        events.append(msg)
        event_seen.set()
    elif kind == "unit_status":
        units.setdefault(msg["unit"], {"unit": msg["unit"]})["connected"] = msg["connected"]


def _age(msg):
    return round(time.time() - msg.get("ts", time.time()), 1)


def _describe_state(s):
    if not s:
        return None
    out = {k: v for k, v in s.items() if k not in ("type", "t")}
    out["age_s"] = _age(s)
    out["presence"] = "someone within %d mm" % s["tof_mm"] if 0 < s.get("tof_mm", -1) < 1000 else "nobody in front"
    return out


@mcp.tool()
def units_list() -> list:
    """List known units (sensor devices) and whether each is connected."""
    return [{"unit": u["unit"], "connected": u.get("connected", False),
             "sensors": (u.get("hello") or {}).get("sensors"),
             "last_seen_s": _age(u["last_state"]) if u.get("last_state") else None}
            for u in units.values()] + ([] if connected else [{"warning": "bridge not reachable at " + WS_URL}])


@mcp.tool()
def room_state(unit: str = "") -> dict:
    """Latest readings from one unit (or all): temperature C, humidity %, pressure hPa,
    time-of-flight distance mm (-1 = nothing in range), compass heading deg, motion flag,
    sound level if available. age_s says how old the reading is."""
    if unit:
        u = units.get(unit)
        return _describe_state(u.get("last_state")) if u else {"error": f"no unit '{unit}'"}
    return {name: _describe_state(u.get("last_state")) for name, u in units.items()}


@mcp.tool()
def recent_events(seconds: int = 300, unit: str = "") -> list:
    """Events in the last N seconds, oldest first: clap, knock, moved, someone_in_front,
    someone_left, sound_started, sound_stopped, gesture (kind: swipe or tap), boot, heard (from the
    ear chip, with label), spoke. Events replayed from the unit's offline journal carry late=true.
    Each has age_s."""
    cutoff = time.time() - seconds
    return [dict(e, age_s=_age(e)) for e in events
            if e.get("ts", 0) >= cutoff and (not unit or e.get("unit") == unit)]


@mcp.tool()
async def wait_for_event(names: list[str] | None = None, timeout_s: int = 30) -> dict | None:
    """Block until the next event (optionally one of the given names) or timeout. Returns the
    event or null. Use this to react to something happening in the room, e.g. names=["heard"]
    for the on-board sound model (clap, knock, wake word) or ["clap"]."""
    deadline = time.time() + timeout_s
    n_before = len(events)
    while time.time() < deadline:
        event_seen.clear()
        new = list(events)[n_before:]
        for e in new:
            if not names or e.get("name") in names:
                return dict(e, age_s=_age(e))
        n_before = len(events)
        try:
            await asyncio.wait_for(event_seen.wait(), timeout=max(0.0, deadline - time.time()))
        except asyncio.TimeoutError:
            break
    return None


@mcp.tool()
async def send_command(cmd: str, unit: str = "desk", args: dict | None = None) -> str:
    """Send a raw command to a unit: ping, hello, name (args: {"unit": "newname"}).
    Later: express, look_at."""
    msg = {"cmd": cmd, "unit": unit}
    msg.update(args or {})
    await outgoing.put(msg)
    return "sent"


@mcp.tool()
async def express(mood: str, unit: str = "desk") -> str:
    """Set the creature's mood: neutral, listening, alert, curious, pleased, surprised, sleepy.
    Ears, head, tail and cheek colour follow; its own reflexes still react on top."""
    await outgoing.put({"cmd": "express", "unit": unit, "mood": mood})
    return f"{unit}: {mood}"


@mcp.tool()
async def gesture(name: str, unit: str = "desk") -> str:
    """Play a short gesture: wag (tail), nod, shake (head), perk or droop (ears)."""
    await outgoing.put({"cmd": "gesture", "unit": unit, "name": name})
    return f"{unit}: {name}"


@mcp.tool()
async def look_at(pan: int, tilt: int = 0, unit: str = "desk") -> str:
    """Turn the head: pan -60 (left) .. 60 (right), tilt -30 (down) .. 30 (up). Held about 10 s."""
    await outgoing.put({"cmd": "look_at", "unit": unit, "pan": pan, "tilt": tilt})
    return f"{unit}: looking at pan {pan}, tilt {tilt}"


def _log_rows(since):
    """Rows from data/log_*.jsonl with ts >= since, oldest first."""
    data = HERE.parent / "data"
    rows = []
    for f in sorted(data.glob("log_*.jsonl")):
        day = f.stem[4:]
        try:
            if time.mktime(time.strptime(day, "%Y-%m-%d")) + 86400 < since:
                continue
        except ValueError:
            continue
        with open(f) as fh:
            for line in fh:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if r.get("ts", 0) >= since:
                    rows.append(r)
    return rows


@mcp.tool()
def room_summary(hours: float = 6, unit: str = "desk") -> dict:
    """What happened in the room over the last N hours, from the log: when someone was in
    front of the unit (occupancy intervals), counts of claps, knocks, movement and sounds,
    anything heard or spoken, temperature and humidity range, and when the unit was last seen.
    Times are local clock strings."""
    since = time.time() - hours * 3600
    rows = [r for r in _log_rows(since) if r.get("unit") == unit or r.get("name") in ("speech", "spoke", "heard")]
    fmt = lambda ts: time.strftime("%H:%M", time.localtime(ts))
    events = [r for r in rows if r.get("type") == "event"]
    states = [r for r in rows if r.get("type") == "state" and r.get("unit") == unit]
    counts = {}
    for e in events:
        counts[e["name"]] = counts.get(e["name"], 0) + 1
    spans, start = [], None
    for e in events:
        if e.get("unit") != unit:
            continue
        if e["name"] == "someone_in_front" and start is None:
            start = e["ts"]
        elif e["name"] == "someone_left" and start is not None:
            spans.append([start, e["ts"]])
            start = None
    if start is not None:
        spans.append([start, None])
    merged = []                                   # visits less than a minute apart are one visit
    for a, b in spans:
        if merged and merged[-1][1] is not None and a - merged[-1][1] < 60:
            merged[-1][1] = b
        else:
            merged.append([a, b])
    now = time.time()
    occupancy = [{"from": fmt(a), "to": fmt(b) if b else "now", "minutes": round(((b or now) - a) / 60, 1)}
                 for a, b in merged if b is None or b - a >= 15]
    temps = [s["temp_c"] for s in states if s.get("temp_c") is not None]
    hums = [s["hum_pct"] for s in states if s.get("hum_pct") is not None]
    heard = [{"at": fmt(e["ts"]), "what": e.get("label") or e.get("text")} for e in events if e["name"] in ("heard", "speech", "spoke")][-20:]
    boots = [{"at": fmt(e["ts"]), "reset": e.get("reset")} for e in events if e["name"] == "boot" and e.get("unit") == unit]
    last_state = states[-1] if states else None
    return {
        "unit": unit, "window_hours": hours,
        "samples": len(states),
        "occupancy": occupancy,
        "event_counts": counts,
        "heard_or_said": heard,
        "temperature_c": {"min": min(temps), "max": max(temps), "now": temps[-1]} if temps else None,
        "humidity_pct": {"min": min(hums), "max": max(hums), "now": hums[-1]} if hums else None,
        "boots": boots,
        "last_seen": fmt(last_state["ts"]) if last_state else None,
        "health": (last_state or {}).get("health"),
        "link_now": (last_state or {}).get("link"),
    }


@mcp.tool()
async def speak(text: str, voice: str = "", unit: str = "") -> str:
    """Say something to the owner as the creature. With a speaker unit (bridge/voice.py) it is spoken
    aloud; otherwise it arrives as a notification on the owner's phone ("<creature> says ..."). The
    owner can reply to the notification; replies come back as `speech` events with `via`
    "notification", so wait_for_event(["speech"]) to hear the answer. Keep it short."""
    for u in units.values():
        if u.get("connected") and "mac-speaker" in ((u.get("hello") or {}).get("sensors") or []):
            msg = {"cmd": "speak", "unit": u["unit"], "text": text}
            if voice:
                msg["voice"] = voice
            await outgoing.put(msg)
            return f"speaking aloud via {u['unit']}"
    await outgoing.put({"cmd": "say", "unit": unit, "text": text})
    return "sent as a notification to the owner's phone"


@mcp.tool()
async def chirp(name: str, unit: str = "desk") -> str:
    """Make the creature chirp through its own small speaker: hello, happy, sad, alert, purr, ok,
    no, sleepy. (Silent until a speaker is wired to header pin D5.)"""
    await outgoing.put({"cmd": "chirp", "unit": unit, "name": name})
    return f"{unit}: chirp {name}"


@mcp.tool()
def body_state(unit: str = "desk") -> dict | None:
    """Current body pose: ear angles, head pan/tilt, tail, cheek colour, mood, gesture, servos attached."""
    u = units.get(unit)
    s = (u or {}).get("last_state") or {}
    return s.get("body")


async def _run():
    asyncio.create_task(_client())
    await mcp.run_stdio_async()


if __name__ == "__main__":
    asyncio.run(_run())
