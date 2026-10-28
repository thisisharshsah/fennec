"""
The creature's ongoing thoughts: a short first-person line when what it senses changes (at most every
MIN_GAP_S) or every EVERY_S otherwise, while someone is around. With the brain on, the local model
writes the thought from everything the creature senses, which is where it weighs it all up; without
it, a few templates over the same facts. The hub logs each thought as an event, so it shows in the
conversation as a thought bubble and the agent can read it.
"""
import collections
import time

EVERY_S = 6 * 60
MIN_GAP_S = 2 * 60
LONG_WORK_S = 45 * 60
WARM_C = 29.0

OPENERS = {
    "working": ["You're working. I'll keep you company.", "Busy at the desk. I like the quiet tapping."],
    "on_phone": ["You're on your phone. I wonder what's on it.", "Phone time. I'll wait."],
    "on_call": ["You're on a call. I'll be very quiet."],
    "drinking": ["A drink! Good idea.", "Having a sip. Nice."],
    "eating": ["Something to eat. I hope it's good."],
    "reading": ["You're reading. I'll keep still."],
    "writing": ["Writing on paper. I like watching your hand move."],
    "gaming": ["A game! I hope you're winning."],
    "watching": ["Watching something. Is it good?"],
    "stretching": ["A stretch! That looks good."],
    "with_someone": ["Someone else is here. Hello, whoever you are!"],
    "away": ["The desk is empty. I'll keep watch."],
}


class Mind:
    def __init__(self, clock=time.time):
        self.clock = clock
        self.last_at = float("-inf")
        self.last_key = None
        self.recent = collections.deque(maxlen=6)

    @staticmethod
    def key(summary, temp):
        """What a thought is about: a new key is something new to think about."""
        if not summary:
            return None
        return (summary["activity"], summary.get("posture") == "slouching", bool(summary.get("tired")),
                temp is not None and temp >= WARM_C)

    def due(self, key):
        if key is None:
            return False
        since = self.clock() - self.last_at
        if since < MIN_GAP_S:
            return False
        if key[0] == "away" and self.last_key and self.last_key[0] == "away":
            return False                      # one thought about an empty desk is enough
        return key != self.last_key or since >= EVERY_S

    def noted(self, key, text):
        self.last_at, self.last_key = self.clock(), key
        self.recent.append(text)

    def template(self, summary, temp):
        """A thought without a model: what is going on, and one thing worth adding."""
        activity = summary["activity"]
        options = OPENERS.get(activity, OPENERS["working"])
        line = options[int(self.clock() // 60) % len(options)]
        if activity == "working" and summary.get("for_s", 0) >= LONG_WORK_S:
            line = f"You've been working for {summary['for_s'] // 60} minutes. A stretch might feel good."
        if activity != "away":
            if summary.get("tired"):
                line += " You look tired, though."
            elif summary.get("posture") == "slouching":
                line += " You're a bit hunched. Shoulders back?"
            elif temp is not None and temp >= WARM_C:
                line += f" It's getting warm in here, {temp:.0f}°."
            elif summary.get("talking") and activity not in ("on_call", "on_phone", "with_someone"):
                line += " I can hear voices."
        return line
