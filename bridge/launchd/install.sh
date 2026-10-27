#!/bin/sh
# Install (or remove) login services for the bridge and the voice,
# so the Mac starts them itself and restarts them if they exit.
#
#   bridge/launchd/install.sh            install and start
#   bridge/launchd/install.sh remove     stop and remove
#
# Logs: data/bridge.log and data/voice.log.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PY="$ROOT/bridge/.venv/bin/python"
AGENTS="$HOME/Library/LaunchAgents"
mkdir -p "$AGENTS" "$ROOT/data"

write_plist() {   # label script logfile [extra args...]
  label="$1"; script="$2"; logfile="$3"; shift 3
  args=""
  for a in "$@"; do args="$args<string>$a</string>"; done
  cat > "$AGENTS/$label.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$PY</string><string>$ROOT/bridge/$script</string>$args</array>
  <key>WorkingDirectory</key><string>$ROOT</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>$ROOT/data/$logfile</string>
  <key>StandardErrorPath</key><string>$ROOT/data/$logfile</string>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
</dict></plist>
PLIST
}

UID_="$(id -u)"
for label in com.harshsah.roomcreature.bridge com.harshsah.roomcreature.voice; do
  launchctl bootout "gui/$UID_/$label" 2>/dev/null || true
done

if [ "$1" = "remove" ]; then
  rm -f "$AGENTS/com.harshsah.roomcreature.bridge.plist" "$AGENTS/com.harshsah.roomcreature.voice.plist"
  echo "removed"
  exit 0
fi

write_plist com.harshsah.roomcreature.bridge bridge.py bridge.log
write_plist com.harshsah.roomcreature.voice voice.py voice.log
pkill -f "$ROOT/bridge/bridge.py" 2>/dev/null || true
pkill -f "$ROOT/bridge/voice.py" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$UID_" "$AGENTS/com.harshsah.roomcreature.bridge.plist"
launchctl bootstrap "gui/$UID_" "$AGENTS/com.harshsah.roomcreature.voice.plist"
echo "installed: bridge and voice start at login and restart if they exit"
echo "status:    launchctl print gui/$UID_/com.harshsah.roomcreature.bridge | head -5"
