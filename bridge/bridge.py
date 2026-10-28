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
import math
import os
import signal
import pathlib
import socket
import sys
import time

import serial
import serial.tools.list_ports
import websockets

from life import Life
from brain import Brain
from eye_control import EyeControl
from scene import LABELS as ACTIVITY_LABELS, Scene
from safety import Safety
from mind import Mind
import security
from zeroconf import ServiceInfo
from zeroconf.asyncio import AsyncZeroconf

BRIDGE_VERSION = "0.5.0"
QUIET_TIMEOUT_S = 10    # a unit silent this long is disconnected
LOG_KEEP_DAYS = 14
UNIT_PORT = 8778        # TCP, units over Wi-Fi
HTTP_PORT = 8776        # HTTP: POST /event or /state from simple devices (ear chip); token or loopback
SECURE_PORT = 8779      # TLS WebSocket for apps on the network; plain 8777 listens on this Mac only
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
        self.devices = security.Devices()
        self.unit_keys = security.UnitKeys()
        self.links = []                       # every Link ever opened; dead ones are pruned on claim
        self.units = {}                       # name -> {"connected", "last_state", "hello"}
        self.events = collections.deque(maxlen=500)
        self.clients = set()
        self.picture_clients = set()          # apps that asked for the eye's live picture (cmd "picture")
        self.picture_once = set()             # clients that asked for one picture (cmd "snapshot")
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
        eye = getattr(self, "eye", None)
        hello = {"type": "hello", "bridge": BRIDGE_VERSION, "lan_ip": self.lan_ip, "unit_port": UNIT_PORT, "units": units,
                 "life": bool(life and life.enabled)}
        if eye is not None:
            hello["eye"] = {k: v for k, v in eye.status().items() if k != "type"}
        safety = getattr(self, "safety", None)
        if safety is not None:
            hello["safety"] = {k: v for k, v in safety.status().items() if k != "type"}
        return hello

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
        if msg.get("type") in ("audio", "vision"):   # raw clips and the eye's live outline are not kept
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
                        self.store.unit_keys.rename(old, msg["unit"])
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
        if msg.get("type") == "hello" and self.kind == "serial" and msg.get("unit"):
            unit = msg["unit"]
            if not msg.get("keyed") or self.store.unit_keys.get(unit) is None:
                key = self.store.unit_keys.get(unit) or self.store.unit_keys.new(unit)
                await self.send({"cmd": "set_key", "key": key.hex()})
                log.info("gave unit '%s' its signing key over the cable", unit)
        if msg.get("type") == "hello" and self.kind == "wifi" and msg.get("unit"):
            key = self.store.unit_keys.get(msg["unit"])
            if key is not None:                          # a known creature must prove it, whatever it claims
                if not msg.get("keyed") or not security.hello_auth_ok(key, msg.get("nonce", ""), msg["unit"], msg.get("auth")):
                    log.warning("wifi hello for '%s' from %s failed authentication; dropping it", msg["unit"],
                                getattr(self, "peer", "?"))
                    self.reject = True
                    return
                if msg.get("nonce", "") != getattr(self, "nonce", None):     # a new connection on the unit's side
                    self.cmd_n = 0
                self.nonce, self.signing_key = msg.get("nonce", ""), key
        if getattr(self, "reject", False):
            return
        if msg.get("type") == "event" and msg.get("name") == "button" and not msg.get("late"):
            self.store.devices.open_window("button")
            log.info("pairing window open for %ds (button on %s)", security.PAIRING_WINDOW_S, self.name)
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
        if getattr(self, "signing_key", None):                # a keyed creature only obeys signed lines
            signed = []
            for line in lines:
                self.cmd_n += 1
                signed.append(security.sign_line(self.signing_key, self.nonce, self.cmd_n, line))
            lines = signed
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
                if getattr(self, "reject", False):
                    break
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
         POST /vision {"unit":"eye","bodies":[[x,y,w,h]],...}   live outline for the apps, not logged
         POST /picture {"unit":"eye","jpeg":"<base64>"}         live picture, only to apps watching, never kept
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
            headers = {}
            for h in lines[1:]:
                if ":" in h:
                    k, v = h.split(":", 1)
                    headers[k.strip()] = v.strip()
                if h.lower().startswith("content-length:"):
                    length = int(h.split(":", 1)[1])
            body = await asyncio.wait_for(reader.readexactly(length), 5) if length else b""
            peer = (writer.get_extra_info("peername") or ("", 0))[0]
            if not security.is_loopback(peer) and not self.store.devices.check(security.bearer(headers)):
                status, reply = 401, json.dumps({"error": "pair this device first (token required)"})
            else:
                status, reply = await self._dispatch(method, path, body)
        except Exception as e:  # noqa: BLE001
            status, reply = 400, json.dumps({"error": str(e)})
        reason = {200: "OK", 401: "Unauthorized", 404: "Not Found"}.get(status, "Bad Request")
        text = f"HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {len(reply)}\r\nConnection: close\r\n\r\n{reply}"
        writer.write(text.encode())
        try:
            await writer.drain()
        finally:
            writer.close()

    async def _dispatch(self, method, path, body):
        if method != "POST" or path not in ("/event", "/state", "/hello", "/vision", "/picture"):
            return 404, json.dumps({"error": "POST /event, /state, /hello, /vision or /picture"})
        msg = json.loads(body or b"{}")
        if path == "/picture":
            await send_picture(self.store, msg)
            return 200, json.dumps({"ok": True, "watching": len(self.store.picture_clients)})
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
            if kind == "vision":
                msg["for"] = body_unit(self.store)       # the creature whose eye this stands in for
        await link.deliver(msg)
        reply = {"ok": True, "unit": unit}
        if kind == "vision":
            reply["picture"] = bool(self.store.picture_clients or self.store.picture_once)   # only while someone watches
        return 200, json.dumps(reply)


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


