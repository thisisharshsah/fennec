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
WARM_WINDOW_S = 30 * 60
WARM_COOLDOWN_S = 60 * 60
NIGHT_START_H, NIGHT_END_H = 22, 4
QUIET_FOR_S = 10 * 60            # empty and quiet this long at night: goodnight
QUIET_MARGIN_DB = 4.0            # quiet means within this of the quietest level seen recently
MORNING_START_H, MORNING_END_H = 5, 12
MORNING_GAP_S = 4 * 3600         # first presence after this long away in the morning


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


class Life:
    def __init__(self, clock=time.time, local=None):
        self.clock = clock
        self.local = local or (lambda ts: dt.datetime.fromtimestamp(ts))
        self.units = {}
        self.enabled = True

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
            return self._event(unit, msg.get("name"), now)
        if kind == "state":
            return self._state(unit, msg, now)
        return [], []

    def tick(self):
        if not self.enabled:
            return [], []
        now = self.clock()
        actions, notices = [], []
        for unit, u in self.units.items():
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
                    notices.append((unit, "goodnight", "Goodnight. The room is quiet."))
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
                notices.append((unit, "morning", "Good morning."))
            elif away is not None and away >= GREET_AFTER_S and now - u.last_greet >= GREET_COOLDOWN_S:
                u.last_greet = now
                actions += self._body(unit, "pleased", "wag", "hello")
                notices.append((unit, "greet", f"Welcome back. You were away {self._duration(away)}."))
        elif name == "someone_left" and u.present:
            u.present, u.left_at = False, now
            u.present_since = None
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
            if (temp >= WARM_LIMIT_C or temp - lowest >= WARM_RISE_C) and now - u.last_warm >= WARM_COOLDOWN_S:
                u.last_warm = now
                actions += self._body(unit, "alert", None, None)
                why = f"up {temp - lowest:.1f}° in the last half hour" if temp - lowest >= WARM_RISE_C else "above 29°"
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
