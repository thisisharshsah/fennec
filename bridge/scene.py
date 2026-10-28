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
    "with_creature": "paying attention to the creature",
    "working": "working at the desk",
}
SETTLE_S = 8
STRETCH_SHOWS_S = 20
FRESH_S = 10                     # an outline older than this means the eye stopped
HINT_S = 45                      # a description's hints count this long (descriptions come every ~20 s)
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
        self._hints = {}                  # hint -> when it was last said

    def describe(self, text):
        """The local model's sentence about the scene. Returns the hints found in it."""
        now = self.clock()
        self.note, self.note_at = text.strip(), now
        sure = re.split(r"\b(?:possibly|perhaps|maybe|might|could be)\b", text, flags=re.IGNORECASE)[0]
        found = [h for h, pattern in HINT_WORDS.items() if re.search(pattern, sure, re.IGNORECASE)]
        for h in found:
            self._hints[h] = now
        return found

    def hints(self, now):
        return {h for h, at in self._hints.items() if now - at < (NOBODY_S if h == "nobody" else HINT_S)}
    def guess(self, v, now):
        people = v.get("people") or 0
        hints = self.hints(now)
        if not v.get("present") and people == 0:
            return "away"
        if "nobody" in hints and people <= 1 and not v.get("faces"):
            return "away"                 # the model saw an empty desk; one body box without a face is not enough
        if people >= 2:
            return "with_someone"
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
        if v.get("looking"):
            return "with_creature"
        return "working"

    def update(self, outline):
        """Feed one outline from the eye. Returns the new activity when it changed, else None."""
        now = self.clock()
        self.view, self.view_at = outline, now
        if outline.get("sign") == "stretched":
            self._stretched_at = now
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
        """The current picture for the agent and the apps, or None when the eye is not sending."""
        if not self.fresh():
            return None
        v, now = self.view, self.clock()
        out = {"activity": self.activity, "label": LABELS[self.activity], "for_s": round(now - self.since),
               "people": v.get("people", 0), "looking_at_creature": bool(v.get("looking"))}
        for key in ("posture", "things"):
            if v.get(key):
                out[key] = v[key]
        if v.get("tired"):
            out["tired"] = True
        if self.note and now - self.note_at < NOTE_FRESH_S:
            out["description"] = self.note
        return out

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
        held = [t for t in s.get("things", []) if t not in ("cat", "dog")]
        if held and s["activity"] not in ("on_phone", "eating", "drinking", "reading"):
            parts.append("holding " + ", ".join(held))
        pets = [t for t in s.get("things", []) if t in ("cat", "dog")]
        if pets:
            parts.append("a " + " and a ".join(pets) + " in view")
        line = ", ".join(parts)
        if s.get("description"):
            line += f'. The camera\'s model says: "{s["description"]}"'
        return line