async def send_picture(store, msg):
    """The eye's live picture: straight to the apps that asked for it. Not broadcast, not logged, not kept."""
    jpeg = msg.get("jpeg")
    targets = store.picture_clients | store.picture_once
    if not isinstance(jpeg, str) or not targets:
        return
    store.picture_once.clear()                       # a snapshot is one picture
    text = json.dumps({"type": "picture", "unit": msg.get("unit", "eye"), "for": body_unit(store),
                       "jpeg": jpeg, "ts": time.time()})
    for ws in targets:
        try:
            await ws.send(text)
        except Exception:
            store.picture_clients.discard(ws)


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
                if '"notice"' not in line and '"notification"' not in line and '"gesture"' not in line \
                        and '"thought"' not in line:
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
                elif m.get("name") == "thought":
                    out.append({"id": f'{m.get("unit")}|{m["ts"]}|thought', "unit": m.get("unit"), "ts": m["ts"],
                                "from": "creature", "kind": "thought", "text": m.get("text", "")})
                elif m.get("name") == "speech" and m.get("via") in ("notification", "gesture"):
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


async def untrusted_session(ws, store):
    """A network client without a valid token: it may only pair, and only while the window is open."""
    await ws.send(json.dumps({"type": "auth_required", "pairing_open": store.devices.window_open(),
                              "fingerprint": security.certificate_fingerprint()}))
    async for text in ws:
        try:
            msg = json.loads(text)
        except json.JSONDecodeError:
            continue
        if msg.get("cmd") == "pair":
            result = store.devices.pair(msg.get("name", "device"), msg.get("kind", "app"))
            if result:
                device_id, token = result
                log.info("paired new device %s (%s)", device_id, msg.get("name"))
                await ws.send(json.dumps({"type": "paired", "device_id": device_id, "token": token,
                                          "fingerprint": security.certificate_fingerprint()}))
                await store.broadcast({"type": "event", "unit": "hub", "link": "hub", "name": "device_paired",
                                       "text": str(msg.get("name", "device"))[:60], "t": 0, "ts": time.time()})
            else:
                await ws.send(json.dumps({"type": "pair_refused",
                                          "reason": "Press the blue button on your creature, then try again within a minute."}))
        else:
            await ws.send(json.dumps({"type": "auth_required", "pairing_open": store.devices.window_open()}))


