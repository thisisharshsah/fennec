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
    return s


async def feed(link, obj):
    await link._handle((json.dumps(obj) + "\n").encode())


@pytest.mark.asyncio
async def test_one_active_link_per_unit_latest_hello_wins(tmp_path):
    s = store_without_logging(tmp_path)
    serial, wifi = FakeLink(s, "serial"), FakeLink(s, "wifi")
    seen = []
    s.broadcast = lambda m: seen.append(m) or asyncio.sleep(0)
    await feed(serial, {"type": "hello", "unit": "desk"})
    await feed(serial, {"type": "state", "t": 1})
    await feed(wifi, {"type": "hello", "unit": "desk"})          # newer hello takes over
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
