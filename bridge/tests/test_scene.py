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
    two_faces = [[0.2, 0.5, 0.1, 0.15, 1], [0.6, 0.5, 0.1, 0.15, 0]]
    assert scene.guess(here(people=2, faces=two_faces, things=["phone"]), now) == "with_someone"
    assert scene.guess(here(people=2, faces=two_faces[:1]), now) == "working"        # a second body without a face
    assert scene.guess(here(things=["phone", "drink"]), now) == "on_phone"
    assert scene.guess(here(things=["drink"], looking=True), now) == "drinking"
    assert scene.guess(here(looking=True), now) == "working"


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


def test_the_models_words_reach_what_the_rules_cannot_see():
    clock = Clock()
    scene = S.Scene(clock=clock)
    run(scene, clock, here(), 2)
    assert scene.describe("A person at a desk on a video call, wearing headphones.") == []      # once is not enough
    assert scene.describe("The person is on a video call.") == ["call"]
    assert run(scene, clock, here(), 10) == ["on_call"]
    assert "The camera's model says" in scene.sentence()
    clock.t += S.HINT_S
    assert run(scene, clock, here(), 10) == ["working"]          # the hint wears off without new words


def test_model_hints_join_what_the_hands_hold():
    clock = Clock()
    scene = S.Scene(clock=clock)
    scene.describe("Someone typing on a laptop while holding a mug of coffee.")
    scene.describe("The person holds a mug.")
    assert scene.update(here()) == "drinking"
    scene.describe("Someone writing in a notebook with a pen.")
    assert set(scene.describe("The person is writing on paper.")) == {"writing"}


def test_the_model_seeing_an_empty_desk_overrules_a_shaky_detection():
    clock = Clock()
    scene = S.Scene(clock=clock)
    run(scene, clock, here(), 2)
    scene.describe("Nobody is at the desk.")
    scene.describe("No one is in the picture.")
    assert run(scene, clock, here(), 10) == ["away"]
    scene.describe("Nobody is at the desk.")
    assert run(scene, clock, here(faces=[[0.4, 0.5, 0.1, 0.15, 1]]), 10) == ["working"]   # a face: someone is there


def test_guesses_after_possibly_are_not_hints():
    scene = S.Scene(clock=Clock())
    assert scene.describe("The person is sitting and looking down, possibly typing or writing on paper.") == []
    assert scene.describe("The person is eating something at the desk.") == []
    assert scene.describe("The person eats a sandwich.") == ["food"]
    assert scene.describe("The person appears to be on a video call.") == []


def test_a_correction_is_believed_and_recorded():
    clock = Clock()
    scene = S.Scene(clock=clock)
    scene.describe("The person is on a video call.")
    scene.describe("The person is on a video call.")
    run(scene, clock, here(faces=[[0.4, 0.5, 0.1, 0.15, 1]]), 10)
    assert scene.activity == "on_call"
    record = scene.correct("working")
    assert record["wrong"] == "on_call" and record["right"] == "working" and record["hints"] == ["call"]
    assert record["faces"] == 1 and record["seen"]["present"] is True
    assert scene.activity == "working"
    assert run(scene, clock, here(), 60) == []                         # held, and the call hint is gone
    clock.t += S.CORRECTED_S
    assert run(scene, clock, here(things=["phone"]), 10) == ["on_phone"]   # then the eye decides again


def test_marking_the_sentence_wrong_drops_its_hints():
    scene = S.Scene(clock=Clock())
    scene.describe("The person is writing on paper.")
    scene.describe("The person writes on paper.")
    assert "writing" in scene.hints(scene.clock())
    record = scene.correct(description_wrong=True)
    assert record["description_wrong"] and not scene.hints(scene.clock())


def state(**fields):
    return dict({"type": "state", "unit": "crawl"}, **fields)


def test_sound_and_talking_join_the_picture():
    clock = Clock()
    scene = S.Scene(clock=clock)
    for _ in range(20):                                    # learn the room's quiet level
        scene.room(state(sound_db=32.0))
        clock.t += 5
    run(scene, clock, here(), 2)
    assert scene.summary()["sound"] == "quiet" and "talking" not in scene.summary()
    for _ in range(3):
        scene.room(state(sound_db=46.0))
        clock.t += 4
    scene.update(here())
    s = scene.summary()
    assert s["sound"] == "voices" and s["talking"] is True
    assert "voices in the room" in scene.sentence()


def test_distance_sensor_keeps_the_picture_without_the_camera():
    clock = Clock()
    scene = S.Scene(clock=clock)
    scene.room(state(tof_mm=600))
    s = scene.summary()                                    # the eye never sent anything
    assert s["activity"] == "at_desk" and s["confidence"] == "low"
    scene.room(state(tof_mm=74))                           # something right in front of the sensor
    assert scene.summary() is None


def test_senses_agreeing_or_not_moves_the_confidence():
    clock = Clock()
    scene = S.Scene(clock=clock)
    face = [[0.4, 0.5, 0.1, 0.15, 1]]
    scene.room(state(tof_mm=600))
    run(scene, clock, here(faces=face), 2)
    assert scene.summary()["confidence"] == "high"
    scene.room(state(tof_mm=3000))
    run(scene, clock, here(), 1)
    assert scene.summary()["confidence"] == "low"


def test_being_moved_is_mentioned():
    clock = Clock()
    scene = S.Scene(clock=clock)
    run(scene, clock, here(), 2)
    scene.room({"type": "event", "unit": "crawl", "name": "picked_up"})
    assert "I was just moved" in scene.sentence()
