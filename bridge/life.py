"""
The creature's daily life: small rules that react to what its senses report.

Runs inside the hub, so it works without an agent session. Each rule turns
into body commands (mood, gesture, chirp) for the creature and a short
"notice" event that shows up in its Activity and in the agent's events.
Every rule has a cooldown so it never nags.

Pure logic with an injectable clock: observe() takes hub messages, tick()
runs the time based rules, both return what to do. The hub executes it.
"""
import collections
import datetime as dt
import time

GREET_AFTER_S = 20 * 60          # away at least this long counts as coming back
GREET_COOLDOWN_S = 10 * 60
BREAK_AFTER_S = 50 * 60          # sitting in front this long earns a nudge, and again every 50 min
WARM_LIMIT_C = 29.0
WARM_RISE_C = 1.5                # rise within WARM_WINDOW_S
WARM_RISE_FROM_C = 26.0          # a rise only counts when it ends this warm: 20.5 to 22 is not warm
WARM_WINDOW_S = 30 * 60
WARM_COOLDOWN_S = 60 * 60
NIGHT_START_H, NIGHT_END_H = 22, 4
QUIET_FOR_S = 10 * 60            # empty and quiet this long at night: goodnight
QUIET_MARGIN_DB = 4.0            # quiet means within this of the quietest level seen recently
MORNING_START_H, MORNING_END_H = 5, 12
MORNING_GAP_S = 4 * 3600         # first presence after this long away in the morning
LOOK_COOLDOWN_S = 2 * 60         # a perk when the owner looks at the creature, at most this often
WAVE_COOLDOWN_S = 30
SNOOZE_S = 30 * 60               # an open palm: no notices for this long
HAND_SIGNS = ("waved", "thumbs_up", "open_palm", "nodded", "shook_head")   # answers: they act even while snoozed
POSTURE_AFTER_S = 9 * 60         # after the eye's "slouching" (itself a minute in): about 10 min hunched
POSTURE_COOLDOWN_S = 30 * 60
STRETCH_COOLDOWN_S = 5 * 60
TIRED_SIGNS = 3                  # yawns or heavy eyes within TIRED_WINDOW_S
TIRED_WINDOW_S = 15 * 60
TIRED_COOLDOWN_S = 2 * 3600
EVENING_H = 19


class UnitLife:
    def __init__(self):
        self.present = False
        self.present_since = None
        self.left_at = None
        self.last_greet = 0.0
        self.last_break = 0.0
        self.last_warm = 0.0
        self.temps = collections.deque()
        self.sounds = collections.deque()
        self.quiet_since = None
        self.goodnight_day = None        # the date of the evening we said goodnight
        self.morning_day = None
        self.last_look = 0.0
        self.last_wave = 0.0
        self.slouch_since = None
        self.last_posture = 0.0
        self.last_stretch = 0.0
        self.tired_signs = collections.deque()
        self.last_tired = 0.0


