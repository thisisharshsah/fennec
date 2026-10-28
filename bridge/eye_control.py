"""
When the eye (tools/eye, the camera test rig on the Mac) runs. Three modes, kept in data/eye.json:

  off   the camera is released (its light goes out)
  auto  the eye runs while the creature's own distance sensor feels someone at the desk,
        and stops AWAY_GRACE_S after they leave
  on    the eye runs all the time

The hub starts and stops the eye program itself, so "off" means the camera is not in use,
not merely that pictures are hidden.
"""
import asyncio
import json
import pathlib
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
EYE_FILE = ROOT / "data" / "eye.json"
EYE_BIN = ROOT / "tools" / "eye" / "eye"
EYE_LOG = ROOT / "data" / "eye.log"
MODES = ("off", "auto", "on")
AWAY_GRACE_S = 120


class EyeControl:
    def __init__(self, log, path=None, clock=time.time, launcher=None):
        self.log = log
        self.path = path or EYE_FILE
        self.clock = clock
        saved = self._load()
        self.mode = saved.get("mode") if saved.get("mode") in MODES else "off"
        self.camera = saved.get("camera") or "Brio"
        self.here = False                 # the creature's own sensor feels someone in front
        self.left_at = None
        self.proc = None
        self.launcher = launcher or self._launch
        self._warned = False

    def _load(self):
        try:
            return json.loads(self.path.read_text())
        except (OSError, ValueError):
            return {}

    def _save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps({"mode": self.mode, "camera": self.camera}))

    @property
    def running(self):
        return self.proc is not None and self.proc.returncode is None

    def wanted(self):
        if self.mode == "on":
            return True
        if self.mode == "auto":
            return self.here or (self.left_at is not None and self.clock() - self.left_at < AWAY_GRACE_S)
        return False

    def status(self):
        return {"type": "eye", "mode": self.mode, "running": self.running, "camera": self.camera, "here": self.here}

    async def set_mode(self, mode):
        if mode not in MODES:
            return False
        self.mode = mode
        self._save()
        await self.apply()
        return True

    def observe(self, msg, body_unit):
        """Presence from the creature's own sensor. The eye's sightings ("via": "eye") do not count,
        or Auto would keep the camera on by itself. Returns True when presence changed."""
        if msg.get("type") != "event" or msg.get("via") or not body_unit or msg.get("unit") != body_unit:
            return False
        if msg.get("name") == "someone_in_front" and not self.here:
            self.here, self.left_at = True, None
            return True
        if msg.get("name") == "someone_left" and self.here:
            self.here, self.left_at = False, self.clock()
            return True
        return False

    async def apply(self):
        """Start or stop the eye to match the mode. Returns True when that changed something."""
        want = self.wanted()
        if want and not self.running:
            self.proc = await self.launcher(self.camera)
            if self.proc is not None:
                self.log.info("eye started (%s, mode %s)", self.camera, self.mode)
                return True
            return False
        if not want and self.running:
            await self.stop()
            self.log.info("eye stopped (mode %s)", self.mode)
            return True
        return False

    async def stop(self):
        if not self.running:
            return
        self.proc.terminate()
        try:
            await asyncio.wait_for(self.proc.wait(), 5)
        except asyncio.TimeoutError:
            self.proc.kill()

    def release_leftovers(self):
        """An eye left running by an earlier hub (killed before it could stop it) still holds the camera."""
        import subprocess
        subprocess.run(["pkill", "-f", str(EYE_BIN)], capture_output=True)

    async def _launch(self, camera):
        if not EYE_BIN.exists():
            if not self._warned:
                self.log.warning("eye not built: swiftc -O tools/eye/main.swift -o tools/eye/eye")
                self._warned = True
            return None
        out = open(EYE_LOG, "a")
        try:
            return await asyncio.create_subprocess_exec(str(EYE_BIN), camera, stdout=out,
                                                        stderr=asyncio.subprocess.STDOUT, cwd=str(ROOT))
        finally:
            out.close()                   # the child keeps its own copy of the file
