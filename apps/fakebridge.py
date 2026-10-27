#!/usr/bin/env python3.12
"""Fake RoomCreature bridge: serves docs/protocol.md over WebSocket with synthetic data.

Usage: python3.12 apps/fakebridge.py [-p 8777] [-u desk,mac-mic] [-B]
Stdlib only. Advertises _roomcreature._tcp via /usr/bin/dns-sd when available.
"""
import argparse
import asyncio
import base64
import hashlib
import json
import math
import random
import shutil
import socket
import subprocess
import sys
import time

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
EVENT_NAMES = ["clap", "knock", "moved", "someone_in_front", "someone_left",
               "sound_started", "sound_stopped"]
MOODS = ["neutral", "listening", "alert", "curious", "pleased", "surprised", "sleepy"]
GESTURES = ["wag", "nod", "shake", "perk", "droop"]
CHEEKS = {"neutral": "#8fb4ff", "listening": "#6ea8ff", "alert": "#ff6b6b", "curious": "#b388ff",
          "pleased": "#5fd38a", "surprised": "#ffb347", "sleepy": "#556b8f"}


def log(*parts):
    print(time.strftime("%H:%M:%S"), *parts, flush=True)


def lan_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return "127.0.0.1"


class Unit:
    def __init__(self, name):
        self.name = name
        self.boot = time.time()
        self.phase = random.random() * 100
        self.temp = 22.0 + random.random() * 3
        self.hum = 40.0 + random.random() * 10
        self.press = 1008.0 + random.random() * 6
        self.heading = random.random() * 360
        self.walker_until = 0.0
        self.sound_on = False
        self.last_state = None
        self.body = {"ear_l": 10, "ear_r": 10, "pan": 0, "tilt": 0, "tail": 0,
                     "cheek": CHEEKS["neutral"], "mood": "neutral", "gesture": "", "servos": False}
        self.gesture_until = 0.0
        self.why = "boot"
        self.wifi = {"module": "FAKE-WIFI", "ssid": "", "joined": False, "ip": None, "bridge": False}
        self.rssi = None
        self.bridge_host = ""
        self.bridge_port = 8778
        self.wifi_attempts = 0

    def hello_message(self):
        return self.stamp({"type": "hello", "fw": "0.3.0-fake",
                           "sensors": ["hts221", "lps22hb", "vl53l0x", "lsm6dsl", "lis3mdl"],
                           "wifi": dict(self.wifi)})

    def status_message(self):
        return self.stamp({"type": "status", "ssid": self.wifi["ssid"], "joined": self.wifi["joined"],
                           "ip": self.wifi["ip"], "rssi": self.rssi, "bridge_host": self.bridge_host,
                           "bridge_port": self.bridge_port, "bridge": self.wifi["bridge"]})

    async def join_wifi(self, ssid, password):
        self.wifi["ssid"] = ssid
        self.wifi_attempts += 1
        await asyncio.sleep(random.uniform(2, 5))
        joined = self.wifi_attempts > 1 or random.random() < 0.5
        self.wifi["joined"] = joined
        self.wifi["ip"] = f"192.168.1.{random.randint(50, 99)}" if joined else None
        self.rssi = random.randint(-75, -45) if joined else None
        self.wifi["bridge"] = joined and bool(self.bridge_host)
        log("wifi join", self.name, ssid, "ok" if joined else "failed")

    async def apply_admin_command(self, cmd):
        kind = cmd.get("cmd")
        if kind == "wifi":
            await self.join_wifi(str(cmd.get("ssid", "")), str(cmd.get("pass", "")))
            return self.status_message()
        if kind == "status":
            return self.status_message()
        if kind == "bridge":
            self.bridge_host = str(cmd.get("host", ""))
            self.bridge_port = int(cmd.get("port", 8778))
            self.wifi["bridge"] = self.wifi["joined"] and bool(self.bridge_host)
            return None
        if kind == "name" and isinstance(cmd.get("name"), str) and cmd["name"]:
            log("rename", self.name, "->", cmd["name"])
            self.name = cmd["name"]
            return self.hello_message()
        if kind == "hello":
            return self.hello_message()
        return None

    def stamp(self, msg):
        now = time.time()
        msg.update({"unit": self.name, "link": "serial", "ts": round(now, 3),
                    "t": int((now - self.boot) * 1000)})
        return msg

    def body_message(self):
        if self.body["gesture"] and time.time() > self.gesture_until:
            self.body["gesture"] = ""
        if self.body["gesture"] == "wag":
            self.body["tail"] = random.choice([-35, 35])
        return self.stamp({"type": "body", **self.body, "why": self.why})

    def set_mood(self, mood, why):
        self.body["mood"] = mood
        self.body["cheek"] = CHEEKS.get(mood, CHEEKS["neutral"])
        perk = {"sleepy": -35, "surprised": 45, "alert": 40, "listening": 30, "curious": 25}.get(mood, 10)
        self.body["ear_l"] = self.body["ear_r"] = perk
        self.why = why

    def set_gesture(self, name, why):
        self.body["gesture"] = name
        self.gesture_until = time.time() + 3
        if name == "perk":
            self.body["ear_l"] = self.body["ear_r"] = 45
        elif name == "droop":
            self.body["ear_l"] = self.body["ear_r"] = -40
        elif name == "nod":
            self.body["tilt"] = -20
        elif name == "shake":
            self.body["pan"] = random.choice([-40, 40])
        self.why = why

    def look_at(self, pan, tilt, why):
        self.body["pan"] = max(-60, min(60, pan))
        self.body["tilt"] = max(-30, min(30, tilt))
        self.why = why

    def apply_command(self, cmd):
        kind = cmd.get("cmd")
        if kind == "express" and cmd.get("mood") in MOODS:
            self.set_mood(cmd["mood"], "agent")
        elif kind == "gesture" and cmd.get("name") in GESTURES:
            self.set_gesture(cmd["name"], "agent")
        elif kind == "look_at":
            self.look_at(float(cmd.get("pan", 0)), float(cmd.get("tilt", 0)), "agent")
        elif kind == "cheek" and isinstance(cmd.get("color"), str):
            self.body["cheek"] = cmd["color"]
            self.why = "agent"
        else:
            return None
        return self.body_message()

    def random_body_change(self):
        if random.random() < 0.6:
            self.set_mood(random.choice(MOODS), random.choice(["sound", "quiet", "knock", "clap"]))
        else:
            self.set_gesture(random.choice(GESTURES), random.choice(["clap", "someone_in_front"]))
        return self.body_message()

    def state(self):
        now = time.time()
        k = now / 60.0 + self.phase
        self.temp += random.gauss(0, 0.03)
        self.hum += random.gauss(0, 0.1)
        self.press += random.gauss(0, 0.02)
        self.heading = (self.heading + random.gauss(0, 0.5)) % 360
        if now < self.walker_until:
            tof = int(500 + 300 * random.random())
        else:
            tof = int(1800 + 40 * math.sin(k))
            if tof > 2000:
                tof = -1
        motion = 1 if random.random() < 0.05 else 0
        base_db = 36 + 2 * math.sin(k * 3)
        sound = base_db + (18 if self.sound_on else 0) + random.gauss(0, 0.8)
        if self.body["gesture"] and now > self.gesture_until:
            self.body["gesture"] = ""
        if not self.body["gesture"]:
            self.body["tail"] = 0
        msg = self.stamp({
            "type": "state",
            "temp_c": round(self.temp, 2), "hum_pct": round(self.hum, 1),
            "press_hpa": round(self.press, 2), "tof_mm": tof,
            "heading_deg": round(self.heading, 1), "motion": motion,
            "sound_db": round(sound, 1),
            "sound_dir": round(random.uniform(-0.3, 0.3), 2),
            "body": dict(self.body),
        })
        if self.wifi["joined"]:
            msg["rssi"] = self.rssi + random.randint(-2, 2)
        self.last_state = msg
        return msg

    def event(self):
        now = time.time()
        name = random.choice(EVENT_NAMES)
        msg = self.stamp({"type": "event", "name": name})
        if name == "someone_in_front":
            self.walker_until = now + random.uniform(3, 8)
            msg["mm"] = int(500 + 300 * random.random())
            self.look_at(random.choice([-25, 25]), 5, "someone_in_front")
            self.body["cheek"] = "#ffb347"
        elif name == "someone_left":
            self.walker_until = 0.0
            self.look_at(0, 0, "someone_left")
        elif name == "clap":
            self.set_mood("surprised", "clap")
        elif name == "knock":
            self.set_mood("alert", "knock")
        elif name == "sound_started":
            self.sound_on = True
        elif name == "sound_stopped":
            self.sound_on = False
        return msg


