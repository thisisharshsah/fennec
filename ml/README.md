# ml: a parked experiment

Status 2026-10-27: built to the point of recording clips through the board
and compiling the on-board classifier, then parked. Hearing words goes to an
ear chip with a proven engine (see docs/room-agent-plan.md). Kept because
the recorder and the feature extractor are useful for any later on-board
audio work.


A small sound classifier runs on the board (`src/kws.cpp`), trained here
from clips recorded through the board's own microphones. No speech
recognition, no cloud: labels only.

## Pipeline

```
board mic -[record cmd]-> ml/record.py -> ml/data/<label>/*.wav (20 kHz, 16-bit, 1 s)
ml/train.py: log-mel features (ml/features.py) -> tiny CNN -> src/model_weights.h
pio run -t upload -> board emits {"type":"event","name":"heard","label":"clap","score":0.93}
```

Features (identical in `ml/features.py` and `src/kws.cpp`): 512-sample
frames, hop 256, Hann window, 32 mel bands 80 Hz to 8 kHz, natural log,
window of 64 frames (0.83 s) with its mean removed. Model: three 3x3
stride-2 convolutions (8, 16, 32 channels), global average pool, dense.
About 6k weights, about 330k multiply-adds, run every 205 ms on the board.

## Recording

The board must be on the cable (clips are too much for the Wi-Fi module),
the bridge running.

```bash
bridge/.venv/bin/python ml/collect_auto.py -n 25                 # quiet, speech, noise, alert: no human needed
bridge/.venv/bin/python ml/record.py creature -c 40              # say "creature" at each prompt, vary distance and tone
bridge/.venv/bin/python ml/record.py clap -c 40
bridge/.venv/bin/python ml/record.py knock -c 40
bridge/.venv/bin/python ml/record.py quiet -c 20 -a            # more background from the real room
```

Aim for 30 to 50 clips per class, recorded from where the creature will
actually sit, at several distances. The label folder name becomes the
class name. Background classes (`quiet`, `noise`, `speech`) never raise
events; everything else does.

## Training and flashing

```bash
bridge/.venv/bin/python ml/train.py            # prints test accuracy and a confusion matrix
~/.platformio/penv/bin/pio run -t upload
```

Check it live: `{"cmd":"scores"}` returns the current class probabilities,
`{"cmd":"features","frame":63}` one frame of the live log-mel window.
`bridge/setup_unit.py` is not involved; use the app's event feed or the
agent's `wait_for_event(["heard"])`.

## Limits

128 KB of RAM: the model's scratch is about 24 KB and the feature ring
4 KB. A bigger model means fewer or smaller layers elsewhere. Training on
the Mac takes under a minute on CPU.
