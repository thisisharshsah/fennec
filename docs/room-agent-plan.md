# Fennec: project plan

Last updated: 2026-10-26. Supersedes the bedsense brief in `plan.md`; the
hardware, firmware pipeline and tools from bedsense are reused.

## What we are trying to make

Senses and a body for AI agents, at any scale from one desk to a building.

Today an agent only knows what you type. These units let it know that the
doorbell rang, that a room went quiet, that humidity jumped when a kettle
boiled, that someone walked past, where a sound came from, and let it send a
walker to look. The agent asks questions and gives orders through the same
tool interface it uses for everything else. No app is written for any single
feature; the agent composes behaviours from the units' senses and moves.

Two units, one design language, one firmware:

- **Cell**: a stationary pebble, about 8 cm, our board in a shell. Hears,
  senses the room, counts nearby phones, reports over radio.
- **Creature**: the same board inside a 15 cm upright character with
  ears, head, cheeks and tail that move. Everything a cell does, and it
  shows what it notices: ears perk at a sound and swivel toward it, the
  head turns to look at you, cheeks change colour with its state, the tail
  wags. Expression is the product; walking is not needed and never was.
  Later, hidden wheels under the feet let it turn to face you and scoot
  across a desk.

The character is original. The reference feeling is Pikachu (expressive
ears, glowing cheeks, a tail), the design is ours: no yellow mouse, no red
cheeks, no lightning tail.

Any number of cells and creatures in a building form one swarm over the
board's sub-GHz radio, with one unit acting as the Wi-Fi gateway. The agent
sees the whole building as one body.

Not a camera, not continuous listening. Sound becomes labelled events on
the board and is discarded; only short facts with timestamps leave a unit.
That is the privacy story and the reason it can live in a home or a ward.

## Who it is for, and how it scales

| customer | buys | what the agent gets |
| :- | :- | :- |
| home user running an agent | one creature | a room-aware assistant with a face on the desk |
| small shop or office | a creature at the counter and a few cells | footfall, door events, "is anyone in the back" |
| warehouse, lab, care home | tens of cells, a creature at each station | a building-wide sense of sound, presence and conditions, with a face where people are |
| agent platform vendors (later) | the reference design | hardware to point customers at |

Scales down by leaving out motors and legs (a cell is a third of the price).
Scales up because the mesh costs nothing extra: the radio is already on the
board, and sub-GHz goes through walls and across a building where Wi-Fi
does not.

## Hardware

Brain and senses, one per unit: the ST B-L475E-IOT01A already in hand
(STM32L475, Wi-Fi, BLE, sub-GHz, NFC, two PDM microphones, LSM6DSL IMU,
LIS3MDL magnetometer, HTS221 temperature and humidity, LPS22HB pressure,
VL53L0X time-of-flight, Arduino Uno headers). A production unit shrinks to a
custom board with the same parts.