PHRASES = ["hello there", "what's the temperature", "wag your tail", "who is at the door",
           "good night little one", "play some music", "is anyone there"]


class MacMic(Unit):
    def __init__(self, name):
        super().__init__(name)
        self.next_speech = time.time() + random.uniform(20, 40)

    def hello_message(self):
        return self.stamp({"type": "hello", "fw": "mac-mic-fake", "sensors": ["mac-microphone", "whisper:base"]})

    def state(self):
        now = time.time()
        level = 34 + 3 * math.sin(now / 7 + self.phase) + random.gauss(0, 0.6)
        msg = self.stamp({"type": "state", "sound_db": round(level, 1)})
        self.last_state = msg
        return msg

    def event(self):
        text = random.choice(PHRASES)
        return self.stamp({"type": "event", "name": "speech", "text": text,
                           "duration_s": round(len(text) * 0.08 + random.random(), 1)})

    def due_speech(self):
        if time.time() < self.next_speech:
            return None
        self.next_speech = time.time() + random.uniform(20, 40)
        return self.event()

    def apply_command(self, cmd):
        if cmd.get("cmd") == "speak" and isinstance(cmd.get("text"), str):
            log("speak", self.name, repr(cmd["text"]), cmd.get("voice", ""))
            return self.stamp({"type": "event", "name": "spoke", "text": cmd["text"]})
        return None

    def random_body_change(self):
        return None

    def body_message(self):
        return None