async def ws_handler(ws, store, serial_link):
    peer = (ws.remote_address or ("", 0))[0]
    device = None
    if not security.is_loopback(peer):
        device = store.devices.check(security.bearer(ws.request.headers))
        if device is None:
            log.info("unpaired client from %s", peer)
            try:
                await untrusted_session(ws, store)
            except websockets.ConnectionClosed:
                pass
            return
    store.clients.add(ws)
    log.info("app connected (%d)%s", len(store.clients), f" device {device['name']}" if device else " local")
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
            elif msg.get("cmd") == "pair_open":              # a trusted client approves pairing a new device
                until = store.devices.open_window("app")
                await ws.send(json.dumps({"type": "pairing", "open_until": until}))
            elif msg.get("cmd") == "devices":                # paired devices: list, or revoke one
                if msg.get("revoke"):
                    store.devices.revoke(msg["revoke"])
                await ws.send(json.dumps({"type": "devices", "items": store.devices.list()}))
            elif msg.get("cmd") == "messages":               # conversation history from the log
                await answer_messages(ws, msg)
            elif msg.get("cmd") == "say":                    # the creature "says" something: a notice on the phone
                await creature_says(store, msg.get("unit") or body_unit(store) or "creature", str(msg.get("text", ""))[:300])
            elif msg.get("cmd") == "reply":                  # the owner answered a notification: like speech to the creature
                text = str(msg.get("text", "")).strip()[:300]
                if text:
                    unit = msg.get("unit") or "phone"
                    await store.broadcast({"type": "event", "unit": unit, "link": "hub",
                                           "name": "speech", "text": text, "via": "notification", "t": 0, "ts": time.time()})
                    asyncio.create_task(creature_answers(store, unit))
            elif msg.get("cmd") == "brain":                  # the creature's answering brain: status, on or off, daily cap
                brain = getattr(store, "brain", None)
                cap = msg.get("daily_cap_usd", msg.get("dailyCapUsd"))
                if brain is not None and ("on" in msg or cap is not None):
                    brain.configure(enabled=msg.get("on"), daily_cap_usd=cap)
                await ws.send(json.dumps(dict({"type": "brain"}, **(brain.status() if brain else {}))))
            elif msg.get("cmd") == "eye":                    # when the camera eye runs: off, auto or on
                eye = getattr(store, "eye", None)
                if eye is not None:
                    if msg.get("mode"):
                        await eye.set_mode(str(msg["mode"]))
                    if "describe" in msg:
                        await eye.set_describe(bool(msg["describe"]))
                    await announce_eye(store, force=True)
            elif msg.get("cmd") == "safety":                 # away watch and the still check-in, kept across restarts
                store.safety.configure(away=msg.get("away"), checkin=msg.get("checkin"))
                log.info("safety: away %s, check-in %s", store.safety.away, store.safety.checkin)
                await send_to_apps(store, store.safety.status())
            elif msg.get("cmd") == "correct":                # the owner says the eye got it wrong
                await scene_corrected(store, msg.get("right"),
                                      bool(msg.get("description_wrong") or msg.get("descriptionWrong")))
            elif msg.get("cmd") == "snapshot" and device is None:   # one picture, for the describer on this Mac
                store.picture_once.add(ws)
            elif msg.get("cmd") == "described" and device is None:  # the local model's sentence about the scene
                await scene_described(store, str(msg.get("text", ""))[:300], msg.get("seconds"))
            elif msg.get("cmd") == "picture":                # this app wants the eye's live picture, or no longer
                if msg.get("on"):
                    store.picture_clients.add(ws)
                else:
                    store.picture_clients.discard(ws)
                log.info("live picture: %d watching", len(store.picture_clients))
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
        store.picture_clients.discard(ws)
        store.picture_once.discard(ws)
        log.info("app left (%d)", len(store.clients))


async def register_bonjour(port):
    zc = AsyncZeroconf()
    ip = lan_ip()
    info = ServiceInfo(
        "_roomcreature._tcp.local.",
        f"{socket.gethostname().split('.')[0]}._roomcreature._tcp.local.",
        addresses=[socket.inet_aton(ip)], port=port,
        properties={"version": BRIDGE_VERSION, "tls": "1"},
    )
    try:
        await asyncio.wait_for(zc.async_register_service(info), 5)
    except Exception as e:
        log.warning("bonjour registration failed: %s", e)
    return zc, ip


