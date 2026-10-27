#include "body.h"
#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_PWMServoDriver.h>
#include <math.h>
#include <string.h>
#include "link.h"

struct Pose { float earL, earR, pan, tilt, tail; uint32_t cheek; };

struct Mood { const char *name; Pose pose; };
static const Mood MOODS[] = {
  {"neutral",   { 10,  10,  0,  0, 0, 0x8fb3ff}},
  {"listening", { 35,  35,  0,  5, 0, 0x6ea8ff}},
  {"alert",     { 45,  45,  0, 10, 0, 0xffb347}},
  {"curious",   { 30,  10,  0,  8, 0, 0xb48cff}},
  {"pleased",   { 25,  25,  0,  5, 0, 0x7ddf8a}},
  {"surprised", { 45,  45,  0, 15, 0, 0xffd166}},
  {"sleepy",    {-40, -40,  0,-15, 0, 0x4a5a7a}},
};
static const int N_MOODS = sizeof MOODS / sizeof MOODS[0];

static const uint32_t TEMP_MOOD_MS   = 2500;
static const uint32_t SOUND_LOOK_MS  = 4000;
static const uint32_t SLEEP_AFTER_MS = 60000;
static const uint32_t TICK_MS        = 20;
static const uint32_t AGENT_HOLD_MS  = 20000;   // an agent-set mood resists the sound reflex this long

// PCA9685 channels: 0 ear_l, 1 ear_r, 2 pan, 3 tilt, 4 tail, 5 cheek R, 6 cheek G, 7 cheek B
static const int CH_CHEEK_R = 5, CH_CHEEK_G = 6, CH_CHEEK_B = 7;
static const uint32_t BODY_CFG_MAGIC = 0x424F4431;   // "BOD1"
static const size_t   BODY_CFG_OFFSET = 256;          // after LinkConfig in the EEPROM page

struct BodyConfig { uint32_t magic; int16_t trimUs[5]; int8_t sign[5]; uint8_t cheekInvert; };
static BodyConfig cfg;

static int      rawUs[16]; static uint32_t rawUntil[16];   // manual channel overrides
static uint32_t lastCheek = 0xFFFFFFFF;

static TwoWire wire1(PB9, PB8);                       // Arduino header I2C1
static Adafruit_PWMServoDriver pwm(0x40, wire1);
static bool servos = false;

static Pose cur = MOODS[0].pose, target = MOODS[0].pose;
static int  baseMood = 0, tempMood = -1;
static uint32_t tempUntil = 0;
static bool cheekOverride = false; static uint32_t cheekColor = 0;

static bool  lookActive = false; static float lookPan = 0, lookTilt = 0; static uint32_t lookUntil = 0;
static bool  present = false;
static uint32_t lastActivity = 0, lastTick = 0;

static char  gesture[12] = ""; static uint32_t gestureStart = 0, gestureLen = 0;
static bool  dirty = true; static char why[20] = "boot";
static uint32_t agentHoldUntil = 0;
static uint32_t nextTwitch = 8000; static int twitchEar = 0; static uint32_t twitchUntil = 0;

static void mark(const char *w)
{
  if (dirty) return;                      // keep the first cause until it has been reported
  dirty = true; strncpy(why, w, sizeof why - 1); why[sizeof why - 1] = 0;
}

static int moodIndex(const char *name)
{
  for (int i = 0; i < N_MOODS; i++) if (!strcmp(MOODS[i].name, name)) return i;
  return -1;
}

static void setTemp(int m, uint32_t ms, const char *w)
{
  tempMood = m; tempUntil = millis() + ms; lastActivity = millis(); mark(w);
}

static void loadBodyConfig()
{
  cfgLoad(&cfg, sizeof cfg, BODY_CFG_OFFSET);
  if (cfg.magic != BODY_CFG_MAGIC) {
    memset(&cfg, 0, sizeof cfg);
    cfg.magic = BODY_CFG_MAGIC;
    for (int i = 0; i < 5; i++) cfg.sign[i] = 1;
  }
  for (int i = 0; i < 5; i++) if (cfg.sign[i] != -1) cfg.sign[i] = 1;
}

void bodyBegin()
{
  loadBodyConfig();
  wire1.begin();
  wire1.setClock(400000);
  wire1.beginTransmission(0x40);
  if (wire1.endTransmission() == 0 && pwm.begin()) {
    pwm.setOscillatorFrequency(27000000);
    pwm.setPWMFreq(50);
    servos = true;
  }
  lastActivity = millis();
}

bool bodyHasServos() { return servos; }

void bodyOnSound(float dir, bool loud)
{
  if (!loud) return;
  lastActivity = millis();
  bool held = (int32_t)(millis() - agentHoldUntil) < 0;
  if (!held && (tempMood < 0 || MOODS[tempMood].name[0] != 's')) {   // do not override surprised or an agent mood
    if (tempMood != 1) setTemp(1, TEMP_MOOD_MS, "sound"); else tempUntil = millis() + TEMP_MOOD_MS;
  }
  if (!present && !(lookActive && lookUntil > millis() + SOUND_LOOK_MS)) {
    lookActive = true; lookPan = dir * 45.0f; lookTilt = 5; lookUntil = millis() + SOUND_LOOK_MS;
  }
}

