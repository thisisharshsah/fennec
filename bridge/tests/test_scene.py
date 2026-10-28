"""One activity from everything the eye reports, on a fake clock."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import scene as S  # noqa: E402


class Clock:
    def __init__(self):
        self.t = 1_000_000.0

    def __call__(self):
        return self.t


def here(**extra):
    return dict({"present": True, "people": 1}, **extra)


def run(scene, clock, outline, seconds):
    """The same outline five times a second for a while; returns the changes."""
    changes = []
    for _ in range(int(seconds * 5)):
        changed = scene.update(outline)
        if changed:
            changes.append(changed)
        clock.t += 0.2
    return changes


def test_first_outline_sets_the_activity_at_once():
    clock = Clock()
    scene = S.Scene(clock=clock)
    assert scene.update(here()) == "working"


def test_a_glance_at_a_phone_is_not_phone_time():
    clock = Clock()
    scene = S.Scene(clock=clock)
    run(scene, clock, here(), 5)
    assert run(scene, clock, here(things=["phone"]), 3) == []
    assert run(scene, clock, here(), 5) == []
    assert run(scene, clock, here(things=["phone"]), 10) == ["on_phone"]
    assert scene.summary()["activity"] == "on_phone"


def test_priorities():
    scene = S.Scene(clock=Clock())
    now = 0
    assert scene.guess({"present": False, "people": 0}, now) == "away"
    assert scene.guess(here(people=2, things=["phone"]), now) == "with_someone"
    assert scene.guess(here(things=["phone", "drink"]), now) == "on_phone"
    assert scene.guess(here(things=["drink"], looking=True), now) == "drinking"
    assert scene.guess(here(looking=True), now) == "with_creature"


def test_a_stretch_shows_for_a_while():
    clock = Clock()
    scene = S.Scene(clock=clock)
    run(scene, clock, here(), 2)
    scene.update(here(sign="stretched"))
    assert run(scene, clock, here(), 10) == ["stretching"]
    assert run(scene, clock, here(), 20) == ["working"]


def test_sentence_and_stale_eye():
    clock = Clock()
    scene = S.Scene(clock=clock)
    run(scene, clock, here(posture="slouching", tired=True, things=["drink", "cat"]), 130)
    assert scene.sentence() == "having a drink for 2 min, slouching, looks tired, a cat in view"
    clock.t += S.FRESH_S + 1
    assert scene.summary() is None and scene.sentence() is None
