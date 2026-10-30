"""Bridge logic that bit us: one active link per unit, gap-free acks, replay dedupe, late timestamps."""
import asyncio
import json
import pathlib
import sys
import time

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import bridge as B  # noqa: E402


class FakeLink(B.Link):
    kind = "wifi"

    def __init__(self, store, kind="wifi"):
        super().__init__(store)
        self.kind = kind
        self.alive = True
        self.sent = []

    async def send(self, msg):
        self.sent.append(msg)
        return True


def store_without_logging(tmp_path):
    s = B.Store()
    s._log = lambda msg: None
    s.unit_keys = B.security.UnitKeys(path=tmp_path / "unit_keys.json")     # never the real keys
    s.devices = B.security.Devices(path=tmp_path / "devices.json")
    return s


async def feed(link, obj):
    await link._handle((json.dumps(obj) + "\n").encode())


@pytest.mark.asyncio
async def test_one_active_link_per_unit_latest_hello_wins(tmp_path):
    s = store_without_logging(tmp_path)
    serial, wifi = FakeLink(s, "serial"), FakeLink(s, "wifi")
    seen = []
    s.broadcast = lambda m: seen.append(m) or asyncio.sleep(0)
    await feed(serial, {"type": "hello", "unit": "desk"})          # the hub gives the unit a key over the cable
    await feed(serial, {"type": "state", "t": 1})
    key = s.unit_keys.get("desk")
    import hashlib, hmac
    auth = hmac.new(key, b"hello|n1|desk", hashlib.sha256).hexdigest()
    await feed(wifi, {"type": "hello", "unit": "desk", "keyed": True, "nonce": "n1", "auth": auth})   # newer hello takes over
    await feed(serial, {"type": "state", "t": 2})                 # dropped: serial no longer active
    await feed(wifi, {"type": "state", "t": 3})
    states = [m for m in seen if m["type"] == "state"]
    assert [m["t"] for m in states] == [1, 3]
    assert s.units["desk"]["link"] == "wifi"


@pytest.mark.asyncio
async def test_audio_passes_from_any_link(tmp_path):
    s = store_without_logging(tmp_path)
    serial, wifi = FakeLink(s, "serial"), FakeLink(s, "wifi")
    seen = []
    s.broadcast = lambda m: seen.append(m) or asyncio.sleep(0)
    await feed(serial, {"type": "hello", "unit": "desk"})
    await feed(wifi, {"type": "hello", "unit": "desk"})
    await feed(serial, {"type": "audio", "seq": 0, "of": 1, "b64": "AAAA"})
    assert any(m["type"] == "audio" for m in seen)


@pytest.mark.asyncio
async def test_acks_are_gap_free_and_seeded_from_hello(tmp_path):
    s = store_without_logging(tmp_path)
    link = FakeLink(s)
    s.broadcast = lambda m: asyncio.sleep(0)
    await feed(link, {"type": "hello", "unit": "desk", "acked": 36, "last_seq": 40})
    assert s.units["desk"]["_seq"] == 36
    await feed(link, {"type": "event", "t": 1, "seq": 38, "name": "clap"})     # 37 missing
    assert s.units["desk"]["_seq"] == 36
    await feed(link, {"type": "event", "t": 1, "seq": 37, "name": "boot", "late": True, "age_s": -1})
    assert s.units["desk"]["_seq"] == 38                                       # gap filled, contiguous now
    await feed(link, {"type": "event", "t": 1, "seq": 39, "name": "knock"})
    await feed(link, {"type": "event", "t": 1, "seq": 40, "name": "knock"})
    assert s.units["desk"]["_seq"] == 40


@pytest.mark.asyncio
async def test_replay_of_seen_event_is_dropped(tmp_path):
    s = store_without_logging(tmp_path)
    link = FakeLink(s)
    seen = []
    s.broadcast = lambda m: seen.append(m) or asyncio.sleep(0)
    await feed(link, {"type": "hello", "unit": "desk", "acked": 10})
    await feed(link, {"type": "event", "t": 1, "seq": 11, "name": "clap"})
    await feed(link, {"type": "event", "t": 1, "seq": 11, "name": "clap", "late": True, "age_s": 12})
    assert sum(1 for m in seen if m["type"] == "event") == 1


