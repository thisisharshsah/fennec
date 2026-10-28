"""
When the eye (tools/eye, the camera test rig on the Mac) runs. Three modes, kept in data/eye.json:

  off   the camera is released (its light goes out)
  auto  the eye runs while the creature's own distance sensor feels someone at the desk,
        and stops AWAY_GRACE_S after they leave
  on    the eye runs all the time

The hub starts and stops the eye program itself, so "off" means the camera is not in use,
not merely that pictures are hidden. With the eye runs the describer (tools/describe), a local
vision-language model that puts the scene into one sentence every 20 s; "describe" turns it off.
"""
import asyncio
import json
import pathlib
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
EYE_FILE = ROOT / "data" / "eye.json"
EYE_BIN = ROOT / "tools" / "eye" / "eye"
EYE_LOG = ROOT / "data" / "eye.log"
DESCRIBE_PY = ROOT / "tools" / "describe" / ".venv" / "bin" / "python"
DESCRIBE_SCRIPT = ROOT / "tools" / "describe" / "describe.py"
DESCRIBE_LOG = ROOT / "data" / "describe.log"
MODES = ("off", "auto", "on")
AWAY_GRACE_S = 120


class EyeControl:
    def __init__(self, log, path=None, clock=time.time, launcher=None, describer_launcher=None, can_describe=None):
        self.log = log
        self.path = path or EYE_FILE
        self.clock = clock
        saved = self._load()
        self.mode = saved.get("mode") if saved.get("mode") in MODES else "off"
        self.camera = saved.get("camera") or "Brio"
        self.describe = saved.get("describe", True)
        self.describer = None
        self.here = False                 # the creature's own sensor feels someone in front
        self.left_at = None
        self.proc = None
        self.launcher = launcher or self._launch
        self.describer_launcher = describer_launcher or self._launch_describer
        if can_describe is not None:
            self.can_describe = lambda: can_describe
        self._warned = False

    def _load(self):
        try:
            return json.loads(self.path.read_text())
        except (OSError, ValueError):
            return {}

    def _save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps({"mode": self.mode, "camera": self.camera, "describe": self.describe}))

    @property
    def running(self):
        return self.proc is not None and self.proc.returncode is None

    def wanted(self):
        if self.mode == "on":
            return True
        if self.mode == "auto":
            return self.here or (self.left_at is not None and self.clock() - self.left_at < AWAY_GRACE_S)
        return False

    @property
    def describing(self):
        return self.describer is not None and self.describer.returncode is None

    @staticmethod
    def can_describe():
        return DESCRIBE_PY.exists() and DESCRIBE_SCRIPT.exists()

    def status(self):
        return {"type": "eye", "mode": self.mode, "running": self.running, "camera": self.camera, "here": self.here,
                "describe": self.describe, "describing": self.describing, "can_describe": self.can_describe()}

    async def set_describe(self, on):
        self.describe = on
        self._save()
        await self.apply()

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
        """Start or stop the eye (and the describer with it) to match the mode. True when that changed something."""
        changed = await self._apply_eye()
        want_words = self.running and self.describe and self.can_describe()
        if want_words and not self.describing:
            self.describer = await self.describer_launcher()
            changed = changed or self.describer is not None
        elif not want_words and self.describing:
            await self._stop(self.describer)
            changed = True
        return changed

    async def _apply_eye(self):
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
        if self.describing:
            await self._stop(self.describer)
        if self.running:
            await self._stop(self.proc)

    @staticmethod
    async def _stop(proc):
        proc.terminate()
        try:
            await asyncio.wait_for(proc.wait(), 5)
        except asyncio.TimeoutError:
            proc.kill()

    async def _launch_describer(self):
        out = open(DESCRIBE_LOG, "a")
        try:
            proc = await asyncio.create_subprocess_exec(str(DESCRIBE_PY), str(DESCRIBE_SCRIPT), stdout=out,
                                                        stderr=asyncio.subprocess.STDOUT, cwd=str(ROOT))
        finally:
            out.close()
        self.log.info("describer started")
        return proc

    def release_leftovers(self):
        """An eye left running by an earlier hub (killed before it could stop it) still holds the camera."""
        import subprocess
        subprocess.run(["pkill", "-f", str(EYE_BIN)], capture_output=True)
        subprocess.run(["pkill", "-f", str(DESCRIBE_SCRIPT)], capture_output=True)

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
