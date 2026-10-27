#!/usr/bin/env python3
"""
Bridge daemon: owns the unit's serial port, serves apps over WebSocket.

    bridge/.venv/bin/python bridge/bridge.py              # auto-detect the ST-LINK port
    bridge/.venv/bin/python bridge/bridge.py -p /dev/cu.usbmodem21203 -w 8777

Every message from the unit is forwarded to all WebSocket clients with
"unit" and "ts" added, and appended to data/log_<date>.jsonl.
Protocol: docs/protocol.md
"""
import argparse
import asyncio
import collections
import datetime as dt
import json
import logging
import pathlib
import socket
import sys
import time

import serial
import serial.tools.list_ports
import websockets

from life import Life
from zeroconf import ServiceInfo
from zeroconf.asyncio import AsyncZeroconf

BRIDGE_VERSION = "0.4.0"
QUIET_TIMEOUT_S = 10    # a unit silent this long is disconnected
LOG_KEEP_DAYS = 14
UNIT_PORT = 8778        # TCP, units over Wi-Fi
HTTP_PORT = 8776        # HTTP: POST /event or /state from simple devices (ear chip)
ST_VID = 0x0483
HISTORY = 200
log = logging.getLogger("bridge")


def find_port():
    ports = list(serial.tools.list_ports.comports())
    for p in ports:
        if p.vid == ST_VID:
            return p.device
    for p in ports:
        if "usbmodem" in p.device or "ttyACM" in p.device:
            return p.device
    return None


def lan_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


class Store:
    def __init__(self):
        self.lan_ip = "127.0.0.1"
        self.life_hook = None                 # set by main(): the daily-life rules see every message
        self.links = []                       # every Link ever opened; dead ones are pruned on claim
        self.units = {}                       # name -> {"connected", "last_state", "hello"}
        self.events = collections.deque(maxlen=500)
        self.clients = set()
        self.logfile = None

    def unit(self, name):
        return self.units.setdefault(name, {"unit": name, "connected": False, "last_state": None, "hello": None, "link": None})

    def claim(self, name, link):
        """One active link per unit name; a newer hello takes over, a dead link lets go."""
        u = self.unit(name)
        cur = u.get("_link")
        if cur is None or cur is link or not cur.alive:
            u["_link"] = link
            u["link"] = link.kind
            return True
        return False

    def release(self, name, link):
        u = self.units.get(name)
        if u and u.get("_link") is link:
            u["_link"] = None
            u["connected"] = False

    def hello_message(self):
        units = []
        for u in self.units.values():
            d = {k: v for k, v in u.items() if not k.startswith("_")}
            d["sensors"] = (u.get("hello") or {}).get("sensors")
            units.append(d)
        life = getattr(self, "life", None)
        return {"type": "hello", "bridge": BRIDGE_VERSION, "lan_ip": self.lan_ip, "unit_port": UNIT_PORT, "units": units,
                "life": bool(life and life.enabled)}

    def history_message(self):
        return {"type": "history", "events": list(self.events)[-HISTORY:]}

    def record(self, msg):
        u = self.unit(msg["unit"])
        kind = msg.get("type")
        if kind == "state":
            u["last_state"] = msg
        elif kind == "event":
            self.events.append(msg)
        elif kind == "hello":
            u["hello"] = msg
        elif kind == "unit_status":
            u["connected"] = msg["connected"]
        self._log(msg)

    def _log(self, msg):
        if msg.get("type") == "audio":        # raw training clips go to the requesting app only
            return
        day = dt.date.today().isoformat()
        path = pathlib.Path(__file__).resolve().parent.parent / "data" / f"log_{day}.jsonl"
        if self.logfile is None or self.logfile.name != str(path):
            path.parent.mkdir(exist_ok=True)
            if self.logfile:
                self.logfile.close()
            self.logfile = open(path, "a", buffering=1)
        self.logfile.write(json.dumps(msg) + "\n")

    async def broadcast(self, msg):
        self.record(msg)
        if self.life_hook:
            await self.life_hook(msg)
        if not self.clients:
            return
        text = json.dumps(msg)
        dead = []
        for ws in list(self.clients):          # a client may leave while we await
            try:
                await ws.send(text)
            except Exception:
                dead.append(ws)
        for ws in dead:
            self.clients.discard(ws)