@pytest.mark.asyncio
async def test_late_event_timestamp_is_shifted(tmp_path):
    s = store_without_logging(tmp_path)
    link = FakeLink(s)
    seen = []
    s.broadcast = lambda m: seen.append(m) or asyncio.sleep(0)
    await feed(link, {"type": "hello", "unit": "desk", "acked": 0})
    before = time.time()
    await feed(link, {"type": "event", "t": 1, "seq": 1, "name": "clap", "late": True, "age_s": 100})
    ev = [m for m in seen if m["type"] == "event"][0]
    assert ev["ts"] <= before - 99


@pytest.mark.asyncio
async def test_route_prefers_serial_then_wifi(tmp_path):
    s = store_without_logging(tmp_path)
    serial, wifi = FakeLink(s, "serial"), FakeLink(s, "wifi")
    s.broadcast = lambda m: asyncio.sleep(0)
    await feed(serial, {"type": "hello", "unit": "desk"})
    await feed(wifi, {"type": "hello", "unit": "desk"})
    assert wifi.sent == [{"cmd": "ping"}]                        # the warm-up ping a fresh Wi-Fi link gets
    wifi.sent.clear()
    await B.route_command(s, {"cmd": "ping", "unit": "desk"})
    assert serial.sent[-1]["cmd"] == "ping" and not wifi.sent
    await B.route_command(s, {"cmd": "ping", "unit": "desk", "via": "wifi"})
    assert wifi.sent[-1]["cmd"] == "ping" and "via" not in wifi.sent[-1]
    serial.alive = False
    await B.route_command(s, {"cmd": "express", "unit": "desk", "mood": "alert"})
    assert wifi.sent[-1]["cmd"] == "express"


@pytest.mark.asyncio
async def test_http_ingest_creates_unit_and_event(tmp_path):
    s = store_without_logging(tmp_path)
    seen = []
    s.broadcast = lambda m: seen.append(m) or asyncio.sleep(0)
    h = B.HttpUnits(s)
    status, _ = await h._dispatch("POST", "/hello", json.dumps({"unit": "ear", "sensors": ["mic"]}).encode())
    assert status == 200
    status, _ = await h._dispatch("POST", "/event", json.dumps({"unit": "ear", "name": "heard", "label": "creature"}).encode())
    assert status == 200
    assert any(m["type"] == "event" and m["name"] == "heard" and m["link"] == "http" for m in seen)
    status, _ = await h._dispatch("GET", "/event", b"")
    assert status == 404


@pytest.mark.asyncio
async def test_rename_drops_old_unit(tmp_path):
    s = store_without_logging(tmp_path)
    serial, wifi = FakeLink(s, "serial"), FakeLink(s, "wifi")
    s.broadcast = lambda m: asyncio.sleep(0)
    await feed(serial, {"type": "hello", "unit": "desk"})
    await feed(wifi, {"type": "hello", "unit": "desk"})
    await feed(serial, {"type": "hello", "unit": "crawl"})
    await feed(wifi, {"type": "hello", "unit": "crawl"})
    assert "desk" not in s.units and "crawl" in s.units


def test_series_reads_and_downsamples(tmp_path, monkeypatch):
    data = tmp_path / "data"
    data.mkdir()
    now = time.time()
    day = time.strftime("%Y-%m-%d", time.localtime(now))
    with open(data / f"log_{day}.jsonl", "w") as f:
        for i in range(1000):
            f.write(json.dumps({"type": "state", "unit": "desk", "ts": now - 1000 + i, "temp_c": 20 + i / 1000}) + "\n")
        f.write(json.dumps({"type": "state", "unit": "other", "ts": now - 10, "temp_c": 99}) + "\n")
    fake_bridge = tmp_path / "bridge" / "bridge.py"
    fake_bridge.parent.mkdir()
    monkeypatch.setattr(B, "__file__", str(fake_bridge))
    pts = B.read_series("desk", "temp_c", now - 1100, now + 1)
    assert 0 < len(pts) <= B.SERIES_MAX_POINTS
    assert all(19.9 < v < 21.1 for _, v in pts)


