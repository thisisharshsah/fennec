# bedsense: project brief

Last updated: 2026-10-26

## The problem

Pressure injuries (bedsores) claim over 60,000 lives a year in the US, cost the
system over $11 billion, and affect about 2.5 million Americans annually. They
are almost entirely preventable: the standard of care is repositioning the
patient every 2 hours. It fails because turns get missed, and because nursing
time is the thing that decides both cost and compliance.

The incumbent fix, LEAF (Smith+Nephew), is a chest-worn wearable with a
facility antenna network that confirms turns and documents adherence. It is
FDA-cleared, reduces hospital-acquired pressure injuries by about 74%, and is a
hospital product at hospital prices. It needs a patch on fragile skin and does
nothing for nursing homes or families caring for a bedbound parent at home,
which is where most bedbound people are.

## The product

A bed that knows when its occupant was last turned.

- A flat pad under the mattress at chest level. Nothing touches the patient.
- The IMU detects repositioning: a large rotation transient followed by a new
  static orientation. Small shifts are not turns.
- Every turn is logged. "No turn in 2 hours" alerts the caregiver's phone and
  lights the pad's edge. The log is the documentation nursing homes are
  audited on.
- The same signal gives bed exit, a night restlessness index and (research
  grade) breathing rate; a rail-mounted presence sensor can confirm occupancy.

Why it fits: real deaths in the one population no wearable can serve; a
production node in the $12 class sold per bed to nursing homes and home-care
agencies with the dashboard as the subscription; and a light regulatory
position (see below) with a known predicate if clinical claims are added later.

## Regulatory position (not legal advice)

- Caregiver reminder plus turn log, no clinical claim: stays outside device
  regulation under FDA's 2026 general wellness policy as long as outputs are
  non-invasive, low risk and make no diagnosis, treatment or disease claims.
- Claiming pressure-injury prevention or reporting respiratory rate: Class II.
  LEAF is an existing cleared predicate for the turn-confirmation claim, which
  makes a 510(k) a known path rather than an open question.
- HIPAA applies as soon as a clinic or agency is the customer.
- Launch with the wellness version; collect the pilot data; add claims later.

## Why this board for the prototype

The board in hand is the B-L4S5I-IOT01A (STM32L4S5VI, 120 MHz, 2 MB flash,
640 KB RAM; it mounts as `DIS_L4S5VI`), the newer version of the
B-L475E-IOT01A with the same layout, radios and sensors. It is mains powered
and stationary under a mattress, so its size is irrelevant. Only the LSM6DSL IMU is needed for the core signal; Wi-Fi
and flash cover alerts and offline buffering later; the ToF sensor can confirm
bed presence from a rail mount. Firmware is written so it moves to a smaller
production board unchanged.

Under-mattress accelerometers are a proven signal: published systems reach
about 1.5 breaths/min and 2.2 beats/min average error for respiratory and
heart rate across 23 subjects, with chest-level placement preferred. Turn
detection is a far easier signal than that.

## Plan

1. Night 1 (this folder, v0.1): log raw IMU at 104 Hz over the ST-LINK serial
   port; lie down, roll three times; confirm breathing is visible and each roll
   is a burst followed by a new tilt. `tools/plot_session.py` does the
   detection and the plot.
2. Days 2 to 3: on-device turn detector, 2-hour timer that resets on each
   turn, Wi-Fi push notification (ntfy or a Telegram bot) when it expires, LED
   on the board as the in-room cue.
3. Days 4 to 5: bed exit and entry from the IMU, confirmed by the ToF sensor
   on the rail; night restlessness count.
4. Week 2: breathing rate from the same signal (0.1 to 0.7 Hz band, peak
   count), logged but not claimed.
5. Week 3: caregiver page (time since last turn, turns tonight, bed exits,
   restlessness, breathing trend). One week under one real bed: a family with a
   bedbound relative, or a nursing home that will allow it.

That week of data is what a nursing-home director, a home-care agency or a
wound-care nurse reacts to, and it is the one thing LEAF cannot say: no
wearable, no antenna network, nothing on the skin.

## Enclosure (prototype and renders)

Flat rectangular pad shaped around the dev board (board about 90 x 60 mm):

- outer size about 110 x 80 x 18 mm
- matte white polycarbonate top, softly rounded corners and edges
- textured grey silicone anti-slip underside
- one short edge carries a thin status light bar and a single large
  soft-touch button; this edge is the only part visible at the mattress edge
- fabric-covered USB-C cable exits the same edge
- no screen, no visible seams, no text, no logo

The pad is the better prototype shape anyway: a rigid plate couples body
movement into the accelerometer more evenly than a narrow bar. If a custom PCB
later shrinks it to a bar, only the render base block changes.

## Production reference (later)

MCU with Wi-Fi (ESP32-S3 class or STM32 plus module), LSM6DSV16X or similar
IMU, mains USB-C power, small SPI flash for offline buffering, light bar and
button, optional rail-mounted ToF presence sensor. Phone or web dashboard over
a HIPAA-eligible backend once clinics are customers.

## Open questions

- Turn vs shift threshold on a real mattress, real bed frame, real patient
  weight. Needs the night-1 data and then several nights.
- Mattress type: foam vs spring vs alternating-pressure air mattress (common
  in exactly this population, and a possible noise source).
- Two-person beds at home.
- Whether breathing is reliably visible through a thick foam mattress.