class Life:
    def __init__(self, clock=time.time, local=None, facts=None):
        self.clock = clock
        self.local = local or (lambda ts: dt.datetime.fromtimestamp(ts))
        self.units = {}
        self.enabled = True
        self.snoozed_until = 0.0         # an open palm keeps the creature quiet until then
        # facts(unit, since, until) -> {"present_s", "temp_min", "temp_max", "loud_events"} from the log
        self.facts = facts

    def _u(self, name):
        return self.units.setdefault(name, UnitLife())

    # Each action is (unit, command dict); each notice is (unit, kind, text).

    def observe(self, msg):
        if not self.enabled:
            return [], []
        unit = msg.get("unit")
        if not unit or msg.get("link") == "hub":
            return [], []
        now = self.clock()
        kind = msg.get("type")
        if kind == "event":
            out = self._event(unit, msg.get("name"), now)
            return out if msg.get("name") in HAND_SIGNS else self._quiet(out, now)
        if kind == "state":
            return self._quiet(self._state(unit, msg, now), now)
        return [], []

    def _quiet(self, out, now):
        """While snoozed the rules still keep track of the room but neither act nor notify."""
        return ([], []) if now < self.snoozed_until else out

    def tick(self):
        if not self.enabled:
            return [], []
        now = self.clock()
        if now < self.snoozed_until:
            return [], []                    # postponed, not used up: the reminders come after the snooze
        actions, notices = [], []
        for unit, u in self.units.items():
            if (u.present and u.slouch_since and now - u.slouch_since >= POSTURE_AFTER_S
                    and now - u.last_posture >= POSTURE_COOLDOWN_S):
                u.last_posture = now
                actions += self._body(unit, "curious", "perk", None)
                notices.append((unit, "posture", "You have been hunched over for about 10 minutes. Sit up and roll your shoulders?"))
            if u.present and u.present_since and now - u.present_since >= BREAK_AFTER_S and now - u.last_break >= BREAK_AFTER_S:
                u.last_break = now
                minutes = int((now - u.present_since) // 60)
                actions += self._body(unit, "curious", "nod", "ok")
                notices.append((unit, "break", f"You have been here {minutes} minutes. Time for a short break?"))
            if self._is_night(now) and not u.present and u.quiet_since and now - u.quiet_since >= QUIET_FOR_S:
                night = self._night_key(now)
                if u.goodnight_day != night:
                    u.goodnight_day = night
                    actions += self._body(unit, "sleepy", "droop", "sleepy")
                    notices.append((unit, "goodnight", "Goodnight." + self._day_recap(unit, now)))
        return actions, notices

    # rules driven by events

    def _event(self, unit, name, now):
        u = self._u(unit)
        actions, notices = [], []
        if name == "someone_in_front" and not u.present:
            u.present, u.present_since = True, now
            u.quiet_since = None
            away = now - u.left_at if u.left_at else None
            hour = self.local(now).hour
            today = self.local(now).date()
            if (MORNING_START_H <= hour < MORNING_END_H and u.morning_day != today
                    and (away is None or away >= MORNING_GAP_S or u.goodnight_day is not None)):
                u.morning_day = today
                u.last_greet = now
                actions += self._body(unit, "pleased", "perk", "happy")
                notices.append((unit, "morning", "Good morning." + self._night_recap(unit, now)))
            elif away is not None and away >= GREET_AFTER_S and now - u.last_greet >= GREET_COOLDOWN_S:
                u.last_greet = now
                actions += self._body(unit, "pleased", "wag", "hello")
                notices.append((unit, "greet", f"Welcome back. You were away {self._duration(away)}."))
        elif name == "someone_left" and u.present:
            u.present, u.left_at = False, now
            u.present_since = None
            u.slouch_since = None
        elif name == "looked_at" and now - u.last_look >= LOOK_COOLDOWN_S and now >= self.snoozed_until:
            u.last_look = now                    # noticed: perk up, silently (no chirp, no notice)
            actions += self._body(unit, "pleased", "perk", None)
        elif name == "waved" and now - u.last_wave >= WAVE_COOLDOWN_S:
            u.last_wave = now                    # waves back
            actions += self._body(unit, "pleased", "wag", "hello")
        elif name in ("thumbs_up", "nodded"):
            actions += self._body(unit, "pleased", "nod", None)
        elif name == "shook_head":
            actions += self._body(unit, "neutral", None, None)
        elif name == "slouching":
            u.slouch_since = u.slouch_since or now
        elif name == "sat_up":
            u.slouch_since = None
        elif name == "stretched" and now - u.last_stretch >= STRETCH_COOLDOWN_S:
            u.last_stretch = now                 # a stretch is a short break: the break timer starts again
            if u.present:
                u.present_since = now
            u.slouch_since = None
            actions += self._body(unit, "pleased", "wag", None)
        elif name in ("yawned", "eyes_heavy"):
            u.tired_signs.append(now)
            while u.tired_signs and now - u.tired_signs[0] > TIRED_WINDOW_S:
                u.tired_signs.popleft()
            if (len(u.tired_signs) >= TIRED_SIGNS and now - u.last_tired >= TIRED_COOLDOWN_S
                    and now >= self.snoozed_until):
                u.last_tired = now
                u.tired_signs.clear()
                actions += self._body(unit, "sleepy", None, None)
                later = self.local(now).hour >= EVENING_H
                notices.append((unit, "tired", "You look tired. Maybe call it a day?" if later
                                else "You look tired. A proper break and some water?"))
        elif name == "open_palm":
            self.snoozed_until = now + SNOOZE_S  # not now: quiet for half an hour
            actions += self._body(unit, "neutral", "nod", None)
        return actions, notices

    # rules driven by readings

    def _state(self, unit, msg, now):
        u = self._u(unit)
        actions, notices = [], []
        temp = msg.get("temp_c")
        if isinstance(temp, (int, float)):
            u.temps.append((now, temp))
            while u.temps and now - u.temps[0][0] > WARM_WINDOW_S:
                u.temps.popleft()
            lowest = min(t for _, t in u.temps)
            rising = temp - lowest >= WARM_RISE_C and temp >= WARM_RISE_FROM_C
            if ((temp >= WARM_LIMIT_C or rising) and now - u.last_warm >= WARM_COOLDOWN_S
                    and now >= self.snoozed_until):
                u.last_warm = now
                actions += self._body(unit, "alert", None, None)
                why = f"up {temp - lowest:.1f}° in the last half hour" if rising else "above 29°"
                notices.append((unit, "warm", f"It is getting warm in here: {temp:.1f}°, {why}."))
        sound = msg.get("sound_db")
        if isinstance(sound, (int, float)):
            u.sounds.append((now, sound))
            while u.sounds and now - u.sounds[0][0] > 3600:
                u.sounds.popleft()
            floor = min(s for _, s in u.sounds)
            if sound <= floor + QUIET_MARGIN_DB:
                if u.quiet_since is None:
                    u.quiet_since = now
            else:
                u.quiet_since = None
        return actions, notices

    # daily recaps (best effort: a missing or failing facts source leaves the plain greeting)

    def _facts(self, unit, since, until):
        if not self.facts:
            return None
        try:
            return self.facts(unit, since, until)
        except Exception:
            return None

    def _night_recap(self, unit, now):
        t = self.local(now)
        evening = (t - dt.timedelta(days=1)).replace(hour=NIGHT_START_H, minute=0, second=0, microsecond=0)
        f = self._facts(unit, evening.timestamp(), now)
        if not f:
            return ""
        parts = []
        if f.get("temp_min") is not None and f.get("temp_max") is not None:
            lo, hi = f["temp_min"], f["temp_max"]
            parts.append(f"Overnight it stayed at {lo:.0f}°" if hi - lo < 0.6 else f"Overnight it was {lo:.0f}° to {hi:.0f}°")
        loud = f.get("loud_events", 0)
        if loud == 0:
            parts.append("and quiet all night")
        elif loud <= 3:
            parts.append("with a noise or two")
        else:
            parts.append("and fairly noisy")
        return " " + ", ".join(parts) + "."

    def _day_recap(self, unit, now):
        t = self.local(now)
        morning = t.replace(hour=MORNING_START_H, minute=0, second=0, microsecond=0)
        if t.hour < NIGHT_END_H:
            morning -= dt.timedelta(days=1)
        f = self._facts(unit, morning.timestamp(), now)
        if not f or not f.get("present_s"):
            return " The room is quiet."
        text = f" Today you spent {self._duration(f['present_s'])} at the desk with me."
        seen = f.get("activities") or {}
        extras = [f"about {self._duration(seen[k])} {what}" for k, what in
                  (("working", "working"), ("on_phone", "on your phone")) if seen.get(k, 0) >= 10 * 60]
        if extras:
            text = text[:-1] + ", " + " and ".join(extras) + "."
        if f.get("stretches"):
            n = f["stretches"]
            text += f" You stretched {'once' if n == 1 else f'{n} times'}."
        if f.get("slouched_s", 0) >= 15 * 60:
            text += f" You were hunched over for {self._duration(f['slouched_s'])}."
        return text + " The room is quiet now."

    # helpers

    @staticmethod
    def _body(unit, mood, gesture, chirp):
        out = []
        if mood:
            out.append((unit, {"cmd": "express", "mood": mood}))
        if gesture:
            out.append((unit, {"cmd": "gesture", "name": gesture}))
        if chirp:
            out.append((unit, {"cmd": "chirp", "name": chirp}))
        return out

    def _is_night(self, now):
        h = self.local(now).hour
        return h >= NIGHT_START_H or h < NIGHT_END_H

    def _night_key(self, now):
        t = self.local(now)
        return (t - dt.timedelta(hours=NIGHT_END_H)).date()   # 01:00 belongs to the evening before

    @staticmethod
    def _duration(seconds):
        minutes = int(seconds // 60)
        if minutes < 60:
            return f"{minutes} minutes"
        hours, minutes = divmod(minutes, 60)
        return f"{hours} h {minutes} min" if minutes else f"{hours} h"