LIFE_FILE = pathlib.Path(__file__).resolve().parent.parent / "data" / "life.json"


def day_facts(unit, since, until):
    """What the log says about a stretch of time, for the creature's daily recaps:
    seconds someone was in front of it, temperature range, loud moments, and from the eye:
    seconds per activity, stretches and seconds slouched."""
    data = pathlib.Path(__file__).resolve().parent.parent / "data"
    keys = [f'"unit": "{n}"' for n in names_for(unit)]
    temps, loud, spans, start = [], 0, 0.0, None
    activities, activity, activity_since = {}, None, None
    stretches, slouched, slouch_start = 0, 0.0, None
    for f in sorted(data.glob("log_*.jsonl")):
        try:
            day = time.mktime(time.strptime(f.stem[4:], "%Y-%m-%d"))
        except ValueError:
            continue
        if day + 86400 < since or day > until:
            continue
        with open(f) as fh:
            for line in fh:
                if not any(k in line for k in keys):
                    continue
                try:
                    m = json.loads(line)
                except ValueError:
                    continue
                ts = m.get("ts", 0)
                if not since <= ts <= until or m.get("late"):
                    continue
                if m.get("type") == "state" and m.get("temp_c") is not None:
                    temps.append(m["temp_c"])
                elif m.get("type") == "event":
                    name = m.get("name")
                    if name in ("clap", "knock", "sound_started"):
                        loud += 1
                    elif name == "someone_in_front" and start is None:
                        start = ts
                    elif name == "someone_left" and start is not None:
                        spans += ts - start
                        start = None
                    elif name == "activity" and m.get("activity"):
                        if activity is not None:
                            activities[activity] = activities.get(activity, 0.0) + min(ts - activity_since, 3600)
                        activity, activity_since = m["activity"], ts
                    elif name == "stretched":
                        stretches += 1
                    elif name == "slouching" and slouch_start is None:
                        slouch_start = ts
                    elif name in ("sat_up", "stretched", "someone_left") and slouch_start is not None:
                        slouched += ts - slouch_start
                        slouch_start = None
    if start is not None:
        spans += until - start
    if activity is not None:
        activities[activity] = activities.get(activity, 0.0) + min(until - activity_since, 3600)
    if slouch_start is not None:
        slouched += until - slouch_start
    return {"present_s": spans, "temp_min": min(temps) if temps else None,
            "temp_max": max(temps) if temps else None, "loud_events": loud,
            "activities": activities, "stretches": stretches, "slouched_s": slouched}


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
             "break": "Break time", "warm": "Warm room", "goodnight": "Goodnight",
             "posture": "Posture", "tired": "Tired?", "checkin": "Are you OK?", "alarm": "Alarm"}.get(kind, unit.capitalize())
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


