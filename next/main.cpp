// bedsense v0.2 (next): on-device turn detection + turn timer
//
// Same raw CSV stream as v0.1 (t_ms,ax,ay,az,gx,gy,gz at 104 Hz), plus event lines:
//   #TURN t_ms=<start> dur_ms=<n> angle=<deg>    rotation burst that ended in a new orientation
//   #SHIFT t_ms=<start> dur_ms=<n> angle=<deg>   movement that did not change orientation enough
//   #OVERDUE t_ms=<now> since_ms=<n>             no turn within TURN_INTERVAL_MS; LD2 goes solid
//   #MARK                                         blue user button pressed
//
// Detector (mirrors tools/plot_session.py so on-device and offline results can be compared):
//   movement  = 0.5 s RMS of gyro magnitude above THR_DPS
//   event end = HANG_MS below threshold; wait SETTLE_MS; compare the resting
//               gravity vector before and after; angle >= MIN_ANGLE is a turn
//
// The thresholds are first guesses. Tune them from recorded sessions, then promote
// this file to src/main.cpp.

#include <Arduino.h>
#include <Wire.h>
#include <LSM6DSLSensor.h>
#include <math.h>

#ifndef TURN_INTERVAL_MS
#define TURN_INTERVAL_MS (2UL * 60UL * 60UL * 1000UL)   // 2 h; bench test: -D TURN_INTERVAL_MS=120000
#endif

static const uint32_t BAUD        = 115200;
static const float    ODR_HZ      = 104.0f;
static const uint32_t PERIOD_US   = 9615;

static const float    THR_DPS     = 15.0f;    // gyro RMS that counts as movement
static const float    MIN_ANGLE   = 10.0f;    // degrees of tilt change that make a movement a turn
static const uint32_t HANG_MS     = 2000;     // movement ends after this long below threshold
static const uint32_t SETTLE_MS   = 2000;     // then wait this long before reading the new orientation
static const int      RMS_N       = 52;       // 0.5 s window at 104 Hz
static const float    EMA_ALPHA   = 0.02f;    // orientation filter, ~0.5 s time constant

static const float    G_PER_LSB   = 0.061e-3f;
static const float    DPS_PER_LSB = 17.5e-3f;

TwoWire dev_i2c(PB11, PB10);
LSM6DSLSensor imuLow(&dev_i2c, LSM6DSL_ACC_GYRO_I2C_ADDRESS_LOW);
LSM6DSLSensor imuHigh(&dev_i2c, LSM6DSL_ACC_GYRO_I2C_ADDRESS_HIGH);
LSM6DSLSensor *imu = nullptr;

static bool probe(LSM6DSLSensor &s)
{
  uint8_t id = 0;
  s.begin();
  s.ReadID(&id);
  return id == 0x6A;
}

// detector state
enum State { IDLE, MOVING, SETTLING };
static State    state = IDLE;
static float    sq[RMS_N];
static int      sqIdx = 0;
static float    sqSum = 0.0f;
static float    ori[3] = {0, 0, 1};        // filtered gravity vector (g)
static float    oriBefore[3];
static uint32_t evStart = 0, lastActive = 0, settleUntil = 0;

static uint32_t lastTurnMs = 0;
static bool     overdue = false;
static int      btnIdle = -1;

