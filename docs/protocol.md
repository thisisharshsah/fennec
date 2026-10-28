# Wire protocol

Three links, one message vocabulary. Every message is one JSON object on one
line (newline-delimited JSON). Numbers are plain numbers, times are
milliseconds since the unit booted (`t`) and the bridge adds wall-clock
`ts` (Unix seconds, float) when it forwards a message.

```
unit (firmware) -[serial, or TCP over Wi-Fi]-> bridge (Mac, Python) -[WebSocket]-> apps (Mac, iOS)
                                                     '-[stdio MCP]-> agent (Claude Code)
```

Ports on the bridge: 8777 WebSocket for apps, 8778 TCP for units, 8776 HTTP
for simple devices (`POST /hello`, `/event`, `/state` with a JSON body that
includes `"unit"`; they appear as units with link `http`; the ear chip uses
this). A unit
is given the bridge's address by `setup_unit.py` (the bridge's WebSocket
hello carries `lan_ip` and `unit_port`); the Wi-Fi module's driver cannot
listen for a discovery beacon without blocking.

## Security (hub 0.5+)

* Apps on this Mac use plain `ws://127.0.0.1:8777` and are trusted. Apps on the
  network use `wss://<hub>:8779` with the hub's self-signed certificate
  (`data/tls/`, EC P-256 named curve) and `Authorization: Bearer <token>`.
  Bonjour advertises 8779 with TXT `tls=1`.
* Without a valid token the hub sends only `auth_required` and accepts only
  `{"cmd":"pair","name":..}`, which succeeds while a 60 s pairing window is open:
  opened by a short press of the creature's blue button (event `button`) or by
  a trusted client's `{"cmd":"pair_open"}`. One device per window. The answer
  `paired` carries the token and the certificate fingerprint, which the app
  pins. Trusted clients manage devices with `{"cmd":"devices"}` and
  `{"cmd":"devices","revoke":id}`. The hub stores only token digests.
* The HTTP ingest (8776) needs a device token unless the caller is on this Mac.
* Each creature gets a 32 byte key over the USB cable only
  (`{"cmd":"set_key","key":"<hex>"}`, refused over Wi-Fi). Its Wi-Fi hello
  carries `keyed`, a per connection `nonce` and `auth` =
  HMAC-SHA256(key, "hello|" + nonce + "|" + unit); the hub drops any Wi-Fi hello
  for a known creature that fails this. Every command the hub sends over Wi-Fi is
  `S <n> <hmac> <json>` with HMAC-SHA256(key, nonce + "|" + n + "|" + json) and n
  rising within the connection; the creature drops unsigned, forged and replayed
  lines with an `error` event.

## Unit to bridge (serial 115200 baud, or a TCP line stream to port 8778)

A unit sends the same lines over both links when both are up; the bridge
keeps one active link per unit name (the most recent hello wins) and
drops the other's copies. Commands go the other way on either link: the
bridge prefers serial (instant) and otherwise writes the line to the TCP
link, which the unit polls every 2 s (the module's read blocks, so the unit
spends about 0.3 s of every 2 s asking for inbound bytes). A `via` field of
`serial` or `wifi` on a command from an app forces the link.

Lines that do not start with `{` are human status text and are logged only.

State, once per second:

```json
{"type":"state","t":12345,"temp_c":23.4,"hum_pct":41.2,"press_hpa":1008.7,
 "tof_mm":812,"heading_deg":131.0,"motion":0,"sound_db":38.5,"sound_dir":0.0,"rssi":-61}
```

- `tof_mm`: time-of-flight distance, `-1` when nothing within range
- `heading_deg`: compass heading, 0 to 360, `-1` if unavailable
- `motion`: 0 still, 1 moving (IMU)
- `sound_db`: A-weighted-ish level in dB relative to the mic floor; absent
  while the microphone path is not implemented
- `sound_dir`: -1 left to +1 right, 0 centre or unknown; absent likewise
- `rssi`: Wi-Fi signal in dBm, present only while joined
- `health` (firmware 0.5+): `{"uptime_s","boots","wd_resets","reset","free_ram","wifi_reconnects"}`;
  `reset` is `power`, `pin`, `software` or `watchdog` (a 32 s hardware watchdog reboots a hung unit)
- `boot` events carry `reset` and `boots`

Event, when it happens:

```json
{"type":"event","t":12345,"name":"clap"}
{"type":"event","t":12345,"name":"someone_in_front","mm":640}
{"type":"event","t":12345,"name":"moved"}
```

