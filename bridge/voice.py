#!/usr/bin/env python3
"""
The creature's voice: a unit called "mac-voice" that reads `speak` commands
out loud with the Mac's speech synthesis and reports `spoke` events.

    bridge/.venv/bin/python bridge/voice.py [-v Samantha] [-b 127.0.0.1]
"""
import argparse
import json
import socket
import subprocess
import threading
import time


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-v", dest="voice")
    ap.add_argument("-b", dest="bridge", default="127.0.0.1")
    ap.add_argument("-p", dest="port", type=int, default=8778)
    ap.add_argument("-n", dest="name", default="mac-voice")
    args = ap.parse_args()
    t0 = time.time()
    lock = threading.Lock()

    def say(sock, text, voice):
        cmd = ["say"] + (["-v", voice] if voice else []) + [text]
        with lock:
            try:
                subprocess.run(cmd, check=False, timeout=120)
            except (OSError, subprocess.TimeoutExpired):
                pass
            print(f"[{time.strftime('%H:%M:%S')}] said: {text}")
            try:
                sock.sendall((json.dumps({"type": "event", "t": int((time.time() - t0) * 1000), "name": "spoke", "text": text}) + "\n").encode())
            except OSError:
                pass

    while True:
        try:
            sock = socket.create_connection((args.bridge, args.port), timeout=3)
            sock.settimeout(None)
            sock.sendall((json.dumps({"type": "hello", "unit": args.name, "fw": "voice 0.1", "sensors": ["mac-speaker"]}) + "\n").encode())
            print(f"connected to bridge as '{args.name}'")
            buf = b""
            sock.settimeout(5)
            while True:
                try:
                    chunk = sock.recv(4096)
                except socket.timeout:          # keepalive: the bridge drops units silent for 10 s
                    sock.sendall((json.dumps({"type": "state", "t": int((time.time() - t0) * 1000)}) + "\n").encode())
                    continue
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    try:
                        msg = json.loads(line)
                    except ValueError:
                        continue
                    if msg.get("cmd") == "speak" and msg.get("text"):
                        threading.Thread(target=say, args=(sock, str(msg["text"])[:500], msg.get("voice") or args.voice), daemon=True).start()
                    elif msg.get("cmd") == "hello":
                        sock.sendall((json.dumps({"type": "hello", "unit": args.name, "fw": "voice 0.1", "sensors": ["mac-speaker"]}) + "\n").encode())
        except OSError as e:
            print(f"bridge not reachable ({e}); retrying")
        time.sleep(2)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
