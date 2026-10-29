"""
Safety: alarms for when something may be wrong. Alerts go to the owner's own apps only (notices of
kind "checkin" and "alarm"); nothing leaves the house unless the ntfy relay (data/notify.json) is set
up. This is an extra pair of eyes, not an emergency service: it calls no one and can miss things.

  check-in     at the desk, slumped (no face, or eyes closed) and still for STILL_ASK_S: the creature
               asks "Are you OK?". A nod, thumbs-up, wave, reply, look or any movement is an answer;
               none within ANSWER_S raises an alarm.
  away watch   while the owner says they are away: someone at the desk, the creature moved or picked
               up, or a loud noise raises an alarm.
  room danger  heat rising fast or very hot, a very loud bang, humidity jumping. Rises are ignored for
               WARMUP_S after the creature starts, while it heats itself up.
  gone dark    the creature offline for longer than DARK_S.

Pure logic with an injectable clock: observe() takes hub messages, tick() runs the timers; both
return what to do as ("notice", unit, kind, text) and ("cmd", unit, command) items.
"""
import collections
import json
import pathlib
import time

SAFETY_FILE = pathlib.Path(__file__).resolve().parent.parent / "data" / "safety.json"
STILL_ASK_S = 5 * 60
ANSWER_S = 120
ALARM_COOLDOWN_S = 10 * 60          # per reason
AWAY_COOLDOWN_S = 2 * 60
HEAT_RISE_C = 4.0                   # within DANGER_WINDOW_S
HEAT_LIMIT_C = 40.0
HUMID_RISE_PCT = 15.0               # within DANGER_WINDOW_S
DANGER_WINDOW_S = 10 * 60
LOUD_DB = 85.0
DARK_S = 60
WARMUP_S = 20 * 60                  # after power on the board heats itself about 4 degrees: rises mean nothing yet
ANSWERS = {"nodded", "thumbs_up", "open_palm", "waved", "looked_at", "sat_up", "stretched", "knock", "shook_head"}
AWAY_EVENTS = {"someone_in_front": "Someone is at your desk", "moved": "Your creature was moved",
               "picked_up": "Your creature was picked up", "shaken": "Your creature was shaken"}