void bodyOnClap(float dir)
{
  setTemp(5, TEMP_MOOD_MS, "clap");
  lookActive = true; lookPan = dir * 50.0f; lookTilt = 12; lookUntil = millis() + SOUND_LOOK_MS;
  bodyGesture("perk");
}

void bodyOnKnock()
{
  if (present) { setTemp(4, 3000, "pat"); bodyGesture("wag"); }
  else setTemp(2, 3000, "knock");
}

void bodyOnPresence(bool p)
{
  if (p == present) return;
  present = p;
  lastActivity = millis();
  if (p) { setTemp(2, 4000, "someone_in_front"); lookActive = true; lookPan = 0; lookTilt = 10; lookUntil = millis() + 3600000UL; }
  else   { lookActive = false; if (tempMood == 2) tempMood = -1; mark("someone_left"); }
}

bool bodyExpress(const char *mood)
{
  int m = moodIndex(mood);
  if (m < 0) return false;
  baseMood = m; tempMood = -1; cheekOverride = false; lastActivity = millis();
  agentHoldUntil = millis() + AGENT_HOLD_MS;
  mark("agent");
  return true;
}

bool bodyGesture(const char *name)
{
  static const char *known[] = {"wag", "nod", "shake", "perk", "droop"};
  for (auto k : known) if (!strcmp(k, name)) {
    strcpy(gesture, name); gestureStart = millis();
    gestureLen = !strcmp(name, "wag") ? 1500 : !strcmp(name, "nod") ? 1300 : !strcmp(name, "shake") ? 1500 : 1200;
    lastActivity = millis();
    if (why[0] == 0 || !dirty) mark("agent");
    return true;
  }
  return false;
}

void bodyLookAt(float pan, float tilt, uint32_t holdMs)
{
  lookActive = true; lookPan = constrain(pan, -60, 60); lookTilt = constrain(tilt, -30, 30);
  lookUntil = millis() + holdMs; lastActivity = millis(); mark("agent");
}

void bodyCheek(uint32_t rgb) { cheekOverride = true; cheekColor = rgb; mark("agent"); }

static void computeTarget(uint32_t now)
{
  if (tempMood >= 0 && (int32_t)(now - tempUntil) >= 0) { tempMood = -1; mark("calm"); }
  int m = tempMood >= 0 ? tempMood : baseMood;
  if (tempMood < 0 && baseMood != 6 && now - lastActivity > SLEEP_AFTER_MS) {
    if (m != 6) mark("quiet");
    m = 6;
  }
  target = MOODS[m].pose;
  if (lookActive && (int32_t)(now - lookUntil) < 0) { target.pan = lookPan; target.tilt += lookTilt; }
  else if (lookActive) { lookActive = false; mark("look_done"); }
  if (cheekOverride) target.cheek = cheekColor;

  if (gesture[0]) {
    float t = (now - gestureStart) / 1000.0f;
    if (now - gestureStart >= gestureLen) { gesture[0] = 0; mark("gesture_done"); }
    else if (!strcmp(gesture, "wag"))   target.tail += 35.0f * sinf(2 * (float)M_PI * 3.0f * t);
    else if (!strcmp(gesture, "nod"))   target.tilt += 15.0f * sinf(2 * (float)M_PI * 1.5f * t);
    else if (!strcmp(gesture, "shake")) target.pan  += 20.0f * sinf(2 * (float)M_PI * 2.0f * t);
    else if (!strcmp(gesture, "perk"))  { target.earL = 45; target.earR = 45; }
    else if (!strcmp(gesture, "droop")) { target.earL = -45; target.earR = -45; }
  }
  // idle life: a slow breath, an occasional ear twitch, a soft cheek pulse
  bool idle = !gesture[0] && !lookActive && tempMood < 0;
  float t = now / 1000.0f;
  if (idle && m != 6) {
    target.tilt += 1.5f * sinf(2 * (float)M_PI * 0.2f * t);            // breathing, 5 s period
    if ((int32_t)(now - nextTwitch) >= 0) {
      twitchEar = (now / 7) & 1; twitchUntil = now + 250;
      nextTwitch = now + 6000 + (now * 7919u) % 9000u;                 // next twitch in 6 to 15 s
    }
    if ((int32_t)(now - twitchUntil) < 0) { if (twitchEar) target.earR += 15; else target.earL += 15; }
  }
  if (m == 6) target.tilt += 1.0f * sinf(2 * (float)M_PI * 0.12f * t); // sleeping breath, slower
  {                                                                    // cheek pulse: 70..100 % brightness, 4 s period
    float k = 0.85f + 0.15f * sinf(2 * (float)M_PI * 0.25f * t);
    uint32_t c = target.cheek;
    uint32_t r = (uint32_t)(((c >> 16) & 0xFF) * k), g = (uint32_t)(((c >> 8) & 0xFF) * k), b = (uint32_t)((c & 0xFF) * k);
    target.cheek = (r << 16) | (g << 8) | b;
  }
  target.pan = constrain(target.pan, -60, 60); target.tilt = constrain(target.tilt, -30, 30);
  target.tail = constrain(target.tail, -40, 40);
}