class Link:
    """One transport to one unit. Subclasses deliver raw lines to _handle()."""
    kind = "?"

    def __init__(self, store):
        self.store = store
        self.name = None
        self.alive = False
        store.links = [l for l in store.links if l.alive] + [self]

    async def send(self, msg):
        return False

    async def _status(self, connected):
        if self.name:
            await self.store.broadcast({"type": "unit_status", "unit": self.name, "link": self.kind,
                                        "connected": connected, "ts": time.time()})

    last_rx = 0.0

    async def _handle(self, raw):
        self.last_rx = time.time()
        line = raw.decode("ascii", "replace").strip()
        if not line:
            return
        if not line.startswith("{"):
            log.info("%s says: %s", self.name or self.kind, line)
            return
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            log.debug("bad line: %s", line)
            return
        if msg.get("type") == "hello" and msg.get("unit"):
            if self.name != msg["unit"]:
                if self.name:
                    old = self.name
                    self.store.release(old, self)
                    # a unit that renamed itself: forget the old name unless another live link still uses it
                    if not any(l.alive and l.name == old and l is not self for l in self.store.links):
                        self.store.units.pop(old, None)
                        log.info("unit '%s' is now '%s'", old, msg["unit"])
                        remember_rename(old, msg["unit"])
                self.name = msg["unit"]
                self.store.unit(self.name)["_link"] = None       # a new hello takes over the name
                log.info("%s link is unit '%s'", self.kind, self.name)
                if self.kind == "wifi":
                    await self.send({"cmd": "ping"})              # the first line into a fresh link tends to be lost; spend it
        if not self.name:
            return                                                  # nothing before the hello
        if msg.get("type") == "audio":                              # clips come over the cable even when Wi-Fi is active
            msg["unit"] = self.name
            msg["link"] = self.kind
            await self.store.broadcast(msg)
            return
        if not self.store.claim(self.name, self):
            return                                                  # another link is active for this unit
        u = self.store.unit(self.name)
        if not u["connected"]:
            u["connected"] = True
            await self.store.broadcast({"type": "unit_status", "unit": self.name, "link": self.kind,
                                        "connected": True, "ts": time.time()})
        msg["unit"] = self.name
        msg["link"] = self.kind
        msg["ts"] = time.time()
        if msg.get("late") and isinstance(msg.get("age_s"), (int, float)) and msg["age_s"] >= 0:
            msg["ts"] -= msg["age_s"]                            # replayed from the unit's offline journal
        if msg.get("type") == "hello" and isinstance(msg.get("acked"), int):
            if msg["acked"] > u.get("_seq", 0):                   # the unit's own record of what was confirmed
                u["_seq"] = msg["acked"]
                u["_gaps"] = {x for x in u.get("_gaps", set()) if x > msg["acked"]}
        if msg.get("type") == "event":
            seq = msg.get("seq")
            if isinstance(seq, int) and seq > 0:                   # acknowledge only gap-free sequences
                contig = u.get("_seq", 0)
                gaps = u.setdefault("_gaps", set())
                if msg.get("late") and (seq <= contig or seq in gaps):
                    log.debug("dropping replay of %s seq %d: already seen", msg["name"], seq)
                    return                                           # a replay of something that did arrive
                if seq > contig:
                    gaps.add(seq)
                while contig + 1 in gaps:
                    contig += 1
                    gaps.discard(contig)
                u["_seq"] = contig
            if msg.get("late"):
                log.info("late event %s from %s (age %ss)", msg["name"], self.name, msg.get("age_s"))
            else:
                log.info("event %s (%s)", msg["name"], self.kind)
            if msg["name"] == "heard" and msg.get("label") == "creature":
                asyncio.create_task(nudge_body(self.store, "alert", "perk"))   # the ear heard its name: the body reacts
        elif msg.get("type") == "status":
            log.info("unit status: %s", {k: v for k, v in msg.items() if k not in ("type", "t", "ts", "link")})
        await self.store.broadcast(msg)


