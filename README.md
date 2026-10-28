# Fennec

A tiny listening creature for your desk, named after the fennec fox: big ears, small body, hears everything.

Senses and, later, a body for an AI agent. A small unit on the desk reports
what it hears and senses in the room as short facts (sound level and
direction, someone in front, temperature, humidity, pressure, heading,
movement, events like clap and knock), and an agent asks it questions
through ordinary tools. Raw audio never leaves the board.

Plan: `docs/room-agent-plan.md`. Product look: `docs/room-agent-image-prompts.md`.
Wire protocol between firmware, bridge, apps and agent: `docs/protocol.md`.
The earlier bedsense brief is kept in `docs/plan.md` and `legacy/`.

## Hardware

ST B-L475E-IOT01A (STM32L475VG). The ST-LINK mounts as `DIS_L4S5VI`, which
looks like the newer L4S5 board, but the chip ID is an L47x with 1 MB flash
and 128 KB RAM; the L4S5 PlatformIO target hard-faults before the first
print. `platformio.ini` targets the L475.

Sensors used: two MP34DT01 microphones (DFSDM), VL53L0X time-of-flight,
HTS221 temperature and humidity, LPS22HB pressure, LSM6DSL IMU, LIS3MDL
magnetometer. All on the internal I2C2 bus except the microphones.

## Layout

```
platformio.ini        PlatformIO project (Arduino framework, ST-LINK upload)
src/main.cpp          firmware v0.3: sensors -> one JSON state line per second + events, serial and Wi-Fi
src/link.cpp          Wi-Fi link (ISM43362 over SPI3), settings in flash
src/body.cpp          expression engine: ears, head, tail, cheeks; PCA9685 servos when present
src/provision.cpp     Bluetooth setup mode (Improv Wi-Fi + network list)
src/chirp.cpp         tone patterns on a header speaker
src/journal.cpp       offline event journal in internal flash
src/sound.cpp         microphones via DFSDM + DMA: level, left/right bearing, clap, sound start/stop
bridge/bridge.py      daemon: serial port + TCP units (8778), apps over WebSocket (8777)
bridge/setup_unit.py  give a unit its Wi-Fi details, a fixed bridge address or a name (the app can too)
bridge/voice.py       the creature's voice: reads `speak` commands with the Mac's speech synthesis
ear/                  ESPHome config for the wake-word ear chip (ESP32-S3), posts `heard` to the bridge
ml/                   parked experiment: on-board sound classifier (recorder, trainer, features)
bridge/calibrate.py   centre and orient the servos joint by joint (phase 3)
bridge/launchd/       install.sh: start the bridge and voice at login
bridge/tests/         pytest suite for link selection, acknowledgements, replay, HTTP ingest (`bridge/.venv/bin/python -m pytest bridge/tests`)
bridge/mcp_server.py  MCP server (stdio) for Claude Code; client of the bridge, starts it if needed
.mcp.json             registers the MCP server with Claude Code for this folder
apps/RoomCreature     native SwiftUI app for macOS and iOS: live tiles, charts, event feed
docs/                 plan, protocol, image prompts
data/                 bridge logs (log_<date>.jsonl) and old bedsense sessions
tools/                bedsense-era serial logger and plotter (still work for the IMU)
legacy/               bedsense v0.1 firmware
```

## Phase 1: one unit on the desk

Build and flash (board on the micro-USB port labelled ST-LINK):

```bash
~/.platformio/penv/bin/pio run -t upload
```

Watch the raw stream:

```bash
~/.platformio/penv/bin/pio device monitor
```

Run the bridge (first time: create its environment):

```bash
~/.local/bin/uv venv -p 3.12 bridge/.venv
~/.local/bin/uv pip install -p bridge/.venv/bin/python pyserial websockets zeroconf "mcp>=2"
bridge/.venv/bin/python bridge/bridge.py
```

It prints the WebSocket address for the apps, advertises itself on the
local network as `_roomcreature._tcp`, and appends every message to
`data/log_<date>.jsonl`.

