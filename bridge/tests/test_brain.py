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
    for var in ("ANTHROPIC_API_KEY", "CONSCIOUS_API_URL", "CONSCIOUS_API_KEY", "CONSCIOUS_MODEL"):
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


def test_conscious_gateway_wins_and_is_free(brain):
    BR.KEY_FILE.write_text("sk-test\n")
    BR.ENV_FILE.write_text("CONSCIOUS_API_URL=http://127.0.0.1:8400/p/fennec\nCONSCIOUS_API_KEY=k\nCONSCIOUS_MODEL=gpt-oss-20b\n")
    fake = FakeMessages(text="Cosy in here.")
    with_fake_client(brain, fake)
    status = brain.status()
    assert status["provider"] == "conscious" and status["local"] and status["model"] == "gpt-oss-20b"
    assert asyncio.run(brain.answer("crawl", HISTORY, "temperature 26 C")) == "Cosy in here."
    call = fake.calls[0]
    assert call["model"] == "gpt-oss-20b" and "betas" not in call and isinstance(call["system"], str)
    assert brain.status()["spent_today_usd"] == 0.0


def test_local_model_ignores_the_spending_cap(brain):
    BR.ENV_FILE.write_text("CONSCIOUS_API_URL=http://x/p/fennec\nCONSCIOUS_API_KEY=k\n")
    brain.configure(daily_cap_usd=0)
    assert brain.ready() == (True, "")