| part | sense or action |
| :- | :- |
| microphones | sound level, sound events (clap, doorbell, voice present, machine stopped), left/right bearing from the two-mic delay |
| time-of-flight | something or someone in front (the nose); desk-edge stop when on wheels |
| BLE | count of nearby phones as a presence hint: on the ear chip (the STM32's BLE shares a bus with Wi-Fi and stalls) |
| temperature, humidity, pressure | room conditions, door or window opened |
| IMU | picked up, knocked, tilted; petted (gentle tap pattern) |
| magnetometer | compass heading, so a sound bearing becomes a room bearing |
| sub-GHz | swarm mesh between units, through walls |
| Wi-Fi | gateway unit to the bridge |
| NFC | tap a phone to a unit to name it or pair it |
| Arduino headers | servo driver (creature only) |

Creature body:

- about 15 cm tall, big round head on a small body, stubby feet; the board
  stands upright inside the body with the time-of-flight lens as the nose
  at the front of the head
- six micro servos on a PCA9685 driver from the Arduino headers: two ears
  (each pivots forward and back, together they perk, droop and swivel), head
  turn, head tilt, tail, one spare for a later arm or lid
- cheeks: two soft LED spots behind translucent patches; colour is the
  creature's state
- microphones in the ears (6 cm apart gives the left/right bearing),
  humidity and temperature vented at the back of the head
- 3D-printed shells; a print shop if no printer
- later: two small N20 wheels under the feet and a dual motor driver so it
  can turn to face a sound and scoot across the desk; the time-of-flight
  nose stops it at a desk edge

To buy for the creature (about 25 USD): six MG90S micro servos, one PCA9685,
a USB-C power bank or 2S cell with 5 V regulator, two diffused LEDs, wires,
M2 screws. A cell needs nothing but a shell.

Ear chip (about 15 USD): a Seeed XIAO ESP32S3 Sense (ESP32-S3 with a PDM
microphone and 8 MB PSRAM) or any ESP32-S3 board with an I2S/PDM mic; plus
a small I2S amplifier (MAX98357A) and a 28 mm speaker for the voice. It
talks to the STM32 over the header UART and to the hub over its own Wi-Fi.

## Software

- **Firmware** (PlatformIO, Arduino framework, this repo): reads every
  sensor, classifies sound on the board, prints one line per second of state
  plus event lines; accepts short commands; later drives the servos and wheels and speaks on the mesh.
- **Bridge** on the Mac (Python): reads the serial port now, the Wi-Fi
  gateway later; keeps the latest state and an event log per unit; exposes
  tools to the agent through the standard tool protocol (MCP): `room_state`,
  `recent_events`, `wait_for_event`, later `express`, `look_at`,
  `units`, `locate_sound`, and on wheels `turn`, `go_look`.
- **Agent**: no new code. Claude Code or any MCP client connects to the
  bridge and the swarm appears as tools.

## Phases

### Phase 1: one unit on the desk (done 2026-10-26, except the clap test)

- firmware v0.2 streams temperature, humidity, pressure, time-of-flight
  distance, heading, motion flag, sound level and left/right bearing once a
  second; events `boot`, `moved`, `knock`, `someone_in_front`,
  `someone_left`, `sound_started`, `sound_stopped`, `clap`
- microphones run through DFSDM + DMA against ST's HAL (`src/sound.cpp`);
  verified with speech from the Mac speaker: quiet room ~30 dB, speech ~45,
  bearing swings toward the laptop, sound_started/stopped fire
- bridge daemon + MCP server + `.mcp.json`; tools `units_list`,
  `room_state`, `recent_events`, `wait_for_event`, `send_command`
- native macOS/iOS app with live tiles, event feed, charts, Bonjour
- still to verify by hand: a real clap (the laptop speaker is too quiet to
  trigger the detector), a knock on the desk, walking in front of the board

### Phase 2: untethered (built 2026-10-27)

- firmware v0.3: Wi-Fi link over the on-board ISM43362 (`src/link.cpp`),
  TCP line stream to the bridge at an address set by the setup tool (the
  module cannot listen for a beacon without blocking), settings in emulated EEPROM, `wifi`/`bridge`/`name`/`status` commands
- bridge v0.2: TCP unit server on 8778, one active link per unit name, `link` field on every message
- `bridge/setup_unit.py` to enter network details over the cable
- verified 2026-10-27: joined the home network (rssi about -38), TCP link to
  the bridge up, 1 Hz stream over Wi-Fi, reconnects by itself after a bridge
  restart; commands go over the cable when it is in, otherwise over Wi-Fi
  (the unit polls the module every 2 s; a command lands in 1 to 3 s)
- onboarding without a cable (built and tested from the Mac 2026-10-27:
  discovery, network list, identify, wrong-password rejection, clean restart
  on exit; the phone found and identified the board on 2026-10-27 but saw an
  empty network list after a boot whose first join had failed; fixed by
  skipping the join when the button is held and reinitialising the module on
  an empty scan. Confirmed end to end from the iPhone at 17:07 on 2026-10-27:
  network chosen, password sent, joined, restarted, back on Wi-Fi at -38 dBm): the unit enters setup mode when it has no network, when the blue
  button is held at boot, or on `{"cmd":"provision"}`: Wi-Fi off, cheeks
  violet, Bluetooth advertising as `creature-XXXX` with the open Improv Wi-Fi
  protocol plus a network list and the bridge address (`src/provision.cpp`,
  docs/protocol.md). The app's Settings has "Set up a creature" for iPhone
  and Mac: pick the creature, identify it (it wags), pick a network by
  signal, enter the password, done. The ear chip's firmware supports the same
  protocol with one line, so one screen onboards both chips. The app's
  cable-based Unit Wi-Fi section stays as the fallback.
- password friction (2026-10-27): iOS does not let an app read the phone's
  Wi-Fi password. The app preselects the phone's current network (Access
  Wi-Fi Information entitlement + location permission) and remembers
  passwords in its keychain after the first success. The end state is the
  ear chip as a Matter accessory: iOS then hands over the home Wi-Fi
  credentials itself during commissioning (scan a code, confirm), and the
  creature shows up in the Home app. Espressif supports Matter on the
  ESP32-S3; the STM32 cannot run it.
- hearing words is a device feature, not a Mac feature. Decision 2026-10-27:
  the Mac is a test rig only. A Mac Whisper listener was built and removed;
  a hand-rolled on-board sound model (`ml/`) was built to the point of
  recording clips and compiling, then parked: proven engines beat it.
  Product path: an ear chip in the body, an ESP32-S3 running microWakeWord
  (open source, wake words trained from synthetic speech, no recordings
  needed) that wakes on "creature" and then streams audio to the hub for
  speech to text. The hub is the Mac during tests; later the phone app or a
  small home server. The STM32 keeps level, direction, clap, presence,
  motion and the body. Sound events (doorbell, glass, alarm) come from an
  Edge Impulse model on the ear chip when wanted.
