"""
What is happening at the desk right now, as one activity: everything the eye reports (presence,
how many people, looking, posture, tiredness, signs, things in hand) folded into a single guess
with how long it has lasted, plus the details worth saying alongside it.

A new activity must hold for SETTLE_S before it counts, so a glance at a phone is not phone time.
Pure logic with an injectable clock; the hub feeds it the eye's outlines and logs each change as
an "activity" event of the creature, from which the day's totals are counted.

A local vision-language model (tools/describe) adds a sentence about the scene every 20 s or so.
Its words become hints for a while (a video call, a phone, writing on paper), so the activity can be
one the fixed detectors cannot see.
"""
import collections
import re
import time

LABELS = {
    "away": "away from the desk",
    "with_someone": "with someone",
    "on_call": "on a video call",
    "on_phone": "on the phone",
    "eating": "eating",
    "drinking": "having a drink",
    "stretching": "stretching",
    "reading": "reading",
    "writing": "writing on paper",
    "gaming": "playing a game",
    "watching": "watching a video",
    "at_desk": "at the desk (the camera is off)",
    "working": "working at the desk",
}
SETTLE_S = 8
STRETCH_SHOWS_S = 20
FRESH_S = 10                     # an outline older than this means the eye stopped
HINT_S = 45                      # a description's hints count this long (descriptions come every ~20 s)
SOUND_WINDOW_S = 10 * 60          # the room's own quiet level is learned over this long
VOICES_DB = 10.0                  # this far above the quiet level: voices or music
LOUD_DB = 25.0
TALK_S = 8                        # voice-level sound this long, with someone here: talking
NEAR_MM, BLOCKED_MM = 1200, 150   # the distance sensor: someone within NEAR_MM; closer than BLOCKED_MM is an object
MOVED_SHOWS_S = 60
CORRECTED_S = 90                 # after the owner says what they are doing, believe them this long
NOBODY_S = 25                    # "nobody is at the desk" overrules a shaky body detection until the next one
NOTE_FRESH_S = 90
HINT_WORDS = {                   # words in the model's sentence -> a hint
    "call": r"video call|video conference|zoom|meeting|webcam call",
    "phone": r"\b(?:phone|smartphone|cellphone|mobile)\b",
    "drink": r"\b(?:mug|cup|drinking|coffee|tea|bottle|glass of)\b",
    "food": r"\b(?:eating|food|sandwich|snack|meal|plate|bowl|fruit)\b",
    "book": r"\b(?:reading a book|book|magazine)\b",
    "writing": r"\b(?:writing|notebook|pen|pencil|paper)\b",
    "gaming": r"game controller|playing a (?:video )?game|gaming",
    "watching": r"watching (?:a )?(?:video|movie|show|tv)|youtube",
    "nobody": r"nobody|no one|empty (?:desk|chair|room)",
}