def make_unit(name):
    return MacMic(name) if name == "mac-mic" else Unit(name)


class Bridge:
    def __init__(self, unit_names):
        self.units = [make_unit(n) for n in unit_names]
        self.history = []
        self.clients = set()

    def hello(self):
        return {"type": "hello", "bridge": "0.2.0-fake", "lan_ip": lan_ip(), "unit_port": 8778, "units": [
            {"unit": u.name, "connected": True, "last_state": u.last_state}
            for u in self.units]}

    async def broadcast(self, msg):
        text = json.dumps(msg, separators=(",", ":"))
        for q in list(self.clients):
            q.put_nowait(text)

    def unit_named(self, name):
        for u in self.units:
            if u.name == name:
                return u
        return self.units[0] if self.units else None

    async def producer(self):
        next_event = time.time() + random.uniform(2, 6)
        next_body = time.time() + random.uniform(5, 15)
        for u in self.units:
            u.state()
        while True:
            for u in self.units:
                await self.broadcast(u.state())
            bodies = [u for u in self.units if not isinstance(u, MacMic)]
            if bodies and time.time() >= next_body:
                u = random.choice(bodies)
                msg = u.random_body_change()
                log("body", u.name, msg["mood"], msg["gesture"] or "-", msg["why"])
                await self.broadcast(msg)
                next_body = time.time() + random.uniform(5, 15)
            if bodies and time.time() >= next_event:
                u = random.choice(bodies)
                ev = u.event()
                await self.record_event(ev)
                if ev["name"] in ("clap", "knock", "someone_in_front", "someone_left"):
                    await self.broadcast(u.body_message())
                next_event = time.time() + random.uniform(5, 20)
            for u in self.units:
                if isinstance(u, MacMic):
                    ev = u.due_speech()
                    if ev:
                        await self.record_event(ev)
            await asyncio.sleep(1)

    async def record_event(self, ev):
        self.history.append(ev)
        self.history = self.history[-200:]
        log("event", ev["unit"], ev["name"], repr(ev.get("text", "")))
        await self.broadcast(ev)


async def read_exact(reader, n):
    data = await reader.readexactly(n)
    return data