class Safety:
    def __init__(self, path=None, clock=time.time):
        self.path = path or SAFETY_FILE
        self.clock = clock
        saved = self._load()
        self.away = bool(saved.get("away", False))
        self.checkin = bool(saved.get("checkin", True))
        self.asked_at = None
        self.asked_unit = None
        self._alarmed = {}
        self._temps = collections.deque()
        self._hums = collections.deque()
        self._dark_since = {}
        self._dark_alarmed = set()
        self._warm_until = 0.0

    def _load(self):
        try:
            return json.loads(self.path.read_text())
        except (OSError, ValueError):
            return {}

    def _save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps({"away": self.away, "checkin": self.checkin}))

    def status(self):
        return {"type": "safety", "away": self.away, "checkin": self.checkin, "asking": self.asked_at is not None}

    def configure(self, away=None, checkin=None):
        if away is not None:
            self.away = bool(away)
        if checkin is not None:
            self.checkin = bool(checkin)
            if not self.checkin:
                self.asked_at = None
        self._save()

    # helpers

    def _alarm(self, unit, reason, text, cooldown=ALARM_COOLDOWN_S):
        now = self.clock()
        if now - self._alarmed.get(reason, float("-inf")) < cooldown:
            return []
        self._alarmed[reason] = now
        return [("notice", unit, "alarm", text), ("cmd", unit, {"cmd": "express", "mood": "alert"})]

    def _answered(self):
        if self.asked_at is None:
            return []
        unit = self.asked_unit
        self.asked_at = self.asked_unit = None
        return [("cmd", unit, {"cmd": "express", "mood": "pleased"})]

    # rules

    def observe(self, msg, creature):
        """One hub message. `creature` is the unit with a body (the eye's outlines count for it)."""
        kind = msg.get("type")
        unit = msg.get("unit")
        now = self.clock()
        out = []
        if kind == "vision" and creature:
            slumped = msg.get("slumped_s") or 0
            if self.asked_at is not None and (slumped == 0 or msg.get("sign") in ANSWERS):
                out += self._answered()
            elif self.checkin and self.asked_at is None and slumped >= STILL_ASK_S and not self.away:
                self.asked_at, self.asked_unit = now, creature
                out += [("notice", creature, "checkin",
                         "Are you OK? You have been very still for a while. Nod, give a thumbs-up or reply to tell me."),
                        ("cmd", creature, {"cmd": "express", "mood": "alert"}),
                        ("cmd", creature, {"cmd": "chirp", "name": "question"})]
            return out
        if unit != creature or not creature:
            return out
        if kind == "event" and msg.get("link") != "hub":
            name = msg.get("name")
            if name == "boot":
                self._warming(now)
            if name in ANSWERS:
                out += self._answered()
            if self.away and name in AWAY_EVENTS:
                where = " (seen by the camera)" if msg.get("via") == "eye" else ""
                out += self._alarm(unit, f"away:{name}", f"{AWAY_EVENTS[name]} while you are away{where}.",
                                   AWAY_COOLDOWN_S)
        elif kind == "event" and msg.get("name") == "speech" and msg.get("via") in ("notification", "gesture"):
            out += self._answered()                          # the owner replied
        elif kind == "state":
            out += self._room(unit, msg, now)
        elif kind == "unit_status":
            if msg.get("connected"):
                if unit in self._dark_since:                 # it was off: it starts cold again
                    self._warming(now)
                self._dark_since.pop(unit, None)
                if unit in self._dark_alarmed:
                    self._dark_alarmed.discard(unit)
                    out.append(("notice", unit, "alarm", "Back online."))
            else:
                self._dark_since.setdefault(unit, now)
        return out

    def _warming(self, now):
        self._warm_until = now + WARMUP_S
        self._temps.clear()
        self._hums.clear()

    def _room(self, unit, msg, now):
        out = []
        warming = now < self._warm_until                     # only the absolute limit counts while it warms up
        temp, hum, sound = msg.get("temp_c"), msg.get("hum_pct"), msg.get("sound_db")
        if isinstance(temp, (int, float)):
            self._temps.append((now, temp))
            while self._temps and now - self._temps[0][0] > DANGER_WINDOW_S:
                self._temps.popleft()
            rise = temp - min(t for _, t in self._temps)
            if temp >= HEAT_LIMIT_C or (rise >= HEAT_RISE_C and not warming):
                why = f"up {rise:.1f}° in ten minutes" if rise >= HEAT_RISE_C else "very hot"
                out += self._alarm(unit, "heat", f"Heat alarm: {temp:.1f}°, {why}. Is something burning?")
        if isinstance(hum, (int, float)):
            self._hums.append((now, hum))
            while self._hums and now - self._hums[0][0] > DANGER_WINDOW_S:
                self._hums.popleft()
            if hum - min(h for _, h in self._hums) >= HUMID_RISE_PCT and not warming:
                out += self._alarm(unit, "humidity", f"Humidity jumped to {hum:.0f} %. A leak, or steam?")
        if isinstance(sound, (int, float)) and sound >= LOUD_DB:
            text = f"A very loud bang ({sound:.0f} dB)" + (" while you are away." if self.away else ".")
            out += self._alarm(unit, "loud", text, AWAY_COOLDOWN_S if self.away else ALARM_COOLDOWN_S)
        return out

    def tick(self):
        now = self.clock()
        out = []
        if self.asked_at is not None and now - self.asked_at >= ANSWER_S:
            unit = self.asked_unit
            self.asked_at = self.asked_unit = None
            out += self._alarm(unit, "no_answer", "No answer after I asked if you were OK. Please check on yourself.", 0)
        for unit, since in list(self._dark_since.items()):
            if now - since >= DARK_S and unit not in self._dark_alarmed:
                self._dark_alarmed.add(unit)
                out.append(("notice", unit, "alarm", f"Gone dark: offline for {int(now - since)} s. Power cut, or unplugged?"))
        return out
