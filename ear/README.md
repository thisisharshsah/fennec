# ear: the creature's wake-word chip

Hardware: Seeed XIAO ESP32S3 Sense (ESP32-S3, 8 MB PSRAM, PDM microphone on
the Sense board), about 15 USD. Later a MAX98357A I2S amplifier and a 28 mm
speaker for the voice.

Software: ESPHome with `micro_wake_word`, the open-source wake-word engine
whose models are trained from synthetic speech (no recordings needed). The
chip hears the wake word on-device and POSTs `heard: creature` to the
bridge's HTTP ingest (port 8776). Nothing else leaves the chip.

```bash
~/.local/bin/uv pip install -p bridge/.venv/bin/python esphome
cp ear/secrets.example.yaml ear/secrets.yaml      # fill in the Wi-Fi details
bridge/.venv/bin/esphome run ear/creature-ear.yaml
```

Until a custom "creature" model is trained with microWakeWord's training
notebook, the stock `okay_nabu` model proves the whole path. When the ear
says the word, the bridge nudges the body: the creature goes alert and perks
its ears.

Stage two, with the body: after the wake word the chip streams audio to the
hub for speech to text (ESPHome `voice_assistant` pointed at the hub). The
hub is the Mac during tests, later the phone app or a small home server.