async def read_frame(reader):
    head = await read_exact(reader, 2)
    fin_opcode, mask_len = head[0], head[1]
    opcode = fin_opcode & 0x0F
    masked = mask_len & 0x80
    length = mask_len & 0x7F
    if length == 126:
        length = int.from_bytes(await read_exact(reader, 2), "big")
    elif length == 127:
        length = int.from_bytes(await read_exact(reader, 8), "big")
    mask = await read_exact(reader, 4) if masked else None
    payload = await read_exact(reader, length)
    if mask:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return opcode, payload


def frame(opcode, payload=b""):
    header = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        header += bytes([n])
    elif n < 65536:
        header += bytes([126]) + n.to_bytes(2, "big")
    else:
        header += bytes([127]) + n.to_bytes(8, "big")
    return header + payload


async def handshake(reader, writer):
    request = await reader.readuntil(b"\r\n\r\n")
    headers = {}
    for line in request.decode("latin-1").split("\r\n")[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    key = headers.get("sec-websocket-key")
    if not key:
        writer.write(b"HTTP/1.1 400 Bad Request\r\n\r\n")
        await writer.drain()
        return False
    accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
    writer.write(("HTTP/1.1 101 Switching Protocols\r\n"
                  "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                  f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
    await writer.drain()
    return True


async def handle_client(bridge, reader, writer):
    peer = writer.get_extra_info("peername")
    try:
        if not await handshake(reader, writer):
            return
    except Exception as exc:
        log("handshake failed", peer, exc)
        writer.close()
        return
    log("client connected", peer)
    queue = asyncio.Queue()
    bridge.clients.add(queue)
    queue.put_nowait(json.dumps(bridge.hello(), separators=(",", ":")))
    queue.put_nowait(json.dumps({"type": "history", "events": bridge.history},
                                separators=(",", ":")))
    for u in bridge.units:
        queue.put_nowait(json.dumps(u.hello_message(), separators=(",", ":")))

    async def sender():
        while True:
            text = await queue.get()
            writer.write(frame(0x1, text.encode()))
            await writer.drain()

    async def receiver():
        while True:
            opcode, payload = await read_frame(reader)
            if opcode == 0x8:
                return
            if opcode == 0x9:
                writer.write(frame(0xA, payload))
                await writer.drain()
            elif opcode == 0x1:
                try:
                    cmd = json.loads(payload)
                except ValueError:
                    continue
                log("command", peer, cmd)
                if cmd.get("cmd") == "ping":
                    queue.put_nowait(json.dumps({"type": "pong", "unit": cmd.get("unit"),
                                                 "ts": round(time.time(), 3)}))
                    continue
                unit = bridge.unit_named(cmd.get("unit"))
                if unit is None:
                    continue
                if cmd.get("cmd") in ("wifi", "status", "bridge", "name", "hello"):
                    reply = await unit.apply_admin_command(cmd)
                else:
                    reply = unit.apply_command(cmd)
                if reply and reply.get("type") == "event":
                    await bridge.record_event(reply)
                elif reply:
                    await bridge.broadcast(reply)

    send_task = asyncio.create_task(sender())
    try:
        await receiver()
    except (asyncio.IncompleteReadError, ConnectionError):
        pass
    finally:
        send_task.cancel()
        bridge.clients.discard(queue)
        writer.close()
        log("client disconnected", peer)


def advertise(port):
    if not shutil.which("dns-sd"):
        log("dns-sd not found; Bonjour disabled")
        return None
    proc = subprocess.Popen(["dns-sd", "-R", "RoomCreature Fake Bridge", "_roomcreature._tcp",
                             ".", str(port)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log("advertising _roomcreature._tcp on port", port)
    return proc


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-p", dest="port", type=int, default=8777)
    parser.add_argument("-u", dest="units", default="desk,mac-mic")
    parser.add_argument("-B", dest="no_bonjour", action="store_true")
    args = parser.parse_args()
    bridge = Bridge([u.strip() for u in args.units.split(",") if u.strip()])
    server = await asyncio.start_server(
        lambda r, w: handle_client(bridge, r, w), host="0.0.0.0", port=args.port)
    log(f"fake bridge listening on ws://0.0.0.0:{args.port}/")
    advertiser = None if args.no_bonjour else advertise(args.port)
    try:
        async with server:
            await asyncio.gather(server.serve_forever(), bridge.producer())
    finally:
        if advertiser:
            advertiser.terminate()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
