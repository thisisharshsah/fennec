"""The creature's answering brain, with a fake Claude client (no network, no key needed)."""
import asyncio
import logging
import pathlib
import sys
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import brain as BR  # noqa: E402


@pytest.fixture
def brain(tmp_path, monkeypatch):
    monkeypatch.setattr(BR, "KEY_FILE", tmp_path / "anthropic_key")
    monkeypatch.setattr(BR, "STATE_FILE", tmp_path / "brain.json")
    monkeypatch.setattr(BR, "ENV_FILE", tmp_path / ".env")
    monkeypatch.setattr(BR, "OWN_ADAPTER", tmp_path / "adapter")         # no own model unless a test adds one
    for var in ("ANTHROPIC_API_KEY", "FARHELM_API_URL", "FARHELM_API_KEY", "FARHELM_MODEL",
                "FENNEC_BRAIN_MODEL", "FENNEC_BRAIN_ADAPTER"):
        monkeypatch.delenv(var, raising=False)
    return BR.Brain(logging.getLogger("test"))


class FakeMessages:
    def __init__(self, text="Hello! The room feels calm.", stop="end_turn"):
        self.calls = []
        self.text, self.stop = text, stop

    async def create(self, **kwargs):
        self.calls.append(kwargs)
        return SimpleNamespace(
            content=[SimpleNamespace(type="thinking", thinking=""), SimpleNamespace(type="text", text=self.text)],
            stop_reason=self.stop,
            usage=SimpleNamespace(input_tokens=1000, output_tokens=100, cache_read_input_tokens=0, cache_creation_input_tokens=0),
        )


def with_fake_client(brain, messages):
    brain._get_client = lambda: SimpleNamespace(beta=SimpleNamespace(messages=messages), messages=messages)


HISTORY = [
    {"from": "creature", "text": "Welcome back."},
    {"from": "owner", "text": "hi crawl"},
    {"from": "owner", "text": "how warm is it?"},
]


def test_quiet_without_a_key(brain):
    assert brain.ready() == (False, "no_key")
    assert asyncio.run(brain.answer("crawl", HISTORY, "temperature 27 C")) is None


def test_transcript_starts_with_owner_and_merges_runs():
    turns = BR.Brain._transcript(HISTORY)
    assert [t["role"] for t in turns] == ["user"]
    assert turns[0]["content"] == "hi crawl\nhow warm is it?"


def test_answers_with_room_context_and_records_cost(brain):
    BR.KEY_FILE.write_text("sk-test\n")
    fake = FakeMessages()
    with_fake_client(brain, fake)
    text = asyncio.run(brain.answer("crawl", HISTORY, "temperature 27.4 C"))
    assert text == "Hello! The room feels calm."
    call = fake.calls[0]
    assert call["model"] == "claude-opus-5-5"
    assert call["fallbacks"] == "default" and call["betas"] == ["server-side-fallback-2026-07-01"]
    assert call["system"][0]["cache_control"] == {"type": "ephemeral"}
    assert "temperature 27.4 C" in call["messages"][-1]["content"][0]["text"]
    assert brain.status()["spent_today_usd"] == pytest.approx(1000 * 4e-6 + 100 * 20e-6, abs=1e-6)


def test_daily_cap_stops_it(brain):
    BR.KEY_FILE.write_text("sk-test\n")
    brain.configure(daily_cap_usd=0.005)
    with_fake_client(brain, FakeMessages())
    assert asyncio.run(brain.answer("crawl", HISTORY, "")) is not None      # costs 0.006
    brain.last_answer = 0
    assert brain.ready() == (False, "cap")


def test_refusal_stays_quiet(brain):
    BR.KEY_FILE.write_text("sk-test\n")
    with_fake_client(brain, FakeMessages(stop="refusal"))
    assert asyncio.run(brain.answer("crawl", HISTORY, "")) is None


def test_switch_off(brain):
    BR.KEY_FILE.write_text("sk-test\n")
    brain.configure(enabled=False)
    assert brain.ready() == (False, "off")


