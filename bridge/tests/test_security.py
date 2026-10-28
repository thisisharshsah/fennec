"""Pairing, tokens and the certificate."""
import json
import pathlib
import ssl
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import security as S  # noqa: E402


class Clock:
    def __init__(self):
        self.t = 1_000_000.0

    def __call__(self):
        return self.t


def devices(tmp_path):
    clock = Clock()
    return S.Devices(path=tmp_path / "devices.json", clock=clock), clock


def test_no_pairing_without_the_window(tmp_path):
    d, _ = devices(tmp_path)
    assert d.pair("phone") is None


def test_pair_once_per_window_and_check_token(tmp_path):
    d, clock = devices(tmp_path)
    d.open_window("button")
    device_id, token = d.pair("Harsh's iPhone")
    assert d.pair("second") is None                      # the window closes after one device
    assert d.check(token)["id"] == device_id
    assert d.check("wrong") is None and d.check(None) is None
    stored = json.loads((tmp_path / "devices.json").read_text())
    assert token not in json.dumps(stored)               # only a digest is kept


def test_window_expires(tmp_path):
    d, clock = devices(tmp_path)
    d.open_window("button")
    clock.t += S.PAIRING_WINDOW_S + 1
    assert d.pair("late") is None


def test_revoke(tmp_path):
    d, _ = devices(tmp_path)
    d.open_window("cli")
    device_id, token = d.pair("old phone")
    assert d.revoke(device_id)
    assert d.check(token) is None


def test_bearer_and_loopback():
    assert S.bearer({"Authorization": "Bearer abc"}) == "abc"
    assert S.bearer({"x-fennec-token": "xyz"}) == "xyz"
    assert S.bearer({}) is None
    assert S.is_loopback("127.0.0.1") and S.is_loopback("::1")
    assert not S.is_loopback("192.168.1.169")


def test_certificate_and_fingerprint(tmp_path, monkeypatch):
    monkeypatch.setattr(S, "TLS_DIR", tmp_path / "tls")
    ctx = S.server_context()
    assert isinstance(ctx, ssl.SSLContext)
    fp = S.certificate_fingerprint()
    assert len(fp) == 64 and fp == S.certificate_fingerprint()


def test_sign_line_matches_the_firmware_formula():
    import hashlib, hmac
    key = bytes(range(32))
    line = S.sign_line(key, "a1b2c3d4e5f60718", 7, '{"cmd":"ping"}')
    want = hmac.new(key, b'a1b2c3d4e5f60718|7|{"cmd":"ping"}', hashlib.sha256).hexdigest()
    assert line == f'S 7 {want} {{"cmd":"ping"}}'


def test_hello_auth(tmp_path):
    import hashlib, hmac
    keys = S.UnitKeys(path=tmp_path / "keys.json")
    key = keys.new("crawl")
    auth = hmac.new(key, b"hello|n0nce|crawl", hashlib.sha256).hexdigest()
    assert S.hello_auth_ok(key, "n0nce", "crawl", auth)
    assert not S.hello_auth_ok(key, "other", "crawl", auth)
    assert not S.hello_auth_ok(key, "n0nce", "crawl", "")
    keys.rename("crawl", "fox")
    assert keys.get("fox") == key and keys.get("crawl") is None
