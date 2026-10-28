"""The creature's daily rules, on a fake clock."""
import datetime as dt
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import life as L  # noqa: E402


class Clock:
    def __init__(self, when):
        self.t = when.timestamp()

    def __call__(self):
        return self.t

    def advance(self, seconds):
        self.t += seconds


def make(when):
    clock = Clock(when)
    return L.Life(clock=clock), clock


def ev(name, unit="crawl"):
    return {"type": "event", "unit": unit, "name": name}


def state(unit="crawl", **fields):
    return dict({"type": "state", "unit": unit}, **fields)


def kinds(notices):
    return [k for _, k, _ in notices]


def test_greets_after_being_away():
    life, clock = make(dt.datetime(2026, 10, 27, 14, 0))
    life.observe(ev("someone_in_front"))
    clock.advance(60)
    life.observe(ev("someone_left"))
    clock.advance(25 * 60)
    actions, notices = life.observe(ev("someone_in_front"))
    assert kinds(notices) == ["greet"]
    assert any(cmd["cmd"] == "gesture" and cmd["name"] == "wag" for _, cmd in actions)


def test_no_greeting_for_a_short_absence():
    life, clock = make(dt.datetime(2026, 10, 27, 14, 0))
    life.observe(ev("someone_in_front"))
    life.observe(ev("someone_left"))
    clock.advance(5 * 60)
    _, notices = life.observe(ev("someone_in_front"))
    assert notices == []


def test_break_reminder_once_per_fifty_minutes():
    life, clock = make(dt.datetime(2026, 10, 27, 14, 0))
    life.observe(ev("someone_in_front"))
    clock.advance(49 * 60)
    assert life.tick() == ([], [])
    clock.advance(2 * 60)
    _, notices = life.tick()
    assert kinds(notices) == ["break"]
    clock.advance(60)
    assert life.tick()[1] == []


def test_warm_room_by_rise_with_cooldown():
    life, clock = make(dt.datetime(2026, 10, 27, 14, 0))
    life.observe(state(temp_c=26.0))
    clock.advance(20 * 60)
    _, notices = life.observe(state(temp_c=27.8))
    assert kinds(notices) == ["warm"]
    clock.advance(5 * 60)
    assert life.observe(state(temp_c=28.5))[1] == []


def test_goodnight_once_when_quiet_and_empty_at_night():
    life, clock = make(dt.datetime(2026, 10, 27, 22, 30))
    life.observe(state(sound_db=30.0))
    for _ in range(11):
        clock.advance(60)
        life.observe(state(sound_db=31.0))
    _, notices = life.tick()
    assert kinds(notices) == ["goodnight"]
    clock.advance(60)
    assert life.tick()[1] == []


def test_noise_resets_the_quiet_timer():
    life, clock = make(dt.datetime(2026, 10, 27, 23, 0))
    life.observe(state(sound_db=30.0))
    clock.advance(9 * 60)
    life.observe(state(sound_db=50.0))
    clock.advance(3 * 60)
    life.observe(state(sound_db=30.0))
    assert life.tick()[1] == []


def test_good_morning_after_the_night():
    life, clock = make(dt.datetime(2026, 10, 27, 23, 0))
    life.observe(ev("someone_in_front"))
    life.observe(ev("someone_left"))
    clock.t = dt.datetime(2026, 10, 28, 7, 30).timestamp()
    _, notices = life.observe(ev("someone_in_front"))
    assert kinds(notices) == ["morning"]


def test_hub_notices_do_not_feed_back():
    life, _ = make(dt.datetime(2026, 10, 27, 14, 0))
    assert life.observe({"type": "event", "unit": "crawl", "name": "someone_in_front", "link": "hub"}) == ([], [])


def test_morning_and_goodnight_carry_recaps():
    clock = Clock(dt.datetime(2026, 10, 27, 23, 0))
    facts = lambda unit, since, until: {"present_s": 3 * 3600 + 600, "temp_min": 26.8, "temp_max": 27.8, "loud_events": 0}
    life = L.Life(clock=clock, facts=facts)
    life.observe(state(sound_db=30.0))
    for _ in range(11):
        clock.advance(60)
        life.observe(state(sound_db=30.5))
    _, notices = life.tick()
    assert notices[0][2] == "Goodnight. Today you spent 3 h 10 min at the desk with me. The room is quiet now."
    clock.t = dt.datetime(2026, 10, 28, 7, 30).timestamp()
    _, notices = life.observe(ev("someone_in_front"))
    assert notices[0][2] == "Good morning. Overnight it was 27° to 28°, and quiet all night."