Event names: `clap` (with `dir` and `tilt`, the spectral tilt that passed the
broadband gate) and `clap_rejected` (same fields, an impulse that was too
low-frequency to be hands: a door, a click), `knock`, `moved`, `someone_in_front`
(with `mm`), `someone_left`, `gesture` (with `kind` `swipe` or `tap` and
`mm`: a hand crossing or approaching the face for under half a second),
`shaken`, `flipped` (face down for 2 s; it goes to sleep), `upright`,
`picked_up`, `set_down` (with `tilt_deg`), `sound_started`, `sound_stopped`, `boot`, `wifi_connected`,
`wifi_disconnected`, `wifi_cmd` (with `len`), `setup_mode`, `setup_done`,
`identify`, `error` (with `what`).

Offline journal (firmware 0.6+): every event worth keeping carries a
`seq` and is written to a ring in the unit's internal flash (about 2000
records) before it is sent. The bridge sends `{"cmd":"ack","seq":N}` every
5 s over each live link with the highest seq below which it has seen every
event (gap-free; a replayed event fills its gap), seeded from the `acked`
field of the unit's hello. The unit keeps the acknowledged seq in its
settings page (survives reboots) and treats every record above it as
undelivered. Anything unacknowledged for more than 10 s is
replayed over the Wi-Fi link, oldest first, with `"late":true` and
`"age_s"` (seconds since it happened; -1 when it happened before the unit's
last reboot); the bridge moves `ts` back by `age_s`. If no ack arrives for
45 s the unit drops its Wi-Fi link and reconnects (`wifi_stale`).
`health.journal` counts records still waiting; `{"cmd":"journal"}` reports
pending and dropped.

Any program can be a unit by connecting to the unit port and speaking this
format. `bridge/voice.py` is one: unit `mac-voice`, takes
`{"cmd":"speak","text":"...","voice":"Samantha"}` (voice optional), reads
the text out with the Mac's voice and reports
`{"type":"event","name":"spoke","text":"..."}`. The agent has a `speak` tool.

Hearing: the ear chip (`ear/`) reports `{"type":"event","name":"heard",
"label":"creature"}` over HTTP when it hears the wake word; the bridge then
sends the body `express alert` and `gesture perk`. (The parked on-board
classifier in `ml/` would report the same `heard` events.) For training data, `{"cmd":"record","ms":1000}` makes the
unit stream one raw mono window from the left microphone, 16-bit 20 kHz, as
base64 chunks: `{"type":"audio","seq":0,"of":40,"rate":20000,"b64":"..."}`.
The bridge forwards audio messages to apps but does not log them.

Hello, once after boot:

```json
{"type":"hello","unit":"desk","fw":"0.3.0","sensors":["hts221","lps22hb","vl53l0x","lsm6dsl","lis3mdl","mp34dt01x2"],
 "wifi":{"module":"C3.5.2.5.STM","ssid":"MyNet","joined":true,"ip":"192.168.1.50","bridge":true},
 "acked":14,"last_seq":19}
```

The unit also sends hello when its TCP link to the bridge comes up, so the
bridge learns its name on that link.

Bridge to unit (commands, one JSON line):

```json
{"cmd":"hello"}                     -> the hello line again (the bridge sends this on connect,
                                       since the ST-LINK port does not reset the board)
{"cmd":"ping"}                      -> {"type":"pong","t":12345}
{"cmd":"status"}                    -> {"type":"status","unit":..,"ssid":..,"joined":..,"ip":..,"rssi":..,
                                        "bridge_host":..,"bridge_port":..,"bridge":true|false}
{"cmd":"name","name":"shelf"}      -> renames the unit, stored in flash, replies with hello
{"cmd":"wifi","ssid":"..","pass":".."}  -> stored in flash, joins now (blocks a few seconds), replies with status
{"cmd":"bridge","host":"192.168.1.92","port":8778}  -> the bridge address to connect to over Wi-Fi

`bridge/setup_unit.py` sends these for you.
```

## Bridge to apps (WebSocket, `ws://<host>:8777/`, text frames)

On connect the bridge sends, in order:

```json
{"type":"hello","bridge":"0.2.0","lan_ip":"192.168.1.92","unit_port":8778,
 "units":[{"unit":"desk","connected":true,"link":"serial","last_state":{...}}]}
{"type":"history","events":[{...}, ...]}      // last 200 events, oldest first; each already
                                              // carries "unit" and "ts" like a forwarded event
```

Then it forwards every unit message as it arrives, with three fields added
(`link` is `serial` or `wifi`):

