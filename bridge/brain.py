"""
The creature answers back: when the owner replies in Chat, a language model
writes the creature's answer from the room's context and the recent conversation.

Where the answer comes from, in order:
1. Farhelm, the owner's model hub, which keeps the models and the ones tuned for
   Crawl: FARHELM_API_URL and FARHELM_API_KEY from the environment or from
   fennec/.env. FARHELM_MODELS lists the models to ask, first one that answers
   wins (default `companion`, Farhelm's name for the tuned Qwen 3.5 4B).
2. Crawl's own copy on the hub, for when Farhelm cannot be reached (and for a
   creature away from the Mac): the same tuned model run with MLX on a thread
   of its own, loaded only when needed. Used when its adapter is present
   (FENNEC_BRAIN_ADAPTER, default data/train/adapters) and mlx_lm is installed;
   FENNEC_BRAIN_MODEL=off skips it.
   Like Farhelm itself, nothing local ever falls back to a cloud model.
3. Claude directly, only when nothing local is set up: ANTHROPIC_API_KEY, or the
   file data/anthropic_key. A daily spending cap (data/brain.json, default
   0.50 USD) applies.
Keys and adapters are ignored by git.
"""
import asyncio
import concurrent.futures
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
FARHELM_MODELS = "companion"                             # Farhelm's name for the tuned Qwen 3.5 4B (qwen3.5-4b:conscious)
OWN_MODEL = "mlx-community/Qwen3.5-4B-4bit"             # benchmark: grounded 0.95, judge 3.9 / 4.7 / 3.8
OWN_ADAPTER = DATA / "train" / "adapters" / "Qwen3.5-4B-4bit"
MISSING_RETRY_S = 600                                   # how long a model Farhelm lacks is skipped
OWN_TOKENS = 160                                        # what the benchmark gave it; replies are two sentences

PERSONA = """You are {name}, a small creature that lives on your owner's desk. You look like a little \
fox with big ears and round cheeks that glow in different colours. You cannot walk yet; the words you \
write arrive on your owner's phone as messages from you, and the phone may read them out in your voice.

What you can sense: sound level and claps, whether someone is in front of you, temperature, humidity, air \
pressure, being picked up, shaken or tapped. A camera beside you tells you, as facts and a short sentence \
(never the picture itself), whether your owner is there, what they seem to be doing, their posture, whether \
they look tired, signs they make and what is in their hands. These facts can be wrong now and then. You \
know nothing beyond the room facts you are given. Never invent readings or events; if you do not know, say \
so simply.

How you talk: warm, curious, a little playful, never sugary. One or two short sentences, plain text only, \
no markdown, no lists, no emoji unless the owner uses them first. Speak as yourself in the first person. \
Do not offer help like an assistant; you are a companion. If the owner asks for something you cannot do, \
say so in a friendly way. If they seem stressed or tired, be gentle and brief."""


def room_context(room, when=None):
    """The facts that go in front of the owner's message."""
    return "Room right now (from your sensors, " + (when or time.strftime("%A %H:%M")) + "):\n" + room


def thought_prompt(facts, recent, when=None):
    """What the brain is asked for one private thought."""
    earlier = "\n".join(f"- {t}" for t in recent[-4:]) or "- (none yet)"
    return ("What you sense right now (" + (when or time.strftime("%A %H:%M")) + "):\n" + facts
            + "\n\nYour last few thoughts:\n" + earlier
            + "\n\nWrite your next thought: one short first-person sentence, at most 20 words, about what "
              "you notice or wonder right now. Use only the facts above: you have no light sensor and see "
              "nothing beyond them, so do not invent sights, sounds or smells. Do not repeat your last "
              "thoughts. Do not address your owner unless something seems wrong; if it does, say it "
              "plainly and gently.")


