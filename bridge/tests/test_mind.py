"""The creature's ongoing thoughts, on a fake clock."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import mind as M  # noqa: E402


class Clock:
    def __init__(self):
        self.t = 1_000_000.0

    def __call__(self):
        return self.t


def summary(activity="working", **extra):
    return dict({"activity": activity, "for_s": 120}, **extra)


def test_thinks_on_change_but_not_too_often():
    clock = Clock()
    mind = M.Mind(clock=clock)
    key = M.Mind.key(summary(), 25.0)
    assert mind.due(key)
    mind.noted(key, "hi")
    assert not mind.due(M.Mind.key(summary("on_phone"), 25.0))           # changed, but only seconds later
    clock.t += M.MIN_GAP_S
    assert mind.due(M.Mind.key(summary("on_phone"), 25.0))
    mind.noted(key, "again")
    clock.t += M.MIN_GAP_S
    assert not mind.due(key)                                             # same thing: waits for EVERY_S
    clock.t += M.EVERY_S
    assert mind.due(key)


def test_one_thought_about_an_empty_desk():
    clock = Clock()
    mind = M.Mind(clock=clock)
    away = M.Mind.key(summary("away"), None)
    mind.noted(away, "The desk is empty.")
    clock.t += M.EVERY_S
    assert not mind.due(away)
    assert not mind.due(None)


def test_templates_add_one_worthwhile_detail():
    mind = M.Mind(clock=Clock())
    long = mind.template(summary(for_s=50 * 60, posture="slouching"), 25.0)
    assert long == "You've been working for 50 minutes. A stretch might feel good. You're a bit hunched. Shoulders back?"
    assert mind.template(summary("on_call", tired=True), 30.0).endswith("You look tired, though.")
    assert mind.template(summary("away"), 31.0) == "The desk is empty. I'll keep watch."


def test_a_thought_mentions_voices():
    mind = M.Mind(clock=Clock())
    assert mind.template(summary(talking=True), 25.0).endswith("I can hear voices.")
    assert not mind.template(summary("on_call", talking=True), 25.0).endswith("voices.")