static float angleBetween(const float *a, const float *b)
{
  float dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  float na = sqrtf(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
  float nb = sqrtf(b[0] * b[0] + b[1] * b[1] + b[2] * b[2]);
  float c = dot / (na * nb + 1e-9f);
  if (c > 1.0f) c = 1.0f;
  if (c < -1.0f) c = -1.0f;
  return acosf(c) * 57.2957795f;
}

static void setOverdueLed(bool on)
{
#ifdef LED2
  digitalWrite(LED2, on ? HIGH : LOW);
#endif
}

void setup()
{
  Serial.begin(BAUD);
#ifdef LED_BUILTIN
  pinMode(LED_BUILTIN, OUTPUT);
#endif
#ifdef LED2
  pinMode(LED2, OUTPUT);
#endif
#ifdef USER_BTN
  pinMode(USER_BTN, INPUT);
  btnIdle = digitalRead(USER_BTN);
#endif

  dev_i2c.begin();
  dev_i2c.setClock(400000);
  delay(100);

  if (probe(imuLow))       imu = &imuLow;
  else if (probe(imuHigh)) imu = &imuHigh;
  if (imu == nullptr) {
    while (true) {
      Serial.println("# ERROR: LSM6DSL not found on I2C2 (PB11/PB10)");
      delay(1000);
    }
  }

  imu->Set_X_FS(2.0f);
  imu->Set_G_FS(500.0f);
  imu->Enable_X();
  imu->Enable_G();
  imu->Set_X_ODR(ODR_HZ);
  imu->Set_G_ODR(ODR_HZ);

  for (int i = 0; i < RMS_N; i++) sq[i] = 0.0f;
  lastTurnMs = millis();

  Serial.println("# bedsense v0.2");
  Serial.print("# turn interval ms="); Serial.println((unsigned long)TURN_INTERVAL_MS);
  Serial.print("# thr_dps="); Serial.print(THR_DPS);
  Serial.print(" min_angle="); Serial.print(MIN_ANGLE);
  Serial.print(" hang_ms="); Serial.print((unsigned long)HANG_MS);
  Serial.print(" settle_ms="); Serial.println((unsigned long)SETTLE_MS);
  Serial.println("t_ms,ax,ay,az,gx,gy,gz");
}

void loop()
{
  static uint32_t next_us   = micros();
  static uint32_t lastBlink = 0;
  static uint32_t lastBtn   = 0;

  if ((int32_t)(micros() - next_us) < 0) return;
  next_us += PERIOD_US;

  int16_t a[3], g[3];
  imu->Get_X_AxesRaw(a);
  imu->Get_G_AxesRaw(g);
  uint32_t now = millis();

  char line[64];
  snprintf(line, sizeof line, "%lu,%d,%d,%d,%d,%d,%d",
           (unsigned long)now, a[0], a[1], a[2], g[0], g[1], g[2]);
  Serial.println(line);

  // movement envelope: 0.5 s RMS of gyro magnitude
  float gx = g[0] * DPS_PER_LSB, gy = g[1] * DPS_PER_LSB, gz = g[2] * DPS_PER_LSB;
  float m2 = gx * gx + gy * gy + gz * gz;
  sqSum += m2 - sq[sqIdx];
  sq[sqIdx] = m2;
  sqIdx = (sqIdx + 1) % RMS_N;
  float env = sqrtf(sqSum > 0 ? sqSum / RMS_N : 0.0f);
  bool active = env > THR_DPS;

  // orientation filter (only trusted while not moving)
  float acc[3] = {a[0] * G_PER_LSB, a[1] * G_PER_LSB, a[2] * G_PER_LSB};
  if (state != MOVING) {
    for (int i = 0; i < 3; i++) ori[i] += EMA_ALPHA * (acc[i] - ori[i]);
  }

  // state machine
  switch (state) {
    case IDLE:
      if (active) {
        for (int i = 0; i < 3; i++) oriBefore[i] = ori[i];
        evStart = now;
        lastActive = now;
        state = MOVING;
      }
      break;

    case MOVING:
      if (active) {
        lastActive = now;
      } else if (now - lastActive > HANG_MS) {
        for (int i = 0; i < 3; i++) ori[i] = acc[i];     // restart the filter at the new pose
        settleUntil = now + SETTLE_MS;
        state = SETTLING;
      }
      break;

    case SETTLING:
      if (active) {                                        // moved again: extend the same event
        lastActive = now;
        state = MOVING;
      } else if ((int32_t)(now - settleUntil) >= 0) {
        float ang = angleBetween(oriBefore, ori);
        uint32_t dur = lastActive - evStart;
        bool isTurn = ang >= MIN_ANGLE;
        snprintf(line, sizeof line, "#%s t_ms=%lu dur_ms=%lu angle=%.1f",
                 isTurn ? "TURN" : "SHIFT", (unsigned long)evStart, (unsigned long)dur, ang);
        Serial.println(line);
        if (isTurn) {
          lastTurnMs = now;
          overdue = false;
          setOverdueLed(false);
        }
        state = IDLE;
      }
      break;
  }

  // turn timer
  if (!overdue && now - lastTurnMs > TURN_INTERVAL_MS) {
    overdue = true;
    setOverdueLed(true);
    snprintf(line, sizeof line, "#OVERDUE t_ms=%lu since_ms=%lu",
             (unsigned long)now, (unsigned long)(now - lastTurnMs));
    Serial.println(line);
  }

  // heartbeat + button
#ifdef LED_BUILTIN
  if (now - lastBlink >= 1000) {
    lastBlink = now;
    digitalWrite(LED_BUILTIN, !digitalRead(LED_BUILTIN));
  }
#endif
#ifdef USER_BTN
  if (btnIdle >= 0 && digitalRead(USER_BTN) != btnIdle && now - lastBtn > 300) {
    lastBtn = now;
    Serial.println("#MARK");
  }
#endif
}