class Scene:
    def __init__(self, clock=time.time):
        self.clock = clock
        self.activity = None
        self.since = None
        self.view = {}
        self.view_at = 0.0
        self._candidate = None
        self._candidate_since = None
        self._stretched_at = float("-inf")
        self.note = None                  # the model's latest sentence
        self.note_at = float("-inf")
        self._hints = {}                  # hint -> when it was last confirmed
        self._recent = collections.deque(maxlen=3)   # the hints of the last three sentences
        self._corrected = None            # (activity, until): what the owner said they are doing
        # the creature's own senses
        self._sounds = collections.deque()
        self.sound_db = None
        self._voices_since = None
        self.tof_mm = None
        self.tof_at = float("-inf")
        self._moved_at = float("-inf")

    def room(self, msg):
        """A state or event from the creature itself: sound, the distance sensor, being moved."""
        now = self.clock()
        if msg.get("type") == "event" and msg.get("name") in ("moved", "picked_up", "shaken"):
            self._moved_at = now
        if msg.get("type") != "state":
            return
        db = msg.get("sound_db")
        if isinstance(db, (int, float)):
            self.sound_db = db
            self._sounds.append((now, db))
            while self._sounds and now - self._sounds[0][0] > SOUND_WINDOW_S:
                self._sounds.popleft()
            if self.sound_level() in ("voices", "loud"):
                self._voices_since = self._voices_since or now
            else:
                self._voices_since = None
        mm = msg.get("tof_mm")
        if isinstance(mm, (int, float)):
            self.tof_mm, self.tof_at = mm, now

    def sound_level(self):
        """quiet, voices or loud, against the quietest the room has been lately."""
        if self.sound_db is None or len(self._sounds) < 5:
            return None
        quiet = sorted(db for _, db in self._sounds)[len(self._sounds) // 10]
        rise = self.sound_db - quiet
        return "loud" if rise >= LOUD_DB else "voices" if rise >= VOICES_DB else "quiet"

    def talking(self, now):
        return self._voices_since is not None and now - self._voices_since >= TALK_S

    def distance_sensor(self, now):
        """someone, nobody, blocked (an object right in front of it), or None when it has not reported."""
        if self.tof_mm is None or now - self.tof_at > 30:
            return None
        if 0 < self.tof_mm < BLOCKED_MM:
            return "blocked"
        return "someone" if 0 < self.tof_mm < NEAR_MM else "nobody"

    def describe(self, text):
        """The local model's sentence about the scene. Returns the hints found in it."""
        now = self.clock()
        self.note, self.note_at = text.strip(), now
        sure = re.split(r"\b(?:possibly|perhaps|maybe|might|could be|appears? to|seems? to|likely)\b", text,
                        flags=re.IGNORECASE)[0]
        found = [h for h, pattern in HINT_WORDS.items() if re.search(pattern, sure, re.IGNORECASE)]
        self._recent.append(set(found))
        # a small model makes things up now and then: a hint counts once two of the last three sentences say it
        confirmed = [h for h in found if sum(h in r for r in self._recent) >= 2]
        for h in confirmed:
            self._hints[h] = now
        return confirmed

    def hints(self, now):
        return {h for h, at in self._hints.items() if now - at < (NOBODY_S if h == "nobody" else HINT_S)}
    def guess(self, v, now):
        people = v.get("people") or 0
        hints = self.hints(now)
        if not v.get("present") and people == 0:
            return "away"
        if "nobody" in hints and people <= 1 and not v.get("faces"):
            return "away"                 # the model saw an empty desk; one body box without a face is not enough
        if people >= 2 and len(v.get("faces") or []) >= 2:
            return "with_someone"             # two faces: a chair or a poster can pass for a body, rarely for a face
        things = set(v.get("things") or []) | (hints & {"phone", "drink", "food", "book"})
        if "call" in hints:
            return "on_call"
        if "phone" in things:
            return "on_phone"
        if "food" in things:
            return "eating"
        if "drink" in things:
            return "drinking"
        if now - self._stretched_at < STRETCH_SHOWS_S:
            return "stretching"
        if "book" in things:
            return "reading"
        for hint in ("writing", "gaming", "watching"):
            if hint in hints:
                return hint
        # facing the camera is not an activity: beside a screen it looks the same as working
        return "working"

    def correct(self, right=None, description_wrong=False):
        """The owner says the scene is wrong. Returns what the eye knew at that moment, for tuning:
        the activity it showed, the outline's facts, the model's last sentence and hints."""
        now = self.clock()
        v = self.view
        record = {"wrong": self.activity, "right": right, "description_wrong": bool(description_wrong),
                  "for_s": round(now - self.since) if self.since else None,
                  "description": self.note if now - self.note_at < NOTE_FRESH_S else None,
                  "hints": sorted(self.hints(now)),
                  "seen": {k: v.get(k) for k in ("people", "present", "looking", "posture", "tired", "things", "sign")},
                  "faces": len(v.get("faces") or []), "hands": len(v.get("hands") or []),
                  "bodies": len(v.get("bodies") or [])}
        if description_wrong:                       # the model's words stop counting
            self._hints.clear()
            self._recent.clear()
        if right in LABELS:
            self._hints.clear()
            self._corrected = (right, now + CORRECTED_S)
            self.activity, self.since, self._candidate = right, now, None
        return record

    def update(self, outline):
        """Feed one outline from the eye. Returns the new activity when it changed, else None."""
        now = self.clock()
        self.view, self.view_at = outline, now
        if outline.get("sign") == "stretched":
            self._stretched_at = now
        if self._corrected and now < self._corrected[1]:
            return None                              # the owner said what is going on: hold it a while
        self._corrected = None
        guess = self.guess(outline, now)
        if guess == self.activity:
            self._candidate = None
            return None
        if guess != self._candidate:
            self._candidate, self._candidate_since = guess, now
        if self.activity is None or now - self._candidate_since >= SETTLE_S:
            self.activity, self.since = guess, self._candidate_since
            self._candidate = None
            return guess
        return None

    def fresh(self):
        return self.activity is not None and self.clock() - self.view_at < FRESH_S

    def summary(self):
        """The current picture for the agent and the apps, from every sense. Without the eye, the
        distance sensor can still say someone is at the desk; with neither, None."""
        now = self.clock()
        if not self.fresh():
            if self.distance_sensor(now) != "someone":
                return None
            out = {"activity": "at_desk", "label": LABELS["at_desk"], "for_s": 0, "people": None,
                   "looking_at_creature": False, "confidence": "low", "distance_sensor": "someone"}
            self._senses(out, now)
            return out
        v = self.view
        out = {"activity": self.activity, "label": LABELS[self.activity], "for_s": round(now - self.since),
               "people": v.get("people", 0), "looking_at_creature": bool(v.get("looking"))}
        for key in ("posture", "things"):
            if v.get(key):
                out[key] = v[key]
        if v.get("tired"):
            out["tired"] = True
        if self.note and now - self.note_at < NOTE_FRESH_S:
            out["description"] = self.note
        self._senses(out, now)
        # how sure: a face, the model and the distance sensor agreeing raise it; disagreeing lowers it
        hints = self.hints(now)
        here = self.activity != "away"
        sensor = out.get("distance_sensor")
        sure = (0.5 + (0.2 if v.get("faces") else 0) + (0.2 if hints - {"nobody"} else 0) - (0.4 if "nobody" in hints else 0)
                + (0.15 if sensor == ("someone" if here else "nobody") else 0)
                - (0.25 if sensor == ("nobody" if here else "someone") else 0))
        out["confidence"] = "high" if sure >= 0.7 else "low" if sure < 0.4 else "medium"
        return out

    def _senses(self, out, now):
        """What the creature's own senses add: sound, talking, the distance sensor, being moved."""
        level = self.sound_level()
        if level:
            out["sound"] = level
        if self.talking(now) and out["activity"] not in ("away",):
            out["talking"] = True
        sensor = self.distance_sensor(now)
        if sensor:
            out["distance_sensor"] = sensor
        if now - self._moved_at < MOVED_SHOWS_S:
            out["creature_moved"] = True

    def sentence(self):
        """One line for the brain: "working at the desk for 25 min, slouching, looks tired, holding a drink"."""
        s = self.summary()
        if not s:
            return None
        minutes = s["for_s"] // 60
        parts = [s["label"] + (f" for {minutes} min" if minutes else " just now")]
        if s.get("posture") == "slouching":
            parts.append("slouching")
        elif s.get("posture") == "close":
            parts.append("leaning close to the screen")
        if s.get("tired"):
            parts.append("looks tired")
        if s.get("talking"):
            parts.append("talking" if s["activity"] in ("on_call", "on_phone", "with_someone") else "voices in the room")
        elif s.get("sound") == "loud":
            parts.append("the room is loud")
        if s.get("creature_moved"):
            parts.append("I was just moved")
        held = [t for t in s.get("things", []) if t not in ("cat", "dog")]
        if held and s["activity"] not in ("on_phone", "eating", "drinking", "reading"):
            parts.append("holding " + ", ".join(held))
        pets = [t for t in s.get("things", []) if t in ("cat", "dog")]
        if pets:
            parts.append("a " + " and a ".join(pets) + " in view")
        line = ", ".join(parts)
        if s.get("description"):
            line += f'. The camera\'s model says: "{s["description"]}"'
        if s.get("confidence") == "low":
            line += ". (Not sure about this.)"
        return line