class OwnModel:
    """The tuned small model, loaded in the background on first use. MLX keeps its GPU stream per
    thread, so loading and every answer happen on one thread of its own."""

    def __init__(self, log, model_id, adapter):
        self.log, self.model_id, self.adapter = log, model_id, adapter
        self._thread = concurrent.futures.ThreadPoolExecutor(max_workers=1, thread_name_prefix="own-brain")
        self._loading = None
        self._model = self._tokenizer = None
        self.failed = False

    @staticmethod
    def available(model_id, adapter):
        if model_id == "off" or not (pathlib.Path(adapter) / "adapters.safetensors").exists():
            return False
        try:
            import mlx_lm  # noqa: F401
        except ImportError:
            return False
        return True

    def _load(self):
        from mlx_lm import load
        started = time.time()
        self._model, self._tokenizer = load(self.model_id, adapter_path=str(self.adapter))
        self.log.info("own brain: %s loaded in %.0f s", self.model_id, time.time() - started)

    def start_loading(self):
        if self._loading is None:
            self._loading = asyncio.get_running_loop().run_in_executor(self._thread, self._load)
            self._loading.add_done_callback(self._loaded)

    def _loaded(self, future):
        if future.exception():
            self.failed = True
            self.log.warning("own brain: could not load %s: %s", self.model_id, future.exception())

    @property
    def ready(self):
        return self._model is not None

    def _generate(self, persona, turns):
        from mlx_lm import generate
        from mlx_lm.sample_utils import make_sampler
        msgs = [{"role": "system", "content": persona}] + [
            {"role": t["role"], "content": t["content"] if isinstance(t["content"], str)
             else "\n\n".join(part["text"] for part in t["content"])} for t in turns]
        prompt = self._tokenizer.apply_chat_template(msgs, add_generation_prompt=True, tokenize=False,
                                                     enable_thinking=False)
        text = generate(self._model, self._tokenizer, prompt, max_tokens=OWN_TOKENS,
                        sampler=make_sampler(temp=0.7, top_p=0.9))
        return text.split("</think>")[-1].strip().strip('"').strip()

    async def create(self, persona, turns):
        """The answer, or None while it is still loading or when it fails."""
        self.start_loading()
        if not self.ready:
            return None
        try:
            return await asyncio.get_running_loop().run_in_executor(self._thread, self._generate, persona, turns)
        except Exception as e:  # noqa: BLE001
            self.log.warning("own brain: %s", e)
            return None