Give the agent the senses: open this folder in Claude Code. `.mcp.json`
registers the `room-creature` server; approve it when asked. The tools:

| tool | what it does |
| :- | :- |
| `units_list`, `room_state`, `body_state` | what is connected, the latest readings, the body pose |
| `recent_events`, `wait_for_event` | what happened, or block until something happens (clap, heard, ...) |
| `room_summary` | the last N hours from the log: visits, event counts, temperature range, health |
| `express`, `gesture`, `look_at` | drive the creature's mood, a gesture, or its head |
| `speak` | answer out loud through the Mac's speaker (`bridge/voice.py`) |
| `send_command` | any raw command from docs/protocol.md |

The MCP server starts the bridge itself if none is running.

Try it: clap, walk in front of the board, talk, breathe on it, then ask the
agent what just happened in the room.

## Phase 2: untethered

No cable needed (firmware 0.6+): a creature with no network, or booted with
the blue button held for three seconds, goes into setup mode with violet
cheeks and shows up in the app under Settings > Set up a creature, on the
iPhone or the Mac. Pick it, pick your network from the list, enter the
password. Setup mode also starts on `{"cmd":"provision"}`.

With the board on the cable instead, either use the Unit Wi-Fi section in
the app's Settings tab, or:

```bash
bridge/.venv/bin/python bridge/setup_unit.py -s "YourNetwork"      # prompts for the password
```

The unit stores the details and this Mac's address in flash, joins, and
connects to the bridge over TCP; the reply shows `joined` and `bridge`. The
first join after a reset often fails and succeeds on the retry 20 s later.
From then on, power the board from any USB power bank through the ST-LINK
port and it reports over Wi-Fi: the bridge log says `wifi link is unit
'desk'` and the app shows the same stream. Plug the cable back in at any
time; the serial link takes over again on the next hello.

If the Mac's address changes, set it again:

```bash
bridge/.venv/bin/python bridge/setup_unit.py -H 192.168.1.92
```

Commands also travel over Wi-Fi: the unit asks the module for inbound
bytes every 2 s, so a mood or look command sent while untethered lands
within about two seconds. Over the cable it is instant. Giving the unit new
Wi-Fi details needs the cable, since the old network goes away.

## Daily life

The hub gives each creature a few habits of its own, in `bridge/life.py`:
it greets you when you come back after 20 minutes away, says good morning
(with how the night went) and goodnight (with how long you were at the desk), suggests a break after 50 minutes in front of it, and
notices when the room warms up fast. Each shows as a note in the
creature's Activity and moves its body; none repeats often. Turn it off in
the app under Settings › Daily life.

## Hearing words

Not on the Mac and not on this board. The product gets an ear chip (an
ESP32-S3 running a proven wake-word engine) that wakes on "creature" and
later streams speech to the hub; the configuration is ready in `ear/` and
the bridge already takes its events on port 8776. Until that chip is in the
body, the creature hears levels, direction and claps only.