```json
{"type":"state","unit":"desk","link":"wifi","ts":1761500000.123, ...}
{"type":"event","unit":"desk","link":"wifi","ts":1761500000.456,"name":"clap"}
```

Connection changes:

```json
{"type":"unit_status","unit":"desk","link":"wifi","connected":false,"ts":...}
```

Daily life (hub 0.4+): rules in `bridge/life.py` watch presence, readings
and sound, drive the creature's body (express, gesture, chirp) and post a
notice as an event of the creature with `link` `hub`:

```json
{"type":"event","unit":"crawl","link":"hub","name":"notice","kind":"greet","text":"Welcome back. You were away 45 minutes."}
```

Kinds: greet, morning, break, warm, goodnight. The hub hello carries
`"life":true|false`; `{"cmd":"life","on":0}` turns the rules off (kept in
data/life.json) and the hub answers `{"type":"life","enabled":false}`.

Talking without a speaker (hub 0.4+): `{"cmd":"say","unit":"crawl","text":"..."}`
makes the creature chirp and posts a notice of kind `say`; the agent's
`speak` tool does this when no speaker unit is online. The owner answers
with `{"cmd":"reply","unit":"crawl","text":"..."}`, which the hub records as
`{"type":"event","name":"speech","via":"notification","text":"..."}`, so
an agent waiting for speech hears it. `{"cmd":"messages","days":14}`
returns the conversation from the log:

```json
{"type":"messages","items":[{"id":"crawl|1793138676.1|notice","unit":"crawl","ts":1793138676.1,"from":"creature","kind":"say","text":"..."}]}
```

Optional relay for a phone with the app closed: `data/notify.json` with
`{"ntfy_topic":"<secret topic>","ntfy_server":"https://ntfy.sh"}` makes the
hub also post every notice to that ntfy topic. Off when the file is absent.
Notices then pass through the ntfy server, so pick a long random topic.

The eye (test rig, hub 0.5+): `tools/eye` runs on the Mac with a webcam
beside the creature, finds people and faces with Apple Vision, and posts to
the HTTP ingest as unit `eye`. Its events become events of the creature
(`"via":"eye"`): `someone_in_front`, `someone_left`, `looked_at`,
`looked_away`. A look earns a silent perk (mood and gesture, at most every
2 minutes), and the hub turns the head toward the person
(`look_at` from the lens's field of view, `hfov` in the eye's hello).

More events of the creature from the eye: hand signs `waved`, `thumbs_up`,
`open_palm` (snoozes notices for 30 minutes); head answers `nodded`,
`shook_head` (only when a notice is under 10 minutes old); posture
`slouching`, `sat_up`, `stretched` (restarts the break timer); tiredness
`yawned`, `eyes_heavy`. A thumbs-up, open palm, nod or shake soon after a
notice is also kept as the owner's answer (a `speech` event, `"via":"gesture"`).
New notice kinds: `posture`, `tired`.

What is happening: the hub folds the eye's outlines into one activity
(`bridge/scene.py`: away, with_someone, on_phone, eating, drinking,
stretching, reading, with_creature, working; a new one must hold 8 s) and
logs each change as `{"type":"event","name":"activity","activity":"working","text":"working at the desk","via":"eye"}`.
The eye's outline carries `things` (in hand: phone, drink, food, book,
headphones; pets: cat, dog). Recaps count minutes per activity, stretches
and time hunched; the agent's `whats_happening` tool returns the same.

The describer (`tools/describe`, its own Python environment with MLX VLM
and Qwen2.5-VL 3B, about 2 s a sentence) runs with the eye. Every 20 s while
someone is in view it sends `{"cmd":"snapshot"}` (one picture, loopback only),
describes it in memory and answers `{"cmd":"described","text":"...","seconds":1.7}`
(loopback only). The hub logs `{"type":"event","name":"described","text":"...","hints":["call"]}`;
the words become hints for 45 s (a video call, writing, a game, a video, a
phone or a drink), and "Nobody is at the desk" overrules a body box without
a face for 25 s. `{"cmd":"eye","describe":0}` turns the describer off.

When the eye runs: `{"cmd":"eye","mode":"off|auto|on"}`. The hub starts and
stops the eye program itself (auto: while the creature's own distance sensor
feels someone, and two minutes after), keeps the mode in data/eye.json, puts
`"eye":{"mode","running","camera","here"}` in its hello, and tells apps of
changes with `{"type":"eye","mode":"auto","running":false,...}`.