class SerialLink(Link):
    kind = "serial"

    def __init__(self, store, port, baud):
        super().__init__(store)
        self.port_arg, self.baud = port, baud
        self.ser = None
        self.tx = asyncio.Queue()

    async def run(self):
        loop = asyncio.get_running_loop()
        while True:
            port = self.port_arg or find_port()
            if not port:
                await asyncio.sleep(2)
                continue
            try:
                self.ser = serial.Serial(port, self.baud, timeout=0.5)
            except serial.SerialException as e:
                log.warning("open %s failed: %s", port, e)
                await asyncio.sleep(2)
                continue
            log.info("serial unit on %s", port)
            self.ser.reset_input_buffer()
            self.alive = True
            await self.send({"cmd": "hello"})
            writer = asyncio.create_task(self._writer())
            try:
                buf = b""
                while True:
                    # bulk reads: pyserial's readline() goes byte by byte and cannot keep up with audio clips
                    data = await loop.run_in_executor(None, self._read_some)
                    if not data:
                        continue
                    buf += data
                    while b"\n" in buf:
                        raw, buf = buf.split(b"\n", 1)
                        if raw:
                            await self._handle(raw)
                    if len(buf) > 65536:
                        buf = b""
            except (serial.SerialException, OSError) as e:
                log.warning("serial unit lost: %s", e)
            finally:
                writer.cancel()
                self.alive = False
                try:
                    self.ser.close()
                except Exception:
                    pass
                self.ser = None
                if self.name:
                    self.store.release(self.name, self)
                await self._status(False)
            await asyncio.sleep(1)

    def _read_some(self):
        ser = self.ser
        if ser is None:
            raise serial.SerialException("closed")
        n = ser.in_waiting
        return ser.read(n if n > 0 else 1)

    async def _writer(self):
        loop = asyncio.get_running_loop()
        while True:
            msg = await self.tx.get()
            if self.ser:
                data = (json.dumps(msg) + "\n").encode()
                await loop.run_in_executor(None, self.ser.write, data)

    async def send(self, msg):
        await self.tx.put(msg)
        return True


class TcpLink(Link):
    """A unit that connected to us over Wi-Fi. The unit polls for our lines every
    2 s, so a command takes up to that long to land."""
    kind = "wifi"

    COALESCE_S = 0.3      # the module hands the unit one segment per 2 s poll: send queued lines as one segment

    def __init__(self, store, reader, writer):
        super().__init__(store)
        self.reader, self.writer = reader, writer
        self.peer = writer.get_extra_info("peername")
        self.pending = []
        self.flusher = None

    async def send(self, msg):
        if not self.alive:
            return False
        self.pending.append(json.dumps(msg))
        if self.flusher is None or self.flusher.done():
            self.flusher = asyncio.create_task(self._flush_later())
        return True

    async def _flush_later(self):
        await asyncio.sleep(self.COALESCE_S)
        lines, self.pending = self.pending, []
        log.debug("wifi tx to %s: %d line(s)", self.name or self.peer, len(lines))
        try:
            self.writer.write(("\n".join(lines) + "\n").encode())
            await self.writer.drain()
        except (ConnectionError, OSError):
            log.warning("wifi unit %s: write failed", self.name or self.peer)

    async def run(self):
        log.info("wifi unit connected from %s", self.peer)
        self.alive = True
        self.last_rx = time.time()
        try:
            while True:
                try:
                    raw = await asyncio.wait_for(self.reader.readline(), QUIET_TIMEOUT_S)
                except asyncio.TimeoutError:
                    log.warning("wifi unit %s silent for %ds; dropping the link", self.name or self.peer, QUIET_TIMEOUT_S)
                    break
                if not raw:
                    break
                await self._handle(raw)
        except (ConnectionError, OSError) as e:
            log.warning("wifi unit %s lost: %s", self.name or self.peer, e)
        finally:
            self.alive = False
            if self.name:
                self.store.release(self.name, self)
            await self._status(False)
            self.writer.close()
            log.info("wifi unit %s gone", self.name or self.peer)