- the agent still speaks through `bridge/voice.py` (`speak` tool) on the
  test rig; on the product the ear chip's I2S amplifier and speaker do it.
- prepared 2026-10-27 ahead of the chip: `ear/creature-ear.yaml` (ESPHome,
  micro_wake_word, posts to the bridge), bridge HTTP ingest on 8776, and the
  rule that a heard wake word makes the body alert and perks the ears.
- known limit: commands reach a unit over serial only (the module driver's
  read blocks for seconds); phase 3 needs a low-rate polled read with a
  short timeout for `express`/`look_at` over Wi-Fi

### Phase 3: the creature (software done 2026-10-27, hardware waiting on parts)

- `src/body.cpp`: expression engine with seven moods, five gestures, look
  targets, reflexes (ears and head to sound, head to a person, surprised on
  clap, alert on knock, pleased and wag on a pat, sleepy after a quiet
  minute); runs without servos and drives a PCA9685 on the header I2C bus
  when one answers at 0x40 (channels 0 ear_l, 1 ear_r, 2 pan, 3 tilt, 4 tail)
- `body` object in every state line and a `body` message on every change
- agent tools `express`, `gesture`, `look_at`, `body_state`
- app: Creature tab with an animated face and mood, gesture and look controls
- verified: moods and gestures from the bridge, ears and head follow speech
- calibration ready ahead of the parts: `servo`, `trim`, `calib` commands,
  trims and directions in flash, cheek LEDs on PCA9685 channels 5 to 7,
  `bridge/calibrate.py` walks through each joint
- to do when parts arrive: print the first head and body, run the
  calibration, check the ear and tail geometry against the drawing

### Phase 3b: wheels (optional)

- two N20 wheels under the feet, dual driver; `turn`, `go_look`
- time-of-flight desk-edge stop that cannot be overridden

### Phase 4: the swarm (needs a second board)

- sub-GHz link between two units; one is the Wi-Fi gateway
- bridge tracks units by name; `units`, `locate_sound` from two or more
  bearings
- done when: a clap in another room is reported by the unit that heard it,
  with a bearing, and the creature turns its head that way

### Phase 5: product body

- shells, light ring, NFC pairing, wider sound event set with on-device
  classification
- a week in one real space; what did the agent do that nobody programmed

## Upgrades done 2026-10-27 (system hardening)

- firmware 0.5: hardware watchdog, health block (uptime, boot count,
  watchdog resets, reset cause, free RAM, Wi-Fi reconnects), idle life
  (breathing tilt, ear twitches, cheek pulse)
- bridge 0.3: HTTP ingest for simple devices, quiet-unit timeout, 14-day log
  retention, wake word nudges the body
- agent: `room_summary` tool (visits, counts, ranges, health from the log)
- tried and parked: BLE phone counting on the STM32's SPBTLE-RF. It worked
  for about 50 s next to the Wi-Fi module and then stalled (shared SPI3, no
  bus arbitration between the two libraries). It moves to the ear chip, which
  has its own radio: `esp32_ble_tracker` in `ear/creature-ear.yaml` posts
  `ble_nearby` every 5 s.

## Added 2026-10-27, late (firmware 0.6)

- air gestures from the distance sensor (swipe, tap), with reflexes
- chirps on a header speaker (D5), eight patterns, reflex chirps, `chirp` tool
- offline journal in internal flash with sequence numbers and gap-free
  acknowledgements from the bridge; verified: events during a 30 s bridge
  outage were delivered afterwards and the journal drained to zero
- Bluetooth setup mode and the app's setup screen (see phase 2); leaving
  setup mode restarts the board, because Wi-Fi after Bluetooth on the shared
  bus hung once and tripped the watchdog

- clap detector (2026-10-27 afternoon): the night logged 33 false claps in
  10 quiet hours. Added a spectral gate (broadband vs low-frequency, from the
  live log-mel frames); rejections are reported as `clap_rejected` with the
  tilt value so the threshold (-2.0 for now) can be set from real claps.

- handling (2026-10-27 afternoon): picked_up / set_down / shaken / flipped /
  upright from the IMU with reflexes; bridge test suite (7 tests) covering
  the link and acknowledgement logic that failed by hand earlier.

## Open questions

- Two microphones 6 cm apart indoors with echoes: left/right/centre may be
  all we get, which is still enough to turn toward a sound and to combine
  bearings across units.
- Whether the STM32 stays at all once an ESP32-S3 is in the body (it could
  take over sensors and servos too), or whether the two-chip split is kept
  for the sub-GHz radio and the proven sensor code.
- Whether six servos make it feel alive or whether the ears alone do most
  of the work (cheaper if so).
- Sub-GHz range and packet rate inside a real building with the on-board
  SPSGRF module.
- Battery life for a cell on a small cell; whether cells should be
  mains-powered USB pucks instead.