def test_recap_failure_keeps_the_greeting():
    def broken(*_):
        raise OSError("no log")
    life, clock = make(dt.datetime(2026, 10, 28, 7, 30))
    life.facts = broken
    _, notices = life.observe(ev("someone_in_front"))
    assert notices[0][2] == "Good morning."


def test_a_look_earns_a_silent_perk_with_cooldown():
    life, clock = make(dt.datetime(2026, 10, 27, 14, 0))
    actions, notices = life.observe(ev("looked_at"))
    assert notices == [] and ("crawl", {"cmd": "gesture", "name": "perk"}) in actions
    assert not any(cmd["cmd"] == "chirp" for _, cmd in actions)
    clock.advance(60)
    assert life.observe(ev("looked_at")) == ([], [])
    clock.advance(61)
    assert life.observe(ev("looked_at"))[0]


def test_wave_gets_a_wave_back_with_cooldown():
    life, clock = make(dt.datetime(2026, 10, 27, 14, 0))
    actions, _ = life.observe(ev("waved"))
    assert ("crawl", {"cmd": "gesture", "name": "wag"}) in actions
    clock.advance(10)
    assert life.observe(ev("waved")) == ([], [])


def test_open_palm_snoozes_notices_for_half_an_hour():
    life, clock = make(dt.datetime(2026, 10, 27, 14, 0))
    life.observe(ev("someone_in_front"))
    clock.advance(40 * 60)
    life.observe(ev("open_palm"))
    clock.advance(11 * 60)                                # a break would be due, but the creature was told not now
    assert life.tick() == ([], [])
    clock.advance(30 * 60)
    assert kinds(life.tick()[1]) == ["break"]             # and it comes once the snooze is over
    life2, clock2 = make(dt.datetime(2026, 10, 27, 14, 0))
    life2.observe(ev("open_palm"))
    clock2.advance(31 * 60)
    _, notices = life2.observe(state(temp_c=30.0))        # snooze over: the warm rule speaks again
    assert kinds(notices) == ["warm"]


def test_ten_minutes_hunched_earns_one_posture_nudge():
    life, clock = make(dt.datetime(2026, 10, 27, 14, 0))
    life.observe(ev("someone_in_front"))
    life.observe(ev("slouching"))
    clock.advance(8 * 60)
    assert life.tick()[1] == []
    clock.advance(60)
    assert kinds(life.tick()[1]) == ["posture"]
    clock.advance(60)
    assert life.tick()[1] == []                            # once, not every tick


def test_sitting_up_cancels_the_nudge():
    life, clock = make(dt.datetime(2026, 10, 27, 14, 0))
    life.observe(ev("someone_in_front"))
    life.observe(ev("slouching"))
    clock.advance(5 * 60)
    life.observe(ev("sat_up"))
    clock.advance(10 * 60)
    assert life.tick()[1] == []


def test_a_stretch_restarts_the_break_timer():
    life, clock = make(dt.datetime(2026, 10, 27, 14, 0))
    life.observe(ev("someone_in_front"))
    clock.advance(45 * 60)
    life.observe(ev("stretched"))
    clock.advance(10 * 60)                                 # 55 min at the desk, but a stretch 10 min ago
    assert life.tick()[1] == []
    clock.advance(41 * 60)
    assert kinds(life.tick()[1]) == ["break"]


def test_three_tired_signs_in_the_evening_suggest_calling_it_a_day():
    life, clock = make(dt.datetime(2026, 10, 27, 21, 0))
    assert life.observe(ev("yawned"))[1] == []
    clock.advance(120)
    assert life.observe(ev("eyes_heavy"))[1] == []
    clock.advance(120)
    _, notices = life.observe(ev("yawned"))
    assert notices == [("crawl", "tired", "You look tired. Maybe call it a day?")]
    clock.advance(60)
    for name in ("yawned", "yawned", "yawned"):
        assert life.observe(ev(name))[1] == []             # at most every two hours


def test_tired_signs_spread_out_do_not_count():
    life, clock = make(dt.datetime(2026, 10, 27, 15, 0))
    for _ in range(3):
        assert life.observe(ev("yawned"))[1] == []
        clock.advance(10 * 60)
