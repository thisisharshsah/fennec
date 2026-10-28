"""When the eye runs: off, auto (follows the creature's own presence sensor) and on."""
import asyncio
import logging
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import eye_control as E  # noqa: E402


class Clock:
    def __init__(self):
        self.t = 1_000_000.0

    def __call__(self):
        return self.t


class FakeProc:
    def __init__(self):
        self.returncode = None

    def terminate(self):
        self.returncode = 0

    def kill(self):
        self.returncode = -9

    async def wait(self):
        return self.returncode


def make(tmp_path, mode=None):
    clock = Clock()
    started = []

    async def launcher(camera):
        started.append(camera)
        return FakeProc()

    eye = E.EyeControl(logging.getLogger("test"), path=tmp_path / "eye.json", clock=clock, launcher=launcher)
    if mode:
        asyncio.run(eye.set_mode(mode))
    return eye, clock, started


def ev(name, unit="crawl", **extra):
    return dict({"type": "event", "unit": unit, "name": name}, **extra)


def test_off_by_default_and_on_runs(tmp_path):
    eye, _, started = make(tmp_path)
    assert eye.mode == "off" and not eye.running
    asyncio.run(eye.set_mode("on"))
    assert eye.running and started == ["Brio"]
    asyncio.run(eye.set_mode("off"))
    assert not eye.running


def test_mode_is_remembered(tmp_path):
    make(tmp_path, "auto")
    again, _, _ = make(tmp_path)
    assert again.mode == "auto"


def test_auto_follows_the_creatures_sensor_with_a_grace(tmp_path):
    eye, clock, _ = make(tmp_path, "auto")
    assert not eye.running
    assert eye.observe(ev("someone_in_front"), "crawl")
    asyncio.run(eye.apply())
    assert eye.running
    eye.observe(ev("someone_left"), "crawl")
    clock.t += 60
    asyncio.run(eye.apply())
    assert eye.running                                   # stepped away briefly: still on
    clock.t += 61
    asyncio.run(eye.apply())
    assert not eye.running


def test_the_eyes_own_sightings_do_not_keep_auto_on(tmp_path):
    eye, _, _ = make(tmp_path, "auto")
    assert not eye.observe(ev("someone_in_front", via="eye"), "crawl")
    assert not eye.observe(ev("someone_in_front", unit="other"), "crawl")
    asyncio.run(eye.apply())
    assert not eye.running


def test_unknown_mode_is_refused(tmp_path):
    eye, _, _ = make(tmp_path)
    assert not asyncio.run(eye.set_mode("sometimes"))
    assert eye.mode == "off"


def test_the_hub_announces_the_eye_to_apps():
    import json
    import bridge as B

    class WS:
        def __init__(self):
            self.sent = []

        async def send(self, text):
            self.sent.append(json.loads(text))

    store = B.Store()
    app = WS()
    store.clients.add(app)
    store.eye = E.EyeControl(logging.getLogger("test"), path=pathlib.Path("/nonexistent/eye.json"))
    asyncio.run(B.announce_eye(store, force=True))
    assert app.sent[0]["type"] == "eye" and app.sent[0]["mode"] == "off"
    asyncio.run(B.announce_eye(store))
    assert len(app.sent) == 1                              # unchanged: not sent again
