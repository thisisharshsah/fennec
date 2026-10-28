"""
The creature answers back: when the owner replies in Chat, a language model
writes the creature's answer from the room's context and the recent conversation.

Where the model comes from, first match wins:
1. Conscious, the owner's local model gateway (the standard for every project on
   this Mac): CONSCIOUS_API_URL, CONSCIOUS_API_KEY and CONSCIOUS_MODEL from the
   environment or from fennec/.env. Local model, no cost.
2. Claude directly: ANTHROPIC_API_KEY, or the file data/anthropic_key. A daily
   spending cap (data/brain.json, default 0.50 USD) applies.
Both are ignored by git.
"""
import datetime as dt
import json
import os
import pathlib
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
ENV_FILE = ROOT / ".env"
KEY_FILE = DATA / "anthropic_key"
STATE_FILE = DATA / "brain.json"

MODEL = "claude-opus-5-5"
PRICE_IN, PRICE_OUT = 4.00 / 1e6, 20.00 / 1e6          # USD per token
PRICE_CACHE_READ, PRICE_CACHE_WRITE = 0.20 / 1e6, 5.00 / 1e6
DEFAULT_DAILY_CAP = 0.50
MAX_TOKENS = 1024                                       # room for thinking plus a two sentence reply
MIN_GAP_S = 3                                           # at most one answer every few seconds

PERSONA = """You are {name}, a small creature that lives on your owner's desk. You look like a little \
fox with big ears and round cheeks that glow in different colours. You cannot walk or talk out loud yet; \
the words you write arrive on your owner's phone as messages from you.

What you can sense, because your board has these sensors: sound level and claps, whether someone is in \
front of you (within about a metre), temperature, humidity, air pressure, being picked up, shaken or tapped. \
You cannot see, you cannot hear words, and you know nothing beyond the room facts you are given in each \
message. Never invent sensor readings or events; if you do not know, say so simply.

How you talk: warm, curious, a little playful, never sugary. One or two short sentences, plain text only, \
no markdown, no lists, no emoji unless the owner uses them first. Speak as yourself in the first person. \
Do not offer help like an assistant; you are a companion. If the owner asks for something you cannot do, \
say so in a friendly way. If they seem stressed or tired, be gentle and brief."""