Five times a second the eye sends an outline, forwarded to apps with `for`
set to the creature and never logged:

```json
{"type":"vision","unit":"eye","for":"crawl","people":1,"present":true,"looking":true,
 "bodies":[[x,y,w,h]],"faces":[[x,y,w,h,1]],"aspect":1.78,"aim":-0.48,"pan":-13,"since":1793138676.1}
```

Boxes are 0..1 of the picture with the origin at the bottom left. The live
picture is opt in: `{"cmd":"picture","on":1}` subscribes this app (`0`
stops; leaving stops too). The eye encodes pictures only while someone is
subscribed (the hub's answer to each outline says so), and the hub sends
them to the subscribers only, never logs or keeps them:

```json
{"type":"picture","unit":"eye","for":"crawl","jpeg":"<base64, 480 wide>","ts":1793138677.2}
```

Apps to bridge, answered by the hub itself from its log:

```json
{"cmd":"series","unit":"crawl","field":"temp_c","seconds":3600,"request":"any-id"}
-> {"type":"series","unit":"crawl","field":"temp_c","request":"any-id","points":[[ts,value],...]}
```

Fields: temp_c, hum_pct, press_hpa, tof_mm, sound_db, heading_deg. At most
360 points, averaged into equal time buckets. A unit's earlier names count
(renames are kept in data/renames.json).

Apps to bridge (optional):

```json
{"cmd":"ping","unit":"desk"}
{"cmd":"express","unit":"desk","mood":"pleased"}   // phase 3
```

`unit` selects the target; the bridge strips it (and `via`) and forwards
the rest over the unit's serial link if alive, else its Wi-Fi link.

Discovery: the bridge advertises itself with Bonjour as `_roomcreature._tcp`
on port 8777, instance name = the Mac's hostname, and also prints its LAN
address at startup. Apps prefer Bonjour when it is enabled in their settings
and otherwise use the host and port typed by the user (default
`localhost:8777`). Apps ignore message types they do not know (`pong`).
`hello.units[].last_state` may be null before the first state line.

## Bridge to agent (MCP over stdio)

Tools:

- `room_state(unit?)` -> latest state of one unit, or all units
- `recent_events(unit?, seconds=300)` -> events in the window
- `wait_for_event(names?, timeout_s=30)` -> the first matching event or null
- `units()` -> list with connection status

## Body (phase 3)

The creature has five joints and two cheek lights. The firmware runs the
expression engine whether or not servos are attached, so the app can show
the body and the agent can drive it before the hardware exists.

Joint ranges, in degrees, 0 = rest:

| joint | range | meaning |
| :- | :- | :- |
| `ear_l`, `ear_r` | -45 .. 45 | negative = drooped back, positive = perked forward |
| `pan` | -60 .. 60 | head turn, negative = left (from the creature's view) |
| `tilt` | -30 .. 30 | head nod, positive = up |
| `tail` | -40 .. 40 | side to side |

`cheek` is a CSS hex colour. `mood` is one of `neutral`, `listening`,
`alert`, `curious`, `pleased`, `surprised`, `sleepy`. `gesture` is the
gesture now playing or `""`.

The state line gains a `body` object once a second:

```json
{"type":"state", ..., "body":{"ear_l":30,"ear_r":30,"pan":-12,"tilt":5,"tail":0,
                              "cheek":"#6ea8ff","mood":"listening","gesture":"","servos":false}}
```

and a `body` message is sent immediately whenever the mood, gesture or
look target changes, with the same object plus `t`, so apps can animate
without waiting for the next state line:

```json
{"type":"body","t":12345,"ear_l":45,"ear_r":45,"pan":-30,"tilt":10,"tail":0,
 "cheek":"#ffb347","mood":"surprised","gesture":"perk","servos":false,"why":"clap"}
```

`why` is the reflex or command that caused the change: `clap`, `sound`,
`someone_in_front`, `someone_left`, `quiet`, `knock`, `agent`.

Reflexes on the unit (no agent needed): ears and head turn toward a sound,
head looks at a person in front and cheeks go amber, a clap makes it
surprised for a moment, a knock makes it alert, a quiet minute makes it
sleepy with ears drooped, a pat (knock while someone is in front) wags
the tail and turns the cheeks green.

Commands:

```json
{"cmd":"express","mood":"pleased"}                 // hold a mood (reflexes still layer on top)
{"cmd":"gesture","name":"wag"}                     // wag, nod, shake, perk, droop
{"cmd":"look_at","pan":-20,"tilt":5}               // hold a look for 10 s, then reflexes resume
{"cmd":"cheek","color":"#ff00ff"}                  // override the cheek colour until the next mood change
{"cmd":"servo","ch":2,"us":1500}                   // hold one PCA9685 channel at a raw pulse for 15 s (us 0 releases)
{"cmd":"trim","joint":"pan","us":-30,"invert":1}   // centre offset (us) and direction for a joint, stored in flash
{"cmd":"cheek_invert","value":1}                   // common-anode cheek LEDs
{"cmd":"calib"}                                    // -> {"type":"calib","servos":..,"trim":[5],"invert":[5],"cheek_invert":..}
{"cmd":"chirp","name":"hello"}                     // hello, happy, sad, alert, purr, ok, no, sleepy; speaker on header D5 (PB4)
{"cmd":"scan"}                                     // -> {"type":"scan","n":5,"networks":[{"ssid":..,"rssi":-58,"secured":1},...]} (blocks a few seconds)
{"cmd":"journal"}                                  // -> {"type":"journal","pending":..,"acked":..,"last_seq":..,...}
{"cmd":"provision"} / {"cmd":"provision","on":0}  // enter / leave Bluetooth setup mode
{"cmd":"restart"}                                  // reboot (reports {"type":"event","name":"restart","why":"command"} first)
{"cmd":"forget_wifi"}                              // clear the stored network and reboot into setup mode
```

Reflex chirps: `ok` when the Wi-Fi link comes up and on an air tap, `happy`
on a swipe and when setup finishes, `alert` on a knock, `purr` on a pat,
`hello` on identify and when the ear hears the wake word.

Channels: 0 ear_l, 1 ear_r, 2 pan, 3 tilt, 4 tail, 5/6/7 cheek R/G/B. Servo
pulse = 1500 + trim + sign * angle * 1000/90 us, clamped to 600..2400.

Apps send the same objects with a `unit` field; the agent has `express`,
`gesture` and `look_at` tools.

## Onboarding over Bluetooth (setup mode)

A unit with no stored network, or with the blue button held during boot,
or after `{"cmd":"provision"}`, enters setup mode: Wi-Fi off, cheeks violet,
Bluetooth advertising as `creature-XXXX` (last four hex digits of its MAC).
It speaks the open Improv Wi-Fi over BLE protocol, so standard Improv apps
work, plus three small characteristics of our own for the network list.

Service `00467768-6228-2272-4663-277478268000` (Improv):

| characteristic (suffix of the service UUID) | access | content |
| :- | :- | :- |
| `...8005` capabilities | read | 1 byte, bit 0 = supports identify |
| `...8001` current state | read, notify | 1 byte: 0x02 authorized (ready), 0x03 provisioning, 0x04 provisioned |
| `...8002` error state | read, notify | 1 byte: 0 none, 1 invalid packet, 2 unknown command, 3 unable to connect, 0xFF unknown |
| `...8003` RPC command | write | packet `cmd, len, data..., checksum` where checksum = sum of all preceding bytes & 0xFF |
| `...8004` RPC result | read, notify | packet `cmd, len, strings..., checksum`; each string is length-prefixed |

RPC commands: `0x01` send Wi-Fi settings, data = `ssid_len, ssid, pass_len,
pass`; `0x02` identify (the creature wags and flashes its cheeks).
After `0x01` the unit tries to join (up to 15 s): on success state becomes
0x04 and the result carries one string, the unit's URL
(`http://<ip>/` placeholder); on failure error becomes 3 and state 0x02.
Ten seconds after success the unit leaves setup mode: Bluetooth off, Wi-Fi
on, normal operation, credentials stored.

Network list (ours, same service):

| characteristic | access | content |
| :- | :- | :- |
| `...8010` network count | read | 1 byte |
| `...8011` network index | write | 1 byte, selects an entry |
| `...8012` network entry | read | text `secured|rssi|ssid` e.g. `1|-58|HomeNet`, name cut to 20 chars (fits a default-MTU read); `secured` gets an `s` appended (`1s`) for the network the unit last joined. Entries come strongest first with duplicate names merged |
| `...8013` bridge address | write | text `host:port`, e.g. `192.168.1.92:8778`; the app takes it from the bridge's WebSocket hello |

The unit scans once when entering setup mode and again every 30 s while no
phone is connected. The app reads the count, then each entry, and shows
them sorted by signal. The app writes the bridge address before sending the
Wi-Fi settings, so the unit knows where to connect on the new network.