class HttpUnits:
    """Minimal HTTP ingest for devices that cannot hold a TCP line stream:
         POST /event  {"unit":"ear","name":"heard","label":"creature","score":0.9}
         POST /state  {"unit":"ear","sound_db":41}
         POST /hello  {"unit":"ear","fw":"esphome","sensors":["mic"]}
       Each device appears as a unit with link "http"."""

    def __init__(self, store):
        self.store = store
        self.links = {}

    async def handle(self, reader, writer):
        try:
            head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 5)
            lines = head.decode("latin1").split("\r\n")
            method, path, *_ = lines[0].split(" ")
            length = 0
            for h in lines[1:]:
                if h.lower().startswith("content-length:"):
                    length = int(h.split(":", 1)[1])
            body = await asyncio.wait_for(reader.readexactly(length), 5) if length else b""
            status, reply = await self._dispatch(method, path, body)
        except Exception as e:  # noqa: BLE001
            status, reply = 400, json.dumps({"error": str(e)})
        text = f"HTTP/1.1 {status} {'OK' if status == 200 else 'Bad Request'}\r\nContent-Type: application/json\r\nContent-Length: {len(reply)}\r\nConnection: close\r\n\r\n{reply}"
        writer.write(text.encode())
        try:
            await writer.drain()
        finally:
            writer.close()

    async def _dispatch(self, method, path, body):
        if method != "POST" or path not in ("/event", "/state", "/hello"):
            return 404, json.dumps({"error": "POST /event, /state or /hello"})
        msg = json.loads(body or b"{}")
        unit = msg.pop("unit", None) or "http-device"
        link = self.links.get(unit)
        if link is None:
            link = HttpLink(self.store, unit)
            self.links[unit] = link
        kind = path[1:]
        if kind == "hello":
            msg = dict(msg, type="hello", unit=unit)
        else:
            msg = dict(msg, type=kind)
            msg.setdefault("t", int(time.time() * 1000) % 1000000000)
        await link.deliver(msg)
        return 200, json.dumps({"ok": True, "unit": unit})


class HttpLink(Link):
    kind = "http"

    def __init__(self, store, name):
        super().__init__(store)
        self.name = name
        self.alive = True
        store.unit(name)

    async def deliver(self, msg):
        if msg.get("type") == "hello":
            self.store.unit(self.name)["_link"] = None
        await self._handle(json.dumps(msg).encode())


def body_unit(store):
    """The unit that has a body: the one whose hello lists the IMU."""
    for u in store.units.values():
        if "lsm6dsl" in ((u.get("hello") or {}).get("sensors") or []) and u.get("connected"):
            return u["unit"]
    return None


async def nudge_body(store, mood, gesture):
    unit = body_unit(store)
    if not unit:
        return
    await route_command(store, {"cmd": "express", "unit": unit, "mood": mood})
    await route_command(store, {"cmd": "gesture", "unit": unit, "name": gesture})


async def route_command(store, msg):
    """Commands prefer the serial link (instant); over Wi-Fi the unit polls every 2 s."""
    unit = msg.get("unit") or next(iter(store.units), None)
    via = msg.get("via")                                    # optional: force "serial" or "wifi"
    cmd = {k: v for k, v in msg.items() if k not in ("unit", "via")}
    alive = [l for l in store.links if l.alive and l.name == unit]
    order = ["serial", "wifi"] if via != "wifi" else ["wifi", "serial"]
    if via in ("serial", "wifi"):
        alive = [l for l in alive if l.kind == via]
    link = next((l for k in order for l in alive if l.kind == k), None)
    if link is None:
        log.warning("command %s: no live link for unit '%s'", cmd.get("cmd"), unit)
        return
    if not await link.send(cmd):
        log.warning("command %s: send over %s failed", cmd.get("cmd"), link.kind)
    else:
        log.info("command %s -> %s (%s)", cmd.get("cmd"), unit, link.kind)


RENAMES_FILE = pathlib.Path(__file__).resolve().parent.parent / "data" / "renames.json"


def remember_rename(old, new):
    """Keep old -> new names so a unit's history survives a rename."""
    try:
        renames = json.loads(RENAMES_FILE.read_text())
    except (OSError, ValueError):
        renames = {}
    if old != new and renames.get(new) != old:            # ignore a straight swap back
        renames[old] = new
        renames.pop(new, None)
        RENAMES_FILE.write_text(json.dumps(renames, indent=1))