def test_farhelm_hub_wins_and_is_free(brain):
    BR.KEY_FILE.write_text("sk-test\n")
    BR.ENV_FILE.write_text("FARHELM_API_URL=http://127.0.0.1:7842/p/fennec\nFARHELM_API_KEY=k\n")
    fake = FakeMessages(text="Cosy in here.")
    with_fake_client(brain, fake)
    status = brain.status()
    assert status["provider"] == "farhelm" and status["local"] and status["model"] == "crawl-4b"
    assert status["fallback"] == "crawl-2b"
    assert asyncio.run(brain.answer("crawl", HISTORY, "temperature 26 C")) == "Cosy in here."
    call = fake.calls[0]
    assert call["model"] == "crawl-4b" and "betas" not in call and isinstance(call["system"], str)
    assert brain.status()["spent_today_usd"] == 0.0


def test_local_model_ignores_the_spending_cap(brain):
    BR.ENV_FILE.write_text("FARHELM_API_URL=http://x/p/fennec\nFARHELM_API_KEY=k\n")
    brain.configure(daily_cap_usd=0)
    assert brain.ready() == (True, "")


class FakeOwn:
    """Stands in for the tuned model: answers with `text`, or None as while it loads."""
    def __init__(self, text):
        self.text, self.failed, self.calls = text, False, []

    async def create(self, persona, turns):
        self.calls.append(turns)
        return self.text


class FailingThenOk(FakeMessages):
    """Farhelm giving nothing for the first model (not loaded there), answering with the next."""
    async def create(self, **kwargs):
        reply = await super().create(**kwargs)
        if len(self.calls) == 1:
            reply.content = []
        return reply


def test_next_farhelm_model_when_the_first_fails(brain):
    BR.ENV_FILE.write_text("FARHELM_API_URL=http://x/p/fennec\nFARHELM_API_KEY=k\nFARHELM_MODELS=crawl-4b, crawl-2b\n")
    fake = FailingThenOk(text="From the 2B.")
    with_fake_client(brain, fake)
    assert asyncio.run(brain.answer("crawl", HISTORY, "")) == "From the 2B."
    assert [c["model"] for c in fake.calls] == ["crawl-4b", "crawl-2b"]


def test_own_copy_answers_when_farhelm_cannot(brain):
    BR.ENV_FILE.write_text("FARHELM_API_URL=http://x/p/fennec\nFARHELM_API_KEY=k\nFARHELM_MODELS=crawl-4b\n")
    own = FakeOwn("I hear you.")
    brain.own = lambda: own
    with_fake_client(brain, FakeMessages(text=""))          # Farhelm gives nothing back
    assert brain.status()["fallback"] == "Crawl's own copy on the hub"
    assert asyncio.run(brain.answer("crawl", HISTORY, "temperature 26 C")) == "I hear you."
    assert "temperature 26 C" in own.calls[0][-1]["content"][0]["text"]


def test_own_copy_alone_is_the_brain(brain):
    own = FakeOwn("Just me.")
    brain.own = lambda: own
    status = brain.status()
    assert status["provider"] == "own" and status["local"] and status["fallback"] is None
    assert asyncio.run(brain.answer("crawl", HISTORY, "")) == "Just me."


def test_own_model_never_falls_back_to_the_cloud(brain):
    BR.KEY_FILE.write_text("sk-test\n")
    own, cloud = FakeOwn(None), FakeMessages(text="From Claude.")
    brain.own = lambda: own
    with_fake_client(brain, cloud)
    assert brain.provider() is None and brain.ready() == (True, "")
    assert asyncio.run(brain.answer("crawl", HISTORY, "")) is None
    assert cloud.calls == []


def test_own_model_needs_its_adapter(tmp_path):
    assert not BR.OwnModel.available("mlx-community/x", tmp_path)
    assert not BR.OwnModel.available("off", tmp_path)


def test_a_substitute_model_from_farhelm_is_not_used(brain):
    BR.ENV_FILE.write_text("FARHELM_API_URL=http://x/p/fennec\nFARHELM_API_KEY=k\nFARHELM_MODELS=crawl-4b\n")
    own = FakeOwn("Me instead.")
    brain.own = lambda: own
    fake = FakeMessages(text="From the default model.")

    async def substitute(**kwargs):
        reply = await FakeMessages.create(fake, **kwargs)
        reply.model = "local/engine-gpt-oss-20b/gpt-oss-20b"
        return reply
    fake.create = substitute
    with_fake_client(brain, fake)
    assert asyncio.run(brain.answer("crawl", HISTORY, "")) == "Me instead."
    brain.last_answer = 0
    assert asyncio.run(brain.answer("crawl", HISTORY, "")) == "Me instead."
    assert len(fake.calls) == 1                              # the missing model is not asked again for a while