def test_messages_from_log(tmp_path, monkeypatch):
    data = tmp_path / "data"
    data.mkdir()
    now = time.time()
    day = time.strftime("%Y-%m-%d", time.localtime(now))
    rows = [
        {"type": "event", "unit": "crawl", "link": "hub", "name": "notice", "kind": "greet", "text": "Welcome back.", "ts": now - 60},
        {"type": "event", "unit": "crawl", "link": "hub", "name": "speech", "via": "notification", "text": "hi!", "ts": now - 30},
        {"type": "event", "unit": "crawl", "name": "clap", "ts": now - 20},
    ]
    (data / f"log_{day}.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
    fake = tmp_path / "bridge" / "bridge.py"
    fake.parent.mkdir()
    monkeypatch.setattr(B, "__file__", str(fake))
    items = B.read_messages(now - 3600, now + 1)
    assert [(i["from"], i["text"]) for i in items] == [("creature", "Welcome back."), ("owner", "hi!")]


@pytest.mark.asyncio
async def test_creature_says_posts_a_notice(tmp_path, monkeypatch):
    s = store_without_logging(tmp_path)
    seen = []
    s.broadcast = lambda m: seen.append(m) or asyncio.sleep(0)
    monkeypatch.setattr(B, "push_notice", lambda *a: None)
    await B.creature_says(s, "crawl", "Hello there")
    assert any(m.get("name") == "notice" and m.get("kind") == "say" and m.get("text") == "Hello there" for m in seen)


def test_day_facts_from_log(tmp_path, monkeypatch):
    data = tmp_path / "data"
    data.mkdir()
    now = time.time()
    day = time.strftime("%Y-%m-%d", time.localtime(now))
    rows = [
        {"type": "state", "unit": "crawl", "ts": now - 900, "temp_c": 26.5},
        {"type": "state", "unit": "crawl", "ts": now - 800, "temp_c": 27.5},
        {"type": "event", "unit": "crawl", "name": "someone_in_front", "ts": now - 700},
        {"type": "event", "unit": "crawl", "name": "clap", "ts": now - 650},
        {"type": "event", "unit": "crawl", "name": "someone_left", "ts": now - 100},
        {"type": "event", "unit": "other", "name": "clap", "ts": now - 50},
    ]
    (data / f"log_{day}.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
    fake = tmp_path / "bridge" / "bridge.py"
    fake.parent.mkdir()
    monkeypatch.setattr(B, "__file__", str(fake))
    monkeypatch.setattr(B, "RENAMES_FILE", data / "renames.json")
    f = B.day_facts("crawl", now - 3600, now)
    assert {k: f[k] for k in ("present_s", "temp_min", "temp_max", "loud_events")} == \
        {"present_s": 600, "temp_min": 26.5, "temp_max": 27.5, "loud_events": 1}


@pytest.mark.asyncio
async def test_wifi_hello_without_proof_is_dropped(tmp_path):
    s = store_without_logging(tmp_path)
    serial, wifi = FakeLink(s, "serial"), FakeLink(s, "wifi")
    seen = []
    s.broadcast = lambda m: seen.append(m) or asyncio.sleep(0)
    await feed(serial, {"type": "hello", "unit": "desk"})
    await feed(wifi, {"type": "hello", "unit": "desk", "keyed": False})
    await feed(wifi, {"type": "event", "name": "clap", "seq": 5})
    assert not any(m.get("name") == "clap" for m in seen)
    assert serial.sent[-1]["cmd"] == "set_key" and len(serial.sent[-1]["key"]) == 64


def test_eye_pan_follows_the_lens_geometry():
    assert B.eye_pan(0, 52) == 0
    assert B.eye_pan(1, 52) == 26 and B.eye_pan(-1, 52) == -26     # the edge of the picture is half the view
    assert B.eye_pan(-0.5, 52) == -14                               # not half of 26: the lens is not linear
    assert B.eye_pan(1, 170) == 60                                  # never past the head's limit


def test_eye_sightings_become_the_creatures_events():
    store = B.Store()
    store.units["crawl"] = {"unit": "crawl", "connected": True, "hello": {"sensors": ["lsm6dsl"]}}
    seen = B.eye_as_creature_event(store, {"type": "event", "unit": "eye", "name": "person_appeared", "ts": 5.0})
    assert seen["unit"] == "crawl" and seen["name"] == "someone_in_front" and seen["via"] == "eye"
    assert "link" not in seen                       # the creature's own link stays as it is in the apps
    assert B.eye_as_creature_event(store, {"type": "event", "unit": "eye", "name": "looked_at"})["name"] == "looked_at"
    assert B.eye_as_creature_event(store, {"type": "state", "unit": "eye"}) is None


def test_pictures_go_only_to_apps_watching():
    class WS:
        def __init__(self):
            self.sent = []

        async def send(self, text):
            self.sent.append(json.loads(text))

    store = B.Store()
    watcher, other = WS(), WS()
    store.clients |= {watcher, other}
    asyncio.run(B.send_picture(store, {"unit": "eye", "jpeg": "AAAA"}))
    assert watcher.sent == [] and other.sent == []          # nobody asked: nothing sent
    store.picture_clients.add(watcher)
    asyncio.run(B.send_picture(store, {"unit": "eye", "jpeg": "AAAA"}))
    assert watcher.sent[0]["type"] == "picture" and watcher.sent[0]["jpeg"] == "AAAA"
    assert other.sent == []


def test_a_thumbs_up_answers_a_recent_notice():
    store = B.Store()
    store.record = lambda msg: store.events.append(msg) if msg.get("type") == "event" else None
    asyncio.run(B.sign_answer(store, {"unit": "crawl", "name": "thumbs_up"}))
    assert not any(e.get("name") == "speech" for e in store.events)     # nothing to answer
    store.events.append({"type": "event", "unit": "crawl", "name": "notice", "kind": "break", "ts": time.time() - 60})
    asyncio.run(B.sign_answer(store, {"unit": "crawl", "name": "thumbs_up"}))
    answer = [e for e in store.events if e.get("name") == "speech"][-1]
    assert answer["text"] == "👍 Yes" and answer["via"] == "gesture" and answer["link"] == "hub"


def test_a_nod_answers_yes():
    store = B.Store()
    store.record = lambda msg: store.events.append(msg) if msg.get("type") == "event" else None
    store.events.append({"type": "event", "unit": "crawl", "name": "notice", "kind": "break", "ts": time.time() - 30})
    asyncio.run(B.sign_answer(store, {"unit": "crawl", "name": "shook_head"}))
    assert [e for e in store.events if e.get("name") == "speech"][-1]["text"] == "No (shook head)"


def test_a_nod_without_a_question_is_ignored():
    store = B.Store()
    store.units["crawl"] = {"unit": "crawl", "connected": True, "hello": {"sensors": ["lsm6dsl"]}}
    assert B.eye_as_creature_event(store, {"type": "event", "unit": "eye", "name": "nodded"}) is None
    store.events.append({"type": "event", "unit": "crawl", "name": "notice", "kind": "break", "ts": time.time() - 30})
    assert B.eye_as_creature_event(store, {"type": "event", "unit": "eye", "name": "nodded"})["name"] == "nodded"


def test_day_facts_count_activities_stretches_and_slouching(tmp_path, monkeypatch):
    day = time.strftime("%Y-%m-%d")
    base = time.mktime(time.strptime(day, "%Y-%m-%d")) + 9 * 3600
    rows = [("activity", 0, {"activity": "working"}), ("slouching", 600, {}), ("activity", 1800, {"activity": "on_phone"}),
            ("sat_up", 2400, {}), ("stretched", 2700, {}), ("activity", 3000, {"activity": "working"})]
    data = tmp_path / "data"
    data.mkdir()
    with open(data / f"log_{day}.jsonl", "w") as f:
        for name, at, extra in rows:
            f.write(json.dumps(dict({"type": "event", "unit": "crawl", "name": name, "ts": base + at}, **extra)) + "\n")
    monkeypatch.setattr(B.pathlib.Path, "resolve", lambda self: tmp_path / "bridge" / "bridge.py")
    facts = B.day_facts("crawl", base, base + 3600)
    assert facts["activities"] == {"working": 1800 + 600, "on_phone": 1200}
    assert facts["stretches"] == 1 and facts["slouched_s"] == 1800


def test_sign_answers_are_part_of_the_conversation(tmp_path, monkeypatch):
    day = time.strftime("%Y-%m-%d")
    now = time.time()
    data = tmp_path / "data"
    data.mkdir()
    with open(data / f"log_{day}.jsonl", "w") as f:
        f.write(json.dumps({"type": "event", "unit": "crawl", "name": "notice", "kind": "break", "text": "Break?", "ts": now - 60}) + "\n")
        f.write(json.dumps({"type": "event", "unit": "crawl", "name": "speech", "via": "gesture", "text": "👍 Yes", "ts": now - 30}) + "\n")
    monkeypatch.setattr(B.pathlib.Path, "resolve", lambda self: tmp_path / "bridge" / "bridge.py")
    items = B.read_messages(now - 3600, now)
    assert [(i["from"], i["text"]) for i in items] == [("creature", "Break?"), ("owner", "👍 Yes")]


def test_a_snapshot_is_one_picture():
    class WS:
        def __init__(self):
            self.sent = []

        async def send(self, text):
            self.sent.append(json.loads(text))

    store = B.Store()
    describer = WS()
    store.picture_once.add(describer)
    asyncio.run(B.send_picture(store, {"unit": "eye", "jpeg": "AAAA"}))
    asyncio.run(B.send_picture(store, {"unit": "eye", "jpeg": "BBBB"}))
    assert [m["jpeg"] for m in describer.sent] == ["AAAA"]


class FakeCable(FakeLink):
    lasting = True


@pytest.mark.asyncio
async def test_the_cable_link_is_kept_while_unplugged(tmp_path):
    s = store_without_logging(tmp_path)
    cable = FakeCable(s, "serial")
    cable.alive = False                                     # unplugged
    FakeLink(s, "wifi")                                     # a Wi-Fi connection comes and goes meanwhile
    assert cable in s.links
    cable.alive = True                                      # plugged back in: commands reach it again
    await feed(cable, {"type": "hello", "unit": "crawl"})
    await B.route_command(s, {"cmd": "express", "unit": "crawl", "mood": "pleased"})
    assert {"cmd": "express", "mood": "pleased"} in cable.sent


@pytest.mark.asyncio
async def test_a_unit_that_cannot_reach_the_bridge_gets_its_address_once(tmp_path, monkeypatch):
    s = store_without_logging(tmp_path)
    monkeypatch.setattr(B, "lan_ip", lambda: "192.168.1.85")
    cable = FakeCable(s, "serial")
    lost = {"type": "hello", "unit": "crawl", "wifi": {"joined": True, "bridge": False}}
    await feed(cable, lost)
    await feed(cable, lost)
    told = [m for m in cable.sent if m.get("cmd") == "bridge"]
    assert told == [{"cmd": "bridge", "host": "192.168.1.85", "port": B.UNIT_PORT}]
    await feed(cable, {"type": "hello", "unit": "crawl", "wifi": {"joined": True, "bridge": True}})
    assert len([m for m in cable.sent if m.get("cmd") == "bridge"]) == 1