def names_for(unit):
    """The unit's current name plus every earlier name it had."""
    try:
        renames = json.loads(RENAMES_FILE.read_text())
    except (OSError, ValueError):
        renames = {}
    names, frontier = {unit}, [unit]
    while frontier:
        n = frontier.pop()
        for old, new in renames.items():
            if new == n and old not in names:
                names.add(old)
                frontier.append(old)
    return names


SERIES_FIELDS = {"temp_c", "hum_pct", "press_hpa", "tof_mm", "sound_db", "heading_deg"}
SERIES_MAX_POINTS = 360


def read_series(unit, field, since, until):
    """Downsampled (ts, value) pairs for one unit's state field from data/log_*.jsonl."""
    data = pathlib.Path(__file__).resolve().parent.parent / "data"
    raw = []
    keys = [f'"unit": "{n}"' for n in names_for(unit)]
    for f in sorted(data.glob("log_*.jsonl")):
        try:
            day = time.mktime(time.strptime(f.stem[4:], "%Y-%m-%d"))
        except ValueError:
            continue
        if day + 86400 < since or day > until:
            continue
        with open(f) as fh:
            for line in fh:
                if '"state"' not in line or not any(k in line for k in keys):
                    continue
                try:
                    m = json.loads(line)
                except ValueError:
                    continue
                ts, v = m.get("ts"), m.get(field)
                if ts is None or v is None or ts < since or ts > until:
                    continue
                if field == "tof_mm" and v < 0:
                    continue
                raw.append((ts, float(v)))
    if len(raw) <= SERIES_MAX_POINTS:
        return [[round(t, 1), round(v, 3)] for t, v in raw]
    since = raw[0][0]                                          # bucket over the span that has data
    bucket = (until - since) / SERIES_MAX_POINTS              # average into equal time buckets
    out, i = [], 0
    for b in range(SERIES_MAX_POINTS):
        lo, hi = since + b * bucket, since + (b + 1) * bucket
        vals = []
        while i < len(raw) and raw[i][0] < hi:
            if raw[i][0] >= lo:
                vals.append(raw[i][1])
            i += 1
        if vals:
            out.append([round((lo + hi) / 2, 1), round(sum(vals) / len(vals), 3)])
    return out


def read_messages(since, until, unit=None):
    """The conversation from the log: what creatures said (notices) and the owner's replies."""
    data = pathlib.Path(__file__).resolve().parent.parent / "data"
    out = []
    for f in sorted(data.glob("log_*.jsonl")):
        try:
            day = time.mktime(time.strptime(f.stem[4:], "%Y-%m-%d"))
        except ValueError:
            continue
        if day + 86400 < since or day > until:
            continue
        with open(f) as fh:
            for line in fh:
                if '"notice"' not in line and '"notification"' not in line:
                    continue
                try:
                    m = json.loads(line)
                except ValueError:
                    continue
                if m.get("type") != "event" or not (since <= m.get("ts", 0) <= until):
                    continue
                if unit and m.get("unit") != unit:
                    continue
                if m.get("name") == "notice":
                    out.append({"id": f'{m.get("unit")}|{m["ts"]}|notice', "unit": m.get("unit"), "ts": m["ts"],
                                "from": "creature", "kind": m.get("kind"), "text": m.get("text", "")})
                elif m.get("name") == "speech" and m.get("via") == "notification":
                    out.append({"id": f'{m.get("unit")}|{m["ts"]}|reply', "unit": m.get("unit"), "ts": m["ts"],
                                "from": "owner", "kind": "reply", "text": m.get("text", "")})
    return out


async def answer_messages(ws, msg):
    until = time.time()
    since = until - float(msg.get("days", 14)) * 86400
    loop = asyncio.get_running_loop()
    items = await loop.run_in_executor(None, read_messages, since, until, msg.get("unit"))
    await ws.send(json.dumps({"type": "messages", "items": items}))


