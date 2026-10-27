import pytest

pytest_plugins = ("pytest_asyncio",)


@pytest.fixture(autouse=True)
def _asyncio_mode(monkeypatch):
    yield