class Brain:
    def __init__(self, log):
        self.log = log
        self._client = None
        self._key_seen = None
        self.last_answer = 0.0
        self._own = None
        self._missing = {}                                  # Farhelm model -> time to ask again

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

    def _env(self):
        return dict(self._dotenv(), **{k: v for k, v in os.environ.items()
                                       if k.startswith(("FARHELM_", "ANTHROPIC_", "FENNEC_BRAIN_"))})

    def own(self):
        """Crawl's own tuned model, when it is set up on this hub; else None."""
        env = self._env()
        model_id = env.get("FENNEC_BRAIN_MODEL", OWN_MODEL)
        adapter = pathlib.Path(env.get("FENNEC_BRAIN_ADAPTER", OWN_ADAPTER))
        if self._own is None or (self._own.model_id, self._own.adapter) != (model_id, adapter):
            self._own = OwnModel(self.log, model_id, adapter) if OwnModel.available(model_id, adapter) else None
        return self._own

    def provider(self):
        """("farhelm", url, key, [models]) or ("anthropic", None, key, [MODEL]) or None: the model hub,
        or Claude when nothing local is set up."""
        env = self._env()
        if env.get("FARHELM_API_URL") and env.get("FARHELM_API_KEY"):
            models = [m.strip() for m in env.get("FARHELM_MODELS", FARHELM_MODELS).split(",") if m.strip()]
            return ("farhelm", env["FARHELM_API_URL"].rstrip("/"), env["FARHELM_API_KEY"], models)
        if self.own():
            return None
        key = env.get("ANTHROPIC_API_KEY")
        if not key and KEY_FILE.exists():
            key = KEY_FILE.read_text().strip()
        return ("anthropic", None, key, [MODEL]) if key else None

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
        p, own = self.provider(), self.own()
        local = p is not None and p[0] == "farhelm"
        backups = (p[3][1:] if local else []) + (["Crawl's own copy on the hub"] if own and p else [])
        return {
            "enabled": st.get("enabled", True),
            "has_key": p is not None or own is not None,
            "provider": p[0] if p else ("own" if own else None),
            "local": local or (own is not None and p is None),
            "daily_cap_usd": st.get("daily_cap_usd", DEFAULT_DAILY_CAP),
            "spent_today_usd": round(spent, 4),
            "model": p[3][0] if p else ("Crawl's own copy" if own else MODEL),
            "fallback": ", then ".join(backups) or None,
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
            if p[0] == "farhelm":           # Anthropic-style /v1/messages on the owner's gateway
                self._client = anthropic.AsyncAnthropic(base_url=p[1], api_key=p[2], max_retries=1)
            else:
                self._client = anthropic.AsyncAnthropic(api_key=p[2])
            self._key_seen = p
        return self._client

    # the answer

    @staticmethod
    def _transcript(history, limit=16):
        """Alternating user/assistant turns from the message log, ending with the owner."""
        turns = []
        for item in [h for h in history if h.get("kind") != "thought"][-limit:]:   # private thoughts are not said
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
        context = room_context(room)
        turns[-1] = {"role": "user", "content": [
            {"type": "text", "text": context},
            {"type": "text", "text": turns[-1]["content"]},
        ]}
        text = await self._create(PERSONA.format(name=name.capitalize()), turns, "answered")
        return text

    async def think(self, name, facts, recent):
        """One private thought about what the creature senses right now, or None when it stays quiet."""
        ok, why = self.ready()
        if not ok:
            return None
        self.last_answer = time.time()
        return await self._create(PERSONA.format(name=name.capitalize()),
                                  [{"role": "user", "content": thought_prompt(facts, recent)}], "thought")

    async def _create(self, persona, turns, what):
        provider = self.provider()
        if provider and provider[0] == "farhelm":
            for model in provider[3]:                     # Farhelm never swaps models itself: ask each in turn
                if self._missing.get(model, 0) > time.time():
                    continue
                text = await self._create_remote(persona, turns, what, provider, model)
                if text:
                    return text
        own = self.own()
        if own:
            started = time.time()
            text = await own.create(persona, turns)       # starts loading the first time; quiet until it has
            if text:
                self.log.info("brain: %s in %d chars by its own copy (%.1f s)", what, len(text), time.time() - started)
            elif not own.failed:
                self.log.info("brain: own copy still loading")
            return text
        if provider and provider[0] == "anthropic":
            return await self._create_remote(persona, turns, what, provider, MODEL)
        return None

    async def _create_remote(self, persona, turns, what, provider, model):
        import anthropic
        try:
            if provider[0] == "farhelm":
                # the hub takes the plain Messages shape; Claude only features stay off
                response = await self._get_client().messages.create(
                    model=model, max_tokens=MAX_TOKENS, system=persona, messages=turns)
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
            self.log.warning("brain: the %s key was rejected", provider[0])
            return None
        except anthropic.RateLimitError:
            self.log.warning("brain: rate limited")
            return None
        except anthropic.APIStatusError as e:
            self.log.warning("brain: %s error %s %s", model, e.status_code, e.message)
            return None
        except anthropic.APIConnectionError:
            self.log.warning("brain: no connection to %s", provider[0])
            return None
        ran = getattr(response, "model", None) or model
        if provider[0] == "farhelm" and not str(ran).endswith(model) and model not in str(ran):
            # Farhelm serves an undeclared name with the client's default model: not the one asked for
            self.log.info("brain: Farhelm has no %s yet (it would use %s)", model, ran)
            self._missing[model] = time.time() + MISSING_RETRY_S
            return None
        cost = 0.0 if provider[0] == "farhelm" else self._record_cost(response.usage)
        if response.stop_reason == "refusal":
            self.log.info("brain: declined (%.4f USD)", cost)
            return None
        text = " ".join(b.text for b in response.content if b.type == "text").strip()
        self.log.info("brain: %s in %d chars by %s (%.4f USD)", what, len(text), ran, cost)
        return text or None