async def answer_series(ws, msg):
    field = msg.get("field")
    unit = msg.get("unit")
    if field not in SERIES_FIELDS or not unit:
        await ws.send(json.dumps({"type": "series", "error": "bad field or unit", "request": msg.get("request")}))
        return
    until = time.time()
    since = until - float(msg.get("seconds", 3600))
    loop = asyncio.get_running_loop()
    points = await loop.run_in_executor(None, read_series, unit, field, since, until)
    await ws.send(json.dumps({"type": "series", "unit": unit, "field": field, "since": since, "until": until,
                              "request": msg.get("request"), "points": points}))


async def ws_handler(ws, store, serial_link):
    store.clients.add(ws)
    log.info("app connected (%d)", len(store.clients))
    try:
        await ws.send(json.dumps(store.hello_message()))
        await ws.send(json.dumps(store.history_message()))
        async for text in ws:
            try:
                msg = json.loads(text)
            except json.JSONDecodeError:
                continue
            if msg.get("cmd") == "series":                   # answered by the hub from its log, not sent to a unit
                await answer_series(ws, msg)
            elif msg.get("cmd") == "messages":               # conversation history from the log
                await answer_messages(ws, msg)
            elif msg.get("cmd") == "say":                    # the creature "says" something: a notice on the phone
                await creature_says(store, msg.get("unit") or body_unit(store) or "creature", str(msg.get("text", ""))[:300])
            elif msg.get("cmd") == "reply":                  # the owner answered a notification: like speech to the creature
                text = str(msg.get("text", "")).strip()[:300]
                if text:
                    await store.broadcast({"type": "event", "unit": msg.get("unit") or "phone", "link": "hub",
                                           "name": "speech", "text": text, "via": "notification", "t": 0, "ts": time.time()})
            elif msg.get("cmd") == "life":                   # daily-life rules on or off, kept across restarts
                life = getattr(store, "life", None)
                if life is not None and "on" in msg:
                    life.enabled = bool(msg["on"])
                    LIFE_FILE.write_text(json.dumps({"enabled": life.enabled}))
                await ws.send(json.dumps({"type": "life", "enabled": bool(life and life.enabled)}))
            elif "cmd" in msg:
                await route_command(store, msg)
    except websockets.ConnectionClosed:
        pass
    finally:
        store.clients.discard(ws)
        log.info("app left (%d)", len(store.clients))


async def register_bonjour(port):
    zc = AsyncZeroconf()
    ip = lan_ip()
    info = ServiceInfo(
        "_roomcreature._tcp.local.",
        f"{socket.gethostname().split('.')[0]}._roomcreature._tcp.local.",
        addresses=[socket.inet_aton(ip)], port=port,
        properties={"version": BRIDGE_VERSION},
    )
    try:
        await asyncio.wait_for(zc.async_register_service(info), 5)
    except Exception as e:
        log.warning("bonjour registration failed: %s", e)
    return zc, ip


LIFE_FILE = pathlib.Path(__file__).resolve().parent.parent / "data" / "life.json"


NOTIFY_FILE = pathlib.Path(__file__).resolve().parent.parent / "data" / "notify.json"


def notify_config():
    """{"ntfy_topic": "...", "ntfy_server": "https://ntfy.sh"}; absent or empty topic means off."""
    try:
        cfg = json.loads(NOTIFY_FILE.read_text())
    except (OSError, ValueError):
        return None
    return cfg if cfg.get("ntfy_topic") else None


def push_notice(unit, kind, text):
    """Relay a notice to the owner's phone through ntfy, when configured. Runs in a thread."""
    cfg = notify_config()
    if not cfg:
        return
    import urllib.request
    url = cfg.get("ntfy_server", "https://ntfy.sh").rstrip("/") + "/" + cfg["ntfy_topic"]
    title = {"say": f"{unit.capitalize()} says", "greet": "Welcome back", "morning": "Good morning",
             "break": "Break time", "warm": "Warm room", "goodnight": "Goodnight"}.get(kind, unit.capitalize())
    req = urllib.request.Request(url, data=text.encode(), method="POST",
                                 headers={"Title": title.encode().decode("latin1", "ignore"), "Tags": "fox_face"})
    try:
        urllib.request.urlopen(req, timeout=5).read()
    except Exception as e:
        log.warning("ntfy push failed: %s", e)


