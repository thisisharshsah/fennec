# next: firmware v0.2 (on-device turn detection)

Not built yet. `src/main.cpp` stays the plain v0.1 streamer until the first
real recordings have been looked at and the thresholds here have been tuned
against them.

What v0.2 adds on top of v0.1 (same raw stream, so the logger and plots keep
working):

- `#TURN` / `#SHIFT` event lines, classified on the board with the same
  rule as `tools/plot_session.py` (gyro RMS burst, then tilt change)
- a turn timer: `#OVERDUE` line and LD2 solid on when no turn happened
  within `TURN_INTERVAL_MS` (2 h; build with `-D TURN_INTERVAL_MS=120000`
  for a 2-minute bench test)
- `tools/log_serial.py` already turns those lines into `dev-turn`,
  `dev-shift` and `dev-overdue` markers, so a recording made with v0.2 shows
  the on-device decisions next to the offline ones in the plot

To promote: copy `next/main.cpp` over `src/main.cpp`, then `pio run -t upload`.
For the bench variant, add to `platformio.ini`:

```
build_flags = -D TURN_INTERVAL_MS=120000
```

Things to decide from the data before promoting:

- `THR_DPS` (15): does lying still ever cross it? does a real roll always?
- `MIN_ANGLE` (10): what tilt change does a real repositioning produce
  through a mattress, versus a leg shift?
- `HANG_MS` / `SETTLE_MS` (2 s each): long enough that a slow roll is one event