def describe_room(store, unit):
    """A few plain lines the creature's brain gets with every message: what its sensors say now."""
    u = store.units.get(unit) or {}
    s = u.get("last_state") or {}
    lines = []
    if s.get("temp_c") is not None:
        lines.append(f"temperature {s['temp_c']:.1f} C, humidity {s.get('hum_pct', 0):.0f} %")
    if s.get("sound_db") is not None:
        lines.append(f"sound level {s['sound_db']:.0f} dB (quiet room is about 30)")
    body = s.get("body") or {}
    if body.get("mood"):
        lines.append(f"your mood: {body['mood']}")
    now = time.time()
    recent = [e for e in store.events if e.get("unit") == unit and now - e.get("ts", 0) < 2 * 3600]
    presence = next((e for e in reversed(recent) if e.get("name") in ("someone_in_front", "someone_left")), None)
    if presence:
        mins = int((now - presence["ts"]) // 60)
        lines.append(("someone is in front of you" if presence["name"] == "someone_in_front" else "nobody in front of you")
                     + f" (since {mins} min ago)")
    scene = getattr(store, "scene", None)
    now_line = scene.sentence() if scene else None
    if now_line:
        lines.append("right now, through the camera: " + now_line)
    look = next((e for e in reversed(recent) if e.get("name") in ("looked_at", "looked_away")), None)
    if look and look["name"] == "looked_at" and presence and presence["name"] == "someone_in_front":
        lines.append("they are looking at you right now")
    counts = {}
    for e in recent:
        if e.get("name") in ("clap", "knock", "moved", "picked_up", "shaken", "someone_in_front", "looked_at"):
            counts[e["name"]] = counts.get(e["name"], 0) + 1
    if counts:
        lines.append("last 2 hours: " + ", ".join(f"{v} x {k.replace('_', ' ')}" for k, v in sorted(counts.items())))
    return "\n".join(lines) or "no readings yet"


async def creature_answers(store, unit):
    """After the owner wrote to the creature: let the brain answer, as the creature."""
    brain = getattr(store, "brain", None)
    if brain is None:
        return
    loop = asyncio.get_running_loop()
    history = await loop.run_in_executor(None, read_messages, time.time() - 2 * 86400, time.time() + 1, unit)
    text = await brain.answer(unit, history, describe_room(store, unit))
    if text:
        await creature_says(store, unit, text[:300])


async def creature_says(store, unit, text):
    if not text:
        return
    await route_command(store, {"cmd": "chirp", "unit": unit, "name": "hello"})   # silent until a speaker is fitted
    await post_notice(store, unit, "say", text)


EYE_FOV_DEG = 60           # the eye's horizontal field of view, when its hello does not say
EYE_MIN_STEP_DEG = 8
EYE_MIN_GAP_S = 2.0
_eye_last = {"pan": None, "at": 0.0}


def eye_pan(x, fov_deg):
    """Head turn toward a person at x (-1 left .. +1 right of the picture), for a camera beside the head."""
    half = math.radians(fov_deg) / 2
    return max(-60, min(60, round(math.degrees(math.atan(float(x) * math.tan(half))))))


async def eye_follow(store, msg):
    """The test-rig eye (a camera on the Mac) sees a person: turn the creature's head toward them."""
    if msg.get("type") != "state" or not msg.get("people") or msg.get("x") is None:
        return
    unit = body_unit(store)
    if not unit:
        return
    fov = ((store.units.get(msg.get("unit")) or {}).get("hello") or {}).get("hfov") or EYE_FOV_DEG
    pan = eye_pan(msg["x"], fov)
    now = time.time()
    last = _eye_last["pan"]
    if (last is None or abs(pan - last) >= EYE_MIN_STEP_DEG) and now - _eye_last["at"] >= EYE_MIN_GAP_S:
        _eye_last.update(pan=pan, at=now)
        await route_command(store, {"cmd": "look_at", "unit": unit, "pan": pan, "tilt": 5 if msg.get("facing") else 0})


EYE_EVENTS = {"person_appeared": "someone_in_front", "person_left": "someone_left",
              "looked_at": "looked_at", "looked_away": "looked_away",
              "waved": "waved", "thumbs_up": "thumbs_up", "open_palm": "open_palm",
              "nodded": "nodded", "shook_head": "shook_head", "stretched": "stretched",
              "slouching": "slouching", "sat_up": "sat_up", "yawned": "yawned", "eyes_heavy": "eyes_heavy"}
SIGN_ANSWERS = {"thumbs_up": "👍 Yes", "open_palm": "✋ Not now", "nodded": "Yes (nodded)", "shook_head": "No (shook head)"}
SIGN_ANSWER_WINDOW_S = 10 * 60          # a sign answers a notice this recent


async def follow_scene(store, msg):
    """Each outline updates the one-activity picture; a change is logged as an event of the creature."""
    if msg.get("type") != "vision":
        return
    changed = store.scene.update(msg)
    unit = body_unit(store)
    if changed and unit:
        await store.broadcast({"type": "event", "unit": unit, "name": "activity", "activity": changed,
                               "text": ACTIVITY_LABELS[changed], "via": "eye", "t": 0, "ts": time.time()})


async def scene_corrected(store, right, description_wrong):
    """Log what the eye knew when the owner corrected it (tuning data), and show the right activity."""
    unit = body_unit(store)
    if not unit or (right is None and not description_wrong):
        return
    right = right if right in ACTIVITY_LABELS else None
    record = store.scene.correct(right, description_wrong)
    log.info("correction: %s", record)
    now = time.time()
    await store.broadcast(dict({"type": "event", "unit": unit, "link": "hub", "name": "correction", "t": 0, "ts": now},
                               **record))
    if right:
        await store.broadcast({"type": "event", "unit": unit, "name": "activity", "activity": right,
                               "text": ACTIVITY_LABELS[right], "via": "owner", "t": 0, "ts": now})


async def scene_described(store, text, seconds=None):
    """A sentence from the local vision model: kept by the scene, logged for recaps and the agent."""
    unit = body_unit(store)
    if not text.strip() or not unit:
        return
    hints = store.scene.describe(text)
    await store.broadcast({"type": "event", "unit": unit, "name": "described", "text": text.strip(),
                           "hints": hints, "via": "eye", "model_s": seconds, "t": 0, "ts": time.time()})


async def sign_answer(store, msg):
    """A thumbs-up, open palm, nod or shake soon after a notice is the owner's answer to it, kept in the conversation."""
    text = SIGN_ANSWERS.get(msg.get("name"))
    if not text:
        return
    now = time.time()
    unit = msg["unit"]
    if recent_notice(store, unit, now):
        await store.broadcast({"type": "event", "unit": unit, "link": "hub", "name": "speech",
                               "text": text, "via": "gesture", "t": 0, "ts": now})


ANSWER_ONLY = ("nodded", "shook_head")    # a head movement only means yes or no when there is a question


def recent_notice(store, unit, now=None):
    now = now or time.time()
    return any(e.get("unit") == unit and e.get("name") == "notice" and now - e.get("ts", 0) < SIGN_ANSWER_WINDOW_S
               for e in store.events)


def eye_as_creature_event(store, msg):
    """What the eye saw, as an event of the creature it stands in for (its Activity, daily life, the agent)."""
    if msg.get("type") != "event" or msg.get("name") not in EYE_EVENTS:
        return None
    unit = body_unit(store)
    if not unit:
        return None
    if msg["name"] in ANSWER_ONLY and not recent_notice(store, unit):
        return None
    return {"type": "event", "unit": unit, "name": EYE_EVENTS[msg["name"]], "via": "eye",
            "t": msg.get("t", 0), "ts": msg.get("ts", time.time())}


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


async def send_to_apps(store, msg):
    """A hub setting for every app (not a unit's message: not logged)."""
    text = json.dumps(dict(msg, ts=time.time()))
    for ws in list(store.clients):
        try:
            await ws.send(text)
        except Exception:
            store.clients.discard(ws)


async def run_safety(store, items):
    """Carry out what the safety rules decided: notices (alarms always go out) and body commands."""
    for item in items:
        if item[0] == "notice":
            _, unit, kind, text = item
            log.warning("safety %s: %s", kind, text)
            await post_notice(store, unit, kind, text)
        elif item[0] == "cmd":
            _, unit, cmd = item
            await route_command(store, dict(cmd, unit=unit))
    if items:
        await send_to_apps(store, store.safety.status())


async def mind_loop(store):
    """The creature's ongoing thoughts: the brain writes them when it is on, templates otherwise."""
    while True:
        await asyncio.sleep(20)
        try:
            unit = body_unit(store)
            if not unit:
                continue
            summary = store.scene.summary()
            temp = ((store.units.get(unit) or {}).get("last_state") or {}).get("temp_c")
            key = Mind.key(summary, temp)
            if not store.mind.due(key):
                continue
            text, via = None, "rules"
            if store.brain is not None and store.brain.ready()[0]:
                text = await store.brain.think(unit, describe_room(store, unit), list(store.mind.recent))
                via = "brain"
            if not text:
                text, via = store.mind.template(summary, temp), "rules"
            store.mind.noted(key, text)
            await store.broadcast({"type": "event", "unit": unit, "link": "hub", "name": "thought",
                                   "text": text[:300], "via": via, "t": 0, "ts": time.time()})
        except Exception as e:  # noqa: BLE001
            log.warning("mind failed: %s", e)


async def safety_loop(store):
    while True:
        await asyncio.sleep(10)
        try:
            await run_safety(store, store.safety.tick())
        except Exception as e:  # noqa: BLE001
            log.warning("safety tick failed: %s", e)


async def announce_eye(store, force=False):
    """Tell the apps the eye's mode and whether the camera is in use, when that changed."""
    status = store.eye.status()
    if force or status != getattr(store, "_eye_sent", None):
        store._eye_sent = status
        text = json.dumps(dict(status, ts=time.time()))   # a hub setting, not a unit's message: not logged
        for ws in list(store.clients):
            try:
                await ws.send(text)
            except Exception:
                store.clients.discard(ws)


async def eye_loop(store):
    """Auto mode's grace after leaving, and an eye that quit on its own, are noticed here."""
    while True:
        await asyncio.sleep(10)
        try:
            await store.eye.apply()
            await announce_eye(store)
        except Exception as e:  # noqa: BLE001
            log.warning("eye control failed: %s", e)


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
    zc, ip = await register_bonjour(SECURE_PORT)
    store.lan_ip = ip

    async def on_unit(reader, writer):
        await TcpLink(store, reader, writer).run()

    tcp_server = await asyncio.start_server(on_unit, "0.0.0.0", UNIT_PORT)
    http_units = HttpUnits(store)
    http_server = await asyncio.start_server(http_units.handle, "0.0.0.0", HTTP_PORT)
    tls = security.server_context()
    log.info("hub certificate sha256 %s", security.certificate_fingerprint())
    handler = lambda ws: ws_handler(ws, store, serial_link)
    async with websockets.serve(handler, "127.0.0.1", args.ws_port), \
            websockets.serve(handler, "0.0.0.0", SECURE_PORT, ssl=tls), tcp_server, http_server:
        log.info("bridge %s  apps: ws://%s:%d/  units: tcp %s:%d, http://%s:%d/event", BRIDGE_VERSION, ip, args.ws_port, ip, UNIT_PORT, ip, HTTP_PORT)
        keeper = asyncio.create_task(housekeeping(store))
        life = Life(facts=day_facts)
        life.enabled = load_life_enabled()
        store.life = life
        store.brain = Brain(log)
        log.info("brain: %s", store.brain.status())
        if store.brain.own():
            store.brain.own().start_loading()                  # ready by the first message; Farhelm until then

        async def hook(msg):
            try:
                creature = body_unit(store) or store.last_creature      # still Crawl while it is offline
                store.last_creature = creature
                if creature and msg.get("unit") == creature:
                    store.scene.room(msg)                          # sound, distance and motion join the scene
                await run_safety(store, store.safety.observe(msg, creature))
                if store.eye.observe(msg, body_unit(store)):
                    await store.eye.apply()
                    await announce_eye(store)
                if "vision-person" in ((store.units.get(msg.get("unit")) or {}).get("hello") or {}).get("sensors", []):
                    await eye_follow(store, msg)
                    await follow_scene(store, msg)
                    seen = eye_as_creature_event(store, msg)
                    if seen:
                        await store.broadcast(seen)            # comes back through this hook as the creature's
                        await sign_answer(store, seen)
                    return                                     # the eye has no body: the rules act on the creature
                await run_life(store, life, *life.observe(msg))
            except Exception as e:
                log.warning("life rule failed: %s", e)
        store.life_hook = hook
        store.scene = Scene()
        store.safety = Safety()
        store.last_creature = None
        store.mind = Mind()
        store.eye = EyeControl(log)
        store.eye.release_leftovers()
        await store.eye.apply()
        async def release_and_exit():
            await store.eye.stop()                         # stopped by kill: release the camera first
            os._exit(0)
        for sig in (signal.SIGTERM, signal.SIGHUP):
            asyncio.get_running_loop().add_signal_handler(sig, lambda: asyncio.ensure_future(release_and_exit()))
        log.info("eye %s", store.eye.mode)
        eyer = asyncio.create_task(eye_loop(store))
        safer = asyncio.create_task(safety_loop(store))
        thinker = asyncio.create_task(mind_loop(store))
        lifer = asyncio.create_task(life_loop(store, life))
        log.info("daily life %s", "on" if life.enabled else "off")
        try:
            await serial_link.run()
        finally:
            keeper.cancel()
            lifer.cancel()
            eyer.cancel()
            safer.cancel()
            thinker.cancel()
            await store.eye.stop()                         # the camera is released with the hub
            await zc.async_unregister_all_services()
            await zc.async_close()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