async def post_notice(store, unit, kind, text):
    log.info("notice: %s %s: %s", unit, kind, text)
    await store.broadcast({"type": "event", "unit": unit, "link": "hub", "name": "notice",
                           "kind": kind, "text": text, "t": 0, "ts": time.time()})
    asyncio.get_running_loop().run_in_executor(None, push_notice, unit, kind, text)


async def creature_says(store, unit, text):
    if not text:
        return
    await route_command(store, {"cmd": "chirp", "unit": unit, "name": "hello"})   # silent until a speaker is fitted
    await post_notice(store, unit, "say", text)


async def run_life(store, life, actions, notices):
    for unit, cmd in actions:
        await route_command(store, dict(cmd, unit=unit))
    for unit, kind, text in notices:
        await post_notice(store, unit, kind, text)


async def life_loop(store, life):
    while True:
        await asyncio.sleep(15)
        try:
            await run_life(store, life, *life.tick())
        except Exception as e:  # never let a rule take the hub down
            log.warning("life tick failed: %s", e)


def load_life_enabled():
    try:
        return bool(json.loads(LIFE_FILE.read_text()).get("enabled", True))
    except (OSError, ValueError):
        return True


async def housekeeping(store):
    """Acks to units, serial units that go quiet, and old log files."""
    while True:
        await asyncio.sleep(5)
        now = time.time()
        for l in list(store.links):                      # tell every unit what we have seen so far
            if l.alive and l.name and l.kind in ("serial", "wifi"):
                seq = store.units.get(l.name, {}).get("_seq", 0)
                await l.send({"cmd": "ack", "seq": seq})
        for l in list(store.links):
            if l.kind == "serial" and l.alive and l.name and l.last_rx and now - l.last_rx > QUIET_TIMEOUT_S:
                u = store.units.get(l.name)
                if u and u.get("_link") is l and u.get("connected"):
                    log.warning("serial unit %s silent for %ds", l.name, QUIET_TIMEOUT_S)
                    store.release(l.name, l)
                    await store.broadcast({"type": "unit_status", "unit": l.name, "link": l.kind, "connected": False, "ts": now})
        if int(now) % 3600 < 5:
            data = pathlib.Path(__file__).resolve().parent.parent / "data"
            for f in data.glob("log_*.jsonl"):
                if now - f.stat().st_mtime > LOG_KEEP_DAYS * 86400:
                    f.unlink(missing_ok=True)
                    log.info("removed old log %s", f.name)


async def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-p", dest="port", help="serial port (default: auto-detect ST-LINK)")
    ap.add_argument("-b", dest="baud", type=int, default=921600)
    ap.add_argument("-w", dest="ws_port", type=int, default=8777)
    ap.add_argument("-v", dest="verbose", action="store_true")
    args = ap.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s", datefmt="%H:%M:%S")

    store = Store()
    serial_link = SerialLink(store, args.port, args.baud)
    zc, ip = await register_bonjour(args.ws_port)
    store.lan_ip = ip

    async def on_unit(reader, writer):
        await TcpLink(store, reader, writer).run()

    tcp_server = await asyncio.start_server(on_unit, "0.0.0.0", UNIT_PORT)
    http_units = HttpUnits(store)
    http_server = await asyncio.start_server(http_units.handle, "0.0.0.0", HTTP_PORT)
    async with websockets.serve(lambda ws: ws_handler(ws, store, serial_link), "0.0.0.0", args.ws_port), tcp_server, http_server:
        log.info("bridge %s  apps: ws://%s:%d/  units: tcp %s:%d, http://%s:%d/event", BRIDGE_VERSION, ip, args.ws_port, ip, UNIT_PORT, ip, HTTP_PORT)
        keeper = asyncio.create_task(housekeeping(store))
        life = Life()
        life.enabled = load_life_enabled()
        store.life = life

        async def hook(msg):
            try:
                await run_life(store, life, *life.observe(msg))
            except Exception as e:
                log.warning("life rule failed: %s", e)
        store.life_hook = hook
        lifer = asyncio.create_task(life_loop(store, life))
        log.info("daily life %s", "on" if life.enabled else "off")
        try:
            await serial_link.run()
        finally:
            keeper.cancel()
            lifer.cancel()
            await zc.async_unregister_all_services()
            await zc.async_close()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
