"""
Who may talk to the hub.

Trust model:
* Processes on this Mac (loopback) are trusted: the agent's tool server, scripts.
* Anything else on the network must present a device token. Tokens are issued
  only while a pairing window is open (60 s, opened by pressing the creature's
  blue button or from this Mac), so pairing needs someone physically present.
* The hub stores only a SHA-256 of each token (data/devices.json).
* Network clients use TLS with the hub's own self-signed certificate
  (data/tls/), which apps pin when they pair.
"""
import hashlib
import hmac
import ipaddress
import json
import pathlib
import secrets
import ssl
import subprocess
import time

DATA = pathlib.Path(__file__).resolve().parent.parent / "data"
DEVICES_FILE = DATA / "devices.json"
TLS_DIR = DATA / "tls"
PAIRING_WINDOW_S = 60


def is_loopback(host):
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return host in ("localhost",)


def _digest(token):
    return hashlib.sha256(token.encode()).hexdigest()


class Devices:
    """Paired devices and their tokens."""

    def __init__(self, path=None, clock=time.time):
        self.path = path or DEVICES_FILE
        self.clock = clock
        self.window_until = 0.0
        self.window_reason = None

    def _load(self):
        try:
            return json.loads(self.path.read_text())
        except (OSError, ValueError):
            return []

    def _save(self, devices):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(devices, indent=1))
        self.path.chmod(0o600)

    # pairing window

    def open_window(self, reason):
        self.window_until = self.clock() + PAIRING_WINDOW_S
        self.window_reason = reason
        return self.window_until

    def window_open(self):
        return self.clock() < self.window_until

    def close_window(self):
        self.window_until = 0.0

    # issuing and checking

    def pair(self, name, kind="app"):
        """A new device token, only while the window is open. Returns (device_id, token) or None."""
        if not self.window_open():
            return None
        token = secrets.token_urlsafe(32)
        device_id = secrets.token_hex(6)
        devices = self._load()
        devices.append({"id": device_id, "name": str(name)[:60] or "device", "kind": kind,
                        "token_sha256": _digest(token), "created": self.clock(), "last_seen": None})
        self._save(devices)
        self.close_window()                     # one device per press
        return device_id, token

    def check(self, token):
        """The device for a presented token, or None."""
        if not token:
            return None
        want = _digest(token)
        devices = self._load()
        for d in devices:
            if hmac.compare_digest(d.get("token_sha256", ""), want):
                now = self.clock()
                if not d.get("last_seen") or now - d["last_seen"] > 300:
                    d["last_seen"] = now
                    self._save(devices)
                return d
        return None

    def list(self):
        return [{k: d.get(k) for k in ("id", "name", "kind", "created", "last_seen")} for d in self._load()]

    def revoke(self, device_id):
        devices = self._load()
        kept = [d for d in devices if d.get("id") != device_id]
        self._save(kept)
        return len(kept) != len(devices)


def bearer(headers):
    """The token from an Authorization: Bearer header or X-Fennec-Token."""
    auth = headers.get("Authorization") or headers.get("authorization") or ""
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    return headers.get("X-Fennec-Token") or headers.get("x-fennec-token")


# TLS

def tls_paths():
    return TLS_DIR / "hub.crt", TLS_DIR / "hub.key"


def ensure_certificate():
    """A self-signed certificate for the hub, created once (EC P-256, ten years)."""
    crt, key = tls_paths()
    if crt.exists() and key.exists():
        return crt, key
    TLS_DIR.mkdir(parents=True, exist_ok=True)
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
                    "-pkeyopt", "ec_param_enc:named_curve",          # Apple's TLS rejects explicit curve parameters
                    "-nodes", "-keyout", str(key), "-out", str(crt), "-days", "3650", "-subj", "/CN=fennec-hub"],
                   check=True, capture_output=True)
    key.chmod(0o600)
    return crt, key


def certificate_fingerprint():
    """SHA-256 of the certificate in DER form, hex: what apps pin."""
    crt, _ = tls_paths()
    der = ssl.PEM_cert_to_DER_cert(crt.read_text())
    return hashlib.sha256(der).hexdigest()


def server_context():
    crt, key = ensure_certificate()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(str(crt), str(key))
    return ctx


# Unit keys: one secret per creature, given to it over the USB cable only.

UNIT_KEYS_FILE = DATA / "unit_keys.json"


class UnitKeys:
    def __init__(self, path=None):
        self.path = path or UNIT_KEYS_FILE

    def _load(self):
        try:
            return json.loads(self.path.read_text())
        except (OSError, ValueError):
            return {}

    def get(self, unit):
        hexkey = self._load().get(unit)
        return bytes.fromhex(hexkey) if hexkey else None

    def new(self, unit):
        keys = self._load()
        key = secrets.token_bytes(32)
        keys[unit] = key.hex()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(keys, indent=1))
        self.path.chmod(0o600)
        return key

    def rename(self, old, new):
        keys = self._load()
        if old in keys and new not in keys:
            keys[new] = keys.pop(old)
            self.path.write_text(json.dumps(keys, indent=1))


def sign_line(key, nonce, n, json_line):
    """The wire form of a signed command: "S <n> <hmac hex> <json>"."""
    mac = hmac.new(key, f"{nonce}|{n}|{json_line}".encode(), hashlib.sha256).hexdigest()
    return f"S {n} {mac} {json_line}"


def hello_auth_ok(key, nonce, unit, auth):
    want = hmac.new(key, f"hello|{nonce}|{unit}".encode(), hashlib.sha256).hexdigest()
    return bool(auth) and hmac.compare_digest(want, auth)