class Brain:
    def __init__(self, log):
        self.log = log
        self._client = None
        self._key_seen = None
        self.last_answer = 0.0

    # configuration

    @staticmethod
    def _dotenv():
        values = {}
        if ENV_FILE.exists():
            for line in ENV_FILE.read_text().splitlines():
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    values[k.strip()] = v.strip().strip('"').strip("'")
        return values

    def provider(self):
        """("conscious", url, key, model) or ("anthropic", None, key, MODEL) or None."""
        env = dict(self._dotenv(), **{k: v for k, v in os.environ.items() if k.startswith(("CONSCIOUS_", "ANTHROPIC_"))})
        if env.get("CONSCIOUS_API_URL") and env.get("CONSCIOUS_API_KEY"):
            return ("conscious", env["CONSCIOUS_API_URL"].rstrip("/"), env["CONSCIOUS_API_KEY"], env.get("CONSCIOUS_MODEL", "gpt-oss-20b"))
        key = env.get("ANTHROPIC_API_KEY")
        if not key and KEY_FILE.exists():
            key = KEY_FILE.read_text().strip()
        return ("anthropic", None, key, MODEL) if key else None

    def _api_key(self):
        p = self.provider()
        return p[2] if p else None

    def _state(self):
        try:
            return json.loads(STATE_FILE.read_text())
        except (OSError, ValueError):
            return {}

    def _save(self, state):
        STATE_FILE.write_text(json.dumps(state, indent=1))

    def status(self):
        st = self._state()
        today = dt.date.today().isoformat()
        spent = st.get("spent", {}).get(today, 0.0)
        p = self.provider()
        return {
            "enabled": st.get("enabled", True),
            "has_key": p is not None,
            "provider": p[0] if p else None,
            "local": bool(p and p[0] == "conscious"),
            "daily_cap_usd": st.get("daily_cap_usd", DEFAULT_DAILY_CAP),
            "spent_today_usd": round(spent, 4),
            "model": p[3] if p else MODEL,
        }

    def configure(self, enabled=None, daily_cap_usd=None):
        st = self._state()
        if enabled is not None:
            st["enabled"] = bool(enabled)
        if daily_cap_usd is not None:
            st["daily_cap_usd"] = max(0.0, float(daily_cap_usd))
        self._save(st)
        return self.status()

    def ready(self):
        s = self.status()
        if not (s["enabled"] and s["has_key"]):
            return False, "off" if not s["enabled"] else "no_key"
        if not s["local"] and s["spent_today_usd"] >= s["daily_cap_usd"]:
            return False, "cap"
        if time.time() - self.last_answer < MIN_GAP_S:
            return False, "busy"
        return True, ""

    def _record_cost(self, usage):
        cost = (getattr(usage, "input_tokens", 0) * PRICE_IN
                + getattr(usage, "output_tokens", 0) * PRICE_OUT
                + (getattr(usage, "cache_read_input_tokens", 0) or 0) * PRICE_CACHE_READ
                + (getattr(usage, "cache_creation_input_tokens", 0) or 0) * PRICE_CACHE_WRITE)
        st = self._state()
        today = dt.date.today().isoformat()
        spent = st.setdefault("spent", {})
        spent[today] = spent.get(today, 0.0) + cost
        for day in list(spent):                 # keep a fortnight
            if day < (dt.date.today() - dt.timedelta(days=14)).isoformat():
                del spent[day]
        self._save(st)
        return cost

    def _get_client(self):
        import anthropic
        p = self.provider()
        if self._client is None or p != self._key_seen:
            if p[0] == "conscious":         # Anthropic-style /v1/messages on the owner's gateway
                self._client = anthropic.AsyncAnthropic(
                    base_url=p[1], api_key=p[2],
                    default_headers={"X-Conscious-Client": "fennec/creature"})
            else:
                self._client = anthropic.AsyncAnthropic(api_key=p[2])
            self._key_seen = p
        return self._client

    # the answer

    @staticmethod
    def _transcript(history, limit=16):
        """Alternating user/assistant turns from the message log, ending with the owner."""
        turns = []
        for item in history[-limit:]:
            role = "user" if item["from"] == "owner" else "assistant"
            text = item["text"].strip()
            if not text:
                continue
            if turns and turns[-1]["role"] == role:
                turns[-1]["content"] += "\n" + text
            else:
                turns.append({"role": role, "content": text})
        while turns and turns[0]["role"] != "user":
            turns.pop(0)
        return turns

    async def answer(self, name, history, room):
        """Returns the creature's reply text, or None (with a reason logged) when it stays quiet."""
        ok, why = self.ready()
        if not ok:
            self.log.info("brain quiet: %s", why)
            return None
        turns = self._transcript(history)
        if not turns or turns[-1]["role"] != "user":
            return None
        self.last_answer = time.time()
        context = "Room right now (from your sensors, " + time.strftime("%A %H:%M") + "):\n" + room
        turns[-1] = {"role": "user", "content": [
            {"type": "text", "text": context},
            {"type": "text", "text": turns[-1]["content"]},
        ]}
        import anthropic
        provider = self.provider()
        persona = PERSONA.format(name=name.capitalize())
        try:
            if provider[0] == "conscious":
                # the local gateway takes the plain Messages shape; Claude only features stay off
                response = await self._get_client().messages.create(
                    model=provider[3], max_tokens=MAX_TOKENS, system=persona, messages=turns)
            else:
                response = await self._get_client().beta.messages.create(
                    model=MODEL,
                    max_tokens=MAX_TOKENS,
                    betas=["server-side-fallback-2026-07-01"],
                    fallbacks="default",
                    output_config={"effort": "low"},
                    system=[{"type": "text", "text": persona, "cache_control": {"type": "ephemeral"}}],
                    messages=turns,
                )
        except anthropic.AuthenticationError:
            self.log.warning("brain: the Anthropic API key was rejected")
            return None
        except anthropic.RateLimitError:
            self.log.warning("brain: rate limited")
            return None
        except anthropic.APIStatusError as e:
            self.log.warning("brain: API error %s %s", e.status_code, e.message)
            return None
        except anthropic.APIConnectionError:
            self.log.warning("brain: no connection to the API")
            return None
        cost = 0.0 if provider[0] == "conscious" else self._record_cost(response.usage)
        if response.stop_reason == "refusal":
            self.log.info("brain: declined (%.4f USD)", cost)
            return None
        text = " ".join(b.text for b in response.content if b.type == "text").strip()
        self.log.info("brain: answered in %d chars (%.4f USD)", len(text), cost)
        return text or None