`ml/` holds a parked experiment: a small sound classifier for this board,
with a recorder (`ml/record.py`, uses the firmware's `record` command), a
trainer and the on-board feature extractor. It compiles into the firmware
but no model is flashed.

The creature's voice on the test rig is `bridge/voice.py`: a unit named
`mac-voice` that reads the agent's `speak` tool out loud through the Mac.

## Keep it running

The bridge and the voice can start at login and restart if they exit:

```bash
bridge/launchd/install.sh            # installs two LaunchAgents and starts them
bridge/launchd/install.sh remove     # stops and removes them
```

Note: launchd cannot start them while the project lives in `~/Documents`
(macOS keeps background processes out of that folder). Move the project
elsewhere first, or keep starting them by hand.

## Phase 3: the body

Wiring on the PCA9685 (header I2C1, address 0x40, servo power from its own
5 V rail, never from the board):

| channel | part |
| :- | :- |
| 0 | left ear servo |
| 1 | right ear servo |
| 2 | head pan servo |
| 3 | head tilt servo |
| 4 | tail servo |
| 5, 6, 7 | cheek LEDs red, green, blue (through resistors; `cheek_invert` for common-anode) |

The firmware finds the driver at boot and drives it; without one, the body
runs virtually and the app still shows it. Centre each joint and fix its
direction once:

```bash
bridge/.venv/bin/python bridge/calibrate.py
```

It holds each servo at its centre pulse while you fit the horn straight,
lets you nudge the centre and flip the direction, tests the joint through
the expression engine, and stores the result in the unit's flash.

## The app (macOS and iOS)

`apps/RoomCreature/RoomCreature.xcodeproj`, SwiftUI, one target for both
platforms, no dependencies. Live tiles per unit, an event feed, ten-minute
charts with event markers, and a settings tab with Bonjour discovery or a
typed host and port.

```bash
cd apps/RoomCreature
xcodebuild -project RoomCreature.xcodeproj -scheme RoomCreature -destination 'platform=macOS' -derivedDataPath build build
open build/Build/Products/Debug/RoomCreature.app
xcodebuild -project RoomCreature.xcodeproj -scheme RoomCreature -destination 'platform=iOS Simulator,name=iPhone 17' build
```

`apps/fakebridge.py` serves synthetic data for working on the app without
the board (`-p 8780 -B`, then set the host in Settings).

### On your iPhone

A free Apple ID is enough; the install lasts seven days and is renewed by
running again from Xcode.

1. Xcode > Settings > Accounts > + > sign in with your Apple ID.
2. Open `apps/RoomCreature/RoomCreature.xcodeproj`, select the RoomCreature
   target > Signing & Capabilities, tick Automatically manage signing and
   pick your name as Team. Xcode creates the certificate and profile.
3. On the phone: Settings > Privacy & Security > Developer Mode > on, then
   restart it. Plug it into the Mac with a cable and tap Trust.
4. Pick the phone in Xcode's device menu and press Run. The first time,
   the phone asks you to trust the developer under Settings > General >
   VPN & Device Management.
5. With the phone on the same Wi-Fi as the Mac, the app finds the bridge
   over Bonjour by itself (allow Local Network when iOS asks). If not, type
   the Mac's address and port 8777 under Settings in the app.

After the first cabled run, Xcode can install over Wi-Fi.

The iOS Simulator app is not installed with this Xcode; `xcodebuild` for the
simulator still works for compile checks.

## Small speaker (optional)

A piezo disc between header pin D5 and GND through a 100 ohm resistor, or a
small speaker through an NPN transistor, gives the creature chirps of its
own: `{"cmd":"chirp","name":"hello"}` or the agent's `chirp` tool. It chirps
by itself on a tap, a swipe, a knock, a pat, and when its link comes up.

## Handling

Pick it up and it goes alert; set it down and it is pleased and wags. Shake
it and it is surprised and says no. Put it face down for two seconds and it
goes to sleep until it is upright again. Events: `picked_up`, `set_down`,
`shaken`, `flipped`, `upright`.

## Air gestures

With nothing standing in front of it, a hand crossing its face for under
half a second is a `swipe` (it changes mood and chirps) and a quick approach
to within 25 cm is a `tap` (it nods). Someone standing there for almost a
second is presence, as before.

## Offline memory

Every event is written to the board's flash before it is sent, the bridge
acknowledges what it received, and anything unacknowledged is replayed when
the link is back, time-shifted by how old it is, so the log has no holes.
`health.journal` in the state line shows how many wait. Test it with
`tools/ble_setup_test.py`'s sibling: stop the bridge, make noise, restart it.

## Sound figures (uncalibrated)

| situation | sound_db |
| :- | :- |
| quiet room | about 30 |
| speech from a laptop a metre away | 45 to 48 |
| clap | 70 and up |

`sound_dir` is -1 (left) to +1 (right) as seen from the board with the
USB connectors at the back, and only moves while something is audible.
