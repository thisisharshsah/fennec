"""Safety alarms on a fake clock."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import safety as S  # noqa: E402


class Clock:
    def __init__(self):
        self.t = 1_000_000.0

    def __call__(self):
        return self.t


def make(tmp_path):
    clock = Clock()
    return S.Safety(path=tmp_path / "safety.json", clock=clock), clock


def notices(out):
    return [(kind, text) for item in out if item[0] == "notice" for kind, text in [item[2:]]]


def vision(slumped=0, sign=None):
    return {"type": "vision", "unit": "eye", "slumped_s": slumped, "sign": sign}


def ev(name, **extra):
    return dict({"type": "event", "unit": "crawl", "name": name}, **extra)


def test_check_in_then_alarm_without_an_answer(tmp_path):
    s, clock = make(tmp_path)
    assert s.observe(vision(slumped=200), "crawl") == []
    out = s.observe(vision(slumped=S.STILL_ASK_S), "crawl")
    assert [k for k, _ in notices(out)] == ["checkin"]
    assert s.observe(vision(slumped=S.STILL_ASK_S + 1), "crawl") == []      # asked once
    clock.t += S.ANSWER_S
    assert [k for k, _ in notices(s.tick())] == ["alarm"]


def test_a_nod_or_moving_answers_the_check_in(tmp_path):
    for answer in (ev("nodded"), vision(slumped=0), ev("speech", via="notification", link="hub")):
        s, clock = make(tmp_path)
        s.observe(vision(slumped=S.STILL_ASK_S), "crawl")
        s.observe(answer, "crawl")
        clock.t += S.ANSWER_S
        assert s.tick() == []


def test_away_watch_and_settings_are_kept(tmp_path):
    s, clock = make(tmp_path)
    assert s.observe(ev("someone_in_front", via="eye"), "crawl") == []       # not away: nothing
    s.configure(away=True)
    out = s.observe(ev("someone_in_front", via="eye"), "crawl")
    assert notices(out) == [("alarm", "Someone is at your desk while you are away (seen by the camera).")]
    assert s.observe(ev("someone_in_front"), "crawl") == []                   # not again within 2 min
    assert S.Safety(path=tmp_path / "safety.json").away is True


def test_room_danger(tmp_path):
    s, clock = make(tmp_path)
    s.observe({"type": "state", "unit": "crawl", "temp_c": 26.0, "hum_pct": 40.0}, "crawl")
    clock.t += 300
    out = s.observe({"type": "state", "unit": "crawl", "temp_c": 30.5, "hum_pct": 41.0}, "crawl")
    assert notices(out)[0][0] == "alarm" and "Heat alarm" in notices(out)[0][1]
    out = s.observe({"type": "state", "unit": "crawl", "temp_c": 30.5, "hum_pct": 58.0, "sound_db": 92.0}, "crawl")
    assert [t.split()[0] for _, t in notices(out)] == ["Humidity", "A"]


def test_gone_dark_and_back(tmp_path):
    s, clock = make(tmp_path)
    s.observe({"type": "unit_status", "unit": "crawl", "connected": False}, "crawl")
    clock.t += 30
    assert s.tick() == []
    clock.t += 31
    assert "Gone dark" in notices(s.tick())[0][1]
    assert s.tick() == []
    assert notices(s.observe({"type": "unit_status", "unit": "crawl", "connected": True}, "crawl")) == [("alarm", "Back online.")]


def test_the_hub_sends_alarms_as_notices_and_body_commands(tmp_path, monkeypatch):
    import asyncio
    import bridge as B
    store = B.Store()
    store.safety = S.Safety(path=tmp_path / "safety.json")
    sent, commands = [], []

    async def post(store, unit, kind, text):
        sent.append((unit, kind, text))

    async def route(store, cmd):
        commands.append(cmd)

    monkeypatch.setattr(B, "post_notice", post)
    monkeypatch.setattr(B, "route_command", route)
    asyncio.run(B.run_safety(store, [("notice", "crawl", "alarm", "Heat alarm"), ("cmd", "crawl", {"cmd": "express", "mood": "alert"})]))
    assert sent == [("crawl", "alarm", "Heat alarm")] and commands == [{"cmd": "express", "mood": "alert", "unit": "crawl"}]