static void writeServos()
{
  if (!servos) return;
  uint32_t now = millis();
  const float ang[5] = {cur.earL, cur.earR, cur.pan, cur.tilt, cur.tail};
  for (int i = 0; i < 5; i++) {
    int us;
    if (rawUs[i] && (int32_t)(now - rawUntil[i]) < 0) us = rawUs[i];
    else { rawUs[i] = 0; us = 1500 + cfg.trimUs[i] + (int)(cfg.sign[i] * ang[i] * (1000.0f / 90.0f)); }
    pwm.writeMicroseconds(i, (uint16_t)constrain(us, 600, 2400));
  }
  for (int i = 5; i < 16; i++) {
    if (rawUs[i] && (int32_t)(now - rawUntil[i]) < 0) pwm.writeMicroseconds(i, (uint16_t)constrain(rawUs[i], 0, 20000));
    else if (rawUs[i]) rawUs[i] = 0, lastCheek = 0xFFFFFFFF;
  }
  if (cur.cheek != lastCheek) {
    lastCheek = cur.cheek;
    const int ch[3] = {CH_CHEEK_R, CH_CHEEK_G, CH_CHEEK_B};
    for (int c = 0; c < 3; c++) {
      if (rawUs[ch[c]]) continue;
      int v = (int)((cur.cheek >> (16 - 8 * c)) & 0xFF) * 16;        // 0..4080 of 4096
      if (cfg.cheekInvert) v = 4095 - v;
      pwm.setPWM(ch[c], 0, (uint16_t)v);
    }
  }
}

bool bodyServoRaw(int channel, int microseconds)
{
  if (channel < 0 || channel > 15) return false;
  rawUs[channel] = microseconds > 0 ? microseconds : 0;
  rawUntil[channel] = millis() + 15000;
  if (!microseconds) lastCheek = 0xFFFFFFFF;
  return servos;
}

bool bodyTrim(int joint, int offsetUs, bool invert)
{
  if (joint < 0 || joint > 4) return false;
  cfg.trimUs[joint] = (int16_t)constrain(offsetUs, -500, 500);
  cfg.sign[joint] = invert ? -1 : 1;
  cfgSave(&cfg, sizeof cfg, BODY_CFG_OFFSET);
  return true;
}

void bodyCheekInvert(bool inverted)
{
  cfg.cheekInvert = inverted ? 1 : 0;
  cfgSave(&cfg, sizeof cfg, BODY_CFG_OFFSET);
  lastCheek = 0xFFFFFFFF;
}

size_t bodyCalibJson(char *dst, size_t n)
{
  return snprintf(dst, n, "\"servos\":%s,\"trim\":[%d,%d,%d,%d,%d],\"invert\":[%d,%d,%d,%d,%d],\"cheek_invert\":%d",
                  servos ? "true" : "false", cfg.trimUs[0], cfg.trimUs[1], cfg.trimUs[2], cfg.trimUs[3], cfg.trimUs[4],
                  cfg.sign[0] < 0, cfg.sign[1] < 0, cfg.sign[2] < 0, cfg.sign[3] < 0, cfg.sign[4] < 0, cfg.cheekInvert);
}

void bodyTick()
{
  uint32_t now = millis();
  if (now - lastTick < TICK_MS) return;
  lastTick = now;
  computeTarget(now);
  const float k = gesture[0] ? 0.45f : 0.18f;
  cur.earL += (target.earL - cur.earL) * k;
  cur.earR += (target.earR - cur.earR) * k;
  cur.pan  += (target.pan  - cur.pan)  * k;
  cur.tilt += (target.tilt - cur.tilt) * k;
  cur.tail += (target.tail - cur.tail) * k;
  cur.cheek = target.cheek;
  writeServos();
}

size_t bodyJson(char *dst, size_t n)
{
  int m = tempMood >= 0 ? tempMood : baseMood;
  if (tempMood < 0 && baseMood != 6 && millis() - lastActivity > SLEEP_AFTER_MS) m = 6;
  return snprintf(dst, n,
    "\"ear_l\":%.0f,\"ear_r\":%.0f,\"pan\":%.0f,\"tilt\":%.0f,\"tail\":%.0f,\"cheek\":\"#%06lx\",\"mood\":\"%s\",\"gesture\":\"%s\",\"servos\":%s",
    cur.earL, cur.earR, cur.pan, cur.tilt, cur.tail, (unsigned long)cur.cheek, MOODS[m].name, gesture, servos ? "true" : "false");
}

bool bodyTakeChange(char *w, size_t n)
{
  if (!dirty) return false;
  dirty = false;
  strncpy(w, why, n - 1); w[n - 1] = 0;
  return true;
}
