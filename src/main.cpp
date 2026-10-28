// room creature firmware v0.6.0: senses, serial + Wi-Fi links, body, Bluetooth setup mode,
// air gestures, chirps on a header speaker, offline event journal in flash.
// expression engine for ears, head, tail and cheeks (phase 3, servos optional).
//
// Board : ST B-L475E-IOT01A (STM32L475VG). Sensors on I2C2 (PB11/PB10),
//         microphones on DFSDM (sound.cpp), Wi-Fi module on SPI3 (link.cpp).
// Output: newline-delimited JSON on the ST-LINK serial port and, once joined,
//         over TCP to the bridge. See docs/protocol.md.
// Input : commands as JSON lines on the serial port, or from the bridge over Wi-Fi
//         (polled every 2 s): hello, ping, status, name, wifi, bridge, express, gesture, look_at,
//         cheek, servo, trim, cheek_invert, calib, record.

#include <Arduino.h>
#include <Wire.h>
#include <math.h>
#include <HTS221Sensor.h>
#include <LPS22HBSensor.h>
#include <LIS3MDLSensor.h>
#include <LSM6DSLSensor.h>
#include <vl53l0x_class.h>
#include "sound.h"
#include "link.h"
#include "body.h"
#include "kws.h"
#include "provision.h"
#include "chirp.h"
#include "journal.h"
#include "hmac_sha256.h"
#include <IWatchdog.h>
#include <malloc.h>

static const char *FW_VERSION = "0.6.0";
static const uint32_t BAUD = 921600;           // fast enough to stream raw audio for training

static const uint32_t FAST_PERIOD_MS = 100;
static const uint32_t STATE_PERIOD_MS = 1000;

static const int   PRESENCE_MM = 1000;
static const int   PRESENCE_ON_TICKS = 3;
static const int   PRESENCE_OFF_TICKS = 20;
static const float MOTION_THRESHOLD_G = 0.015f;
static const int   MOTION_WINDOW = 10;
static const uint32_t MOTION_HOLD_MS = 1500;
static const float CLAP_TILT_MIN = -2.0f;        // spectral tilt below this is not a clap (see kwsSpectralTilt)

TwoWire bus(PB11, PB10);

static void emitEvent(const char *name, const char *extraJson = nullptr);
static void emitHello();

// Command signing: the hub gives this unit a key over the USB cable only; every command that
// arrives over Wi-Fi must then be "S <n> <hmac> <json>" with HMAC-SHA256(key, nonce|n|json) and
// n above the last one seen in this connection. The nonce is fresh for every Wi-Fi connection.
struct UnitKey { uint32_t magic; uint8_t key[32]; };
static const uint32_t UNITKEY_MAGIC = 0x4B455931, UNITKEY_OFFSET = 768;
static UnitKey unitKey;
static bool keyed = false;
static char wifiNonce[17] = "";
static uint32_t lastCmdN = 0;
static bool cmdFromSerial = false;

HTS221Sensor  hts(&bus);
LPS22HBSensor lps(&bus);
LIS3MDLSensor mag(&bus);
LSM6DSLSensor imu(&bus, LSM6DSL_ACC_GYRO_I2C_ADDRESS_LOW);
VL53L0X       tof(&bus, PC6);

static bool haveHts = false, haveLps = false, haveMag = false, haveImu = false, haveTof = false, haveMic = false;

struct State {
  float temp_c = NAN, hum_pct = NAN, press_hpa = NAN, heading_deg = -1;
  int   tof_mm = -1;
  int   motion = 0;
} st;

static float    accMag[MOTION_WINDOW];
static int      accIdx = 0, accCount = 0;
static uint32_t lastMovingMs = 0;
static bool     wasMoving = false;

// touch and handling: gravity direction (low-passed) tells face-down, pick-up and set-down; the
// 1 s accel spread tells a shake
static float    gLP[3] = {0, 0, 1000};         // mg
static float    restVec[3] = {0, 0, 1000};     // gravity when last at rest
static bool     faceDown = false, carried = false;
static uint32_t faceDownSince = 0, movingSince = 0, lastShakeMs = 0;

static float angleBetween(const float *a, const float *b)
{
  float dot = a[0]*b[0] + a[1]*b[1] + a[2]*b[2];
  float na = sqrtf(a[0]*a[0] + a[1]*a[1] + a[2]*a[2]), nb = sqrtf(b[0]*b[0] + b[1]*b[1] + b[2]*b[2]);
  float c = dot / (na * nb + 1e-6f); if (c > 1) c = 1; if (c < -1) c = -1;
  return acosf(c) * 180.0f / (float)M_PI;
}

static void handlingSample(const int32_t *a, float sd, bool moving)
{
  uint32_t now = millis();
  for (int i = 0; i < 3; i++) gLP[i] += 0.15f * ((float)a[i] - gLP[i]);

  // shaken: a lot of spread in 1 s
  if (sd > 0.35f && now - lastShakeMs > 3000) {
    lastShakeMs = now;
    emitEvent("shaken");
    bodyExpress("surprised"); chirpPlay("no");
  }

  // face down (z points down): sleep
  bool down = gLP[2] < -700.0f;
  if (down && !faceDown) { if (!faceDownSince) faceDownSince = now; else if (now - faceDownSince > 2000) { faceDown = true; emitEvent("flipped"); bodyExpress("sleepy"); chirpPlay("sleepy"); } }
  else if (!down) { faceDownSince = 0; if (faceDown) { faceDown = false; emitEvent("upright"); bodyExpress("neutral"); } }

  // picked up: moving for 1.5 s with the gravity direction well away from the resting one; set down: still again
  if (moving) { if (!movingSince) movingSince = now; }
  else movingSince = 0;
  static bool restInit = false;
  if (!restInit && now > 3000) { for (int i = 0; i < 3; i++) restVec[i] = gLP[i]; restInit = true; }
  if (!carried && restInit && movingSince && now - movingSince > 1500 && angleBetween(gLP, restVec) > 15.0f) {
    carried = true;
    emitEvent("picked_up");
    bodyExpress("alert");
  } else if (carried && !moving && now - lastMovingMs > 2000) {
    carried = false;
    for (int i = 0; i < 3; i++) restVec[i] = gLP[i];
    char extra[40]; snprintf(extra, sizeof extra, "\"tilt_deg\":%.0f", angleBetween(gLP, restVec));
    emitEvent("set_down", extra);
    bodyExpress("pleased"); bodyGesture("wag");
  }
}

static bool presence = false;
static int  nearTicks = 0, farTicks = 0;
static const int PRESENCE_ON_TICKS_SLOW = 8;        // 0.8 s: a hand passing is not a person arriving

// air gestures: a hand crossing the beam briefly (swipe) or approaching close and withdrawing (tap)
static int  handTicks = 0, handMin = 9999; static uint32_t handStart = 0;
static int  moodCycle = 0;

static void gestureSample(int mm)
{
  bool hand = mm > 0 && mm < 600;
  if (hand) {
    if (handTicks == 0) { handStart = millis(); handMin = mm; }
    handTicks++; if (mm < handMin) handMin = mm;
    return;
  }
  if (handTicks == 0) return;
  uint32_t dur = millis() - handStart;
  int ticks = handTicks; handTicks = 0;
  if (presence) return;                                 // someone is standing there: no gestures
  if (ticks >= 1 && dur <= 500) {
    const char *kind = handMin < 250 ? "tap" : "swipe";
    char extra[40]; snprintf(extra, sizeof extra, "\"kind\":\"%s\",\"mm\":%d", kind, handMin);
    emitEvent("gesture", extra);
    if (!strcmp(kind, "tap")) { bodyGesture("nod"); chirpPlay("ok"); }
    else {
      static const char *cycle[] = {"curious", "pleased", "alert", "neutral"};
      bodyExpress(cycle[moodCycle++ % 4]); chirpPlay("happy");
    }
  }
}
static bool wasConnected = false;
static bool setupMode = false;

static void enterSetup(const char *why)
{
  if (provisionBegin()) {
    setupMode = true;
    bodyCheek(0x9b59ff);                       // violet: setup mode
    char extra[40]; snprintf(extra, sizeof extra, "\"why\":\"%s\"", why);
    emitEvent("setup_mode", extra);
  } else {
    emitEvent("error", "\"what\":\"bluetooth module not found\"");
  }
}

static void rebootSoon(const char *why)
{
  // Wi-Fi after Bluetooth on the shared SPI bus does not come back cleanly: restart instead
  char extra[40]; snprintf(extra, sizeof extra, "\"why\":\"%s\"", why);
  emitEvent("restart", extra);
  Serial.flush();
  delay(300);
  NVIC_SystemReset();
}

static void leaveSetup()
{
  provisionEnd();
  setupMode = false;
  emitEvent("setup_done");
  rebootSoon("setup_done");
}

// health: boot counter in flash, reset cause, free RAM, link reconnects
struct HealthConfig { uint32_t magic; uint32_t boots; uint32_t watchdogResets; uint32_t ackedSeq; };
static bool healthDirty = false; static uint32_t lastHealthSave = 0;
static const uint32_t HEALTH_MAGIC = 0x48454131, HEALTH_OFFSET = 512;
static HealthConfig health;
static uint32_t ackedSeq = 0;           // highest event seq the bridge has confirmed (persisted in health)
static const char *resetCause = "power";
static uint32_t wifiReconnects = 0;

static uint32_t freeRam()
{
  extern char _end;                                   // end of .bss, from the linker script
  char here;
  struct mallinfo mi = mallinfo();
  return (uint32_t)(&here - &_end) - (uint32_t)mi.uordblks;   // stack pointer minus heap in use
}

static void healthBegin()
{
  if (__HAL_RCC_GET_FLAG(RCC_FLAG_IWDGRST)) resetCause = "watchdog";
  else if (__HAL_RCC_GET_FLAG(RCC_FLAG_SFTRST)) resetCause = "software";
  else if (__HAL_RCC_GET_FLAG(RCC_FLAG_PINRST)) resetCause = "pin";
  __HAL_RCC_CLEAR_RESET_FLAGS();
  cfgLoad(&health, sizeof health, HEALTH_OFFSET);
  if (health.magic != HEALTH_MAGIC) { memset(&health, 0, sizeof health); health.magic = HEALTH_MAGIC; }
  if (health.ackedSeq == 0xFFFFFFFFu) health.ackedSeq = 0;      // field added later: erased flash reads as all ones
  health.boots++;
  if (!strcmp(resetCause, "watchdog")) health.watchdogResets++;
  cfgSave(&health, sizeof health, HEALTH_OFFSET);
  ackedSeq = health.ackedSeq;
}

// output: every line goes to the serial port and, when up, to the bridge
static char line[800];

// snprintf returns the length it wanted, so clamp before using it as an offset
static size_t room(int n) { return n < 0 ? 0 : ((size_t)n >= sizeof line ? sizeof line - 1 : (size_t)n); }

static uint32_t lastAckMs = 0;

static void out()
{
  Serial.println(line);
  linkSend(line);
}

// replay unacknowledged events older than 10 s once the link is up, oldest first
static void replayJournal()
{
  static uint32_t lastTry = 0, lastReplayed = 0, lastAckSeen = 0, ackStallSince = 0;
  if (!linkConnected() || millis() - lastTry < 1000) return;
  lastTry = millis();
  if (ackedSeq != lastAckSeen) { lastAckSeen = ackedSeq; ackStallSince = millis(); }
  else if (lastReplayed > ackedSeq && millis() - ackStallSince > 60000) {      // acks stalled: replay again from the last confirmed seq
    lastReplayed = ackedSeq; ackStallSince = millis();
  }
  char text[120]; uint32_t t, boot, seq;
  uint32_t skip = ackedSeq > lastReplayed ? ackedSeq : lastReplayed;
  for (int i = 0; i < 3 && journalNext(text, sizeof text, &t, &boot, &seq, skip); i++) {
    if (journalFromThisBoot(boot) && millis() - t < 10000) return;      // still in flight; give the ack a chance
    size_t len = strlen(text);
    if (len < 2 || text[len - 1] != '}') { lastReplayed = seq; skip = seq; continue; }
    text[len - 1] = 0;
    long age = journalFromThisBoot(boot) ? (long)((millis() - t) / 1000) : -1;
    snprintf(line, sizeof line, "%s,\"late\":true,\"age_s\":%ld}", text, age);
    if (!linkSend(line)) return;
    lastReplayed = seq; skip = seq;
  }
  if (lastReplayed <= ackedSeq) lastReplayed = ackedSeq;
}

// Every event worth keeping gets a sequence number and goes into the flash journal first;
// the bridge acknowledges what it has seen and anything unacknowledged is replayed later.
static void emitEvent(const char *name, const char *extraJson)
{
  bool keep = strcmp(name, "wifi_cmd") && strcmp(name, "error");
  uint32_t seq = keep ? journalLastSeq() + 1 : 0;
  snprintf(line, sizeof line, "{\"type\":\"event\",\"t\":%lu,\"seq\":%lu,\"name\":\"%s\"%s%s}",
           (unsigned long)millis(), (unsigned long)seq, name, extraJson ? "," : "", extraJson ? extraJson : "");
  if (keep) journalWrite(line, millis());
  out();
}

static const char *helloAuth()
{
  static char hex[65];
  if (!keyed || !wifiNonce[0]) { hex[0] = 0; return hex; }
  const char *tag = "hello|";
  const void *parts[4] = {tag, wifiNonce, "|", linkCfg.unit};
  size_t lens[4] = {strlen(tag), strlen(wifiNonce), 1, strlen(linkCfg.unit)};
  uint8_t mac[32];
  hmacSha256(unitKey.key, 32, parts, lens, 4, mac);
  toHex(mac, 32, hex);
  return hex;
}

static void freshNonce()
{
  Sha256 h; sha256Init(h);
  uint32_t seed[6] = {health.boots, wifiReconnects, (uint32_t)micros(), HAL_GetUIDw0(), HAL_GetUIDw1(), HAL_GetUIDw2()};
  sha256Update(h, seed, sizeof seed);
  uint8_t d[32]; sha256Final(h, d);
  toHex(d, 8, wifiNonce);
  lastCmdN = 0;
}

// Returns the JSON command inside a signed line, or nullptr (and reports why) when it must be dropped.
static const char *verifySigned(char *lineIn)
{
  if (!keyed) return lineIn;                                   // not provisioned yet: as before
  if (lineIn[0] != 'S' || lineIn[1] != ' ') { emitEvent("error", "\"what\":\"unsigned command\""); return nullptr; }
  char *p = lineIn + 2;
  char *end;
  unsigned long n = strtoul(p, &end, 10);
  if (end == p || *end != ' ') { emitEvent("error", "\"what\":\"bad signed line\""); return nullptr; }
  p = end + 1;
  if (strlen(p) < 66 || p[64] != ' ') { emitEvent("error", "\"what\":\"bad signed line\""); return nullptr; }
  uint8_t sig[32];
  if (!fromHex(p, sig, 32)) { emitEvent("error", "\"what\":\"bad signed line\""); return nullptr; }
  const char *json = p + 65;
  char nbuf[12]; snprintf(nbuf, sizeof nbuf, "%lu", n);
  const void *parts[5] = {wifiNonce, "|", nbuf, "|", json};
  size_t lens[5] = {strlen(wifiNonce), 1, strlen(nbuf), 1, strlen(json)};
  uint8_t want[32];
  hmacSha256(unitKey.key, 32, parts, lens, 5, want);
  if (!equalCt(sig, want, 32)) { emitEvent("error", "\"what\":\"bad signature\""); return nullptr; }
  if (n <= lastCmdN) { emitEvent("error", "\"what\":\"replayed command\""); return nullptr; }
  lastCmdN = n;
  return json;
}

static void emitHello()
{
  char ip[20]; linkIp(ip, sizeof ip);
  snprintf(line, sizeof line,
           "{\"type\":\"hello\",\"unit\":\"%s\",\"fw\":\"%s\",\"sensors\":[%s%s%s%s%s%s],"
           "\"wifi\":{\"module\":\"%s\",\"ssid\":\"%s\",\"joined\":%s,\"ip\":\"%s\",\"bridge\":%s},\"acked\":%lu,\"last_seq\":%lu,"
           "\"keyed\":%s,\"nonce\":\"%s\",\"auth\":\"%s\"}",
           linkCfg.unit, FW_VERSION,
           haveHts ? "\"hts221\"," : "", haveLps ? "\"lps22hb\"," : "", haveTof ? "\"vl53l0x\"," : "",
           haveImu ? "\"lsm6dsl\"," : "", haveMag ? "\"lis3mdl\"," : "", haveMic ? "\"mp34dt01x2\"" : "\"\"",
           linkModuleFw(), linkCfg.ssid, linkJoined() ? "true" : "false", ip, linkConnected() ? "true" : "false",
           (unsigned long)ackedSeq, (unsigned long)journalLastSeq(),
           keyed ? "true" : "false", wifiNonce, helloAuth());
  // tidy the sensors list if the mic is missing: ["a","b",""] -> drop the trailing empty string
  char *p = strstr(line, ",\"\"]"); if (p) { memmove(p, p + 3, strlen(p + 3) + 1); }
  p = strstr(line, "[\"\"]"); if (p) { memmove(p + 1, p + 3, strlen(p + 3) + 1); }
  out();
}

static int fmtNum(char *dst, size_t n, const char *key, float v, int decimals)
{
  if (isnan(v)) return snprintf(dst, n, "\"%s\":null,", key);
  return snprintf(dst, n, "\"%s\":%.*f,", key, decimals, v);
}

static void emitState()
{
  size_t n = room(snprintf(line, sizeof line, "{\"type\":\"state\",\"t\":%lu,", (unsigned long)millis()));
  n = room(n + fmtNum(line + n, sizeof line - n, "temp_c", st.temp_c, 2));
  n = room(n + fmtNum(line + n, sizeof line - n, "hum_pct", st.hum_pct, 1));
  n = room(n + fmtNum(line + n, sizeof line - n, "press_hpa", st.press_hpa, 2));
  n = room(n + snprintf(line + n, sizeof line - n, "\"tof_mm\":%d,", st.tof_mm));
  n = room(n + fmtNum(line + n, sizeof line - n, "heading_deg", st.heading_deg, 1));
  n = room(n + snprintf(line + n, sizeof line - n, "\"motion\":%d", st.motion));
  if (haveMic) n = room(n + snprintf(line + n, sizeof line - n, ",\"sound_db\":%.1f,\"sound_dir\":%.2f", soundLevelDb(), soundDirection()));
  if (linkJoined()) n = room(n + snprintf(line + n, sizeof line - n, ",\"rssi\":%d", linkRssi()));
  n = room(n + snprintf(line + n, sizeof line - n, ",\"health\":{\"uptime_s\":%lu,\"boots\":%lu,\"wd_resets\":%lu,\"reset\":\"%s\",\"free_ram\":%lu,\"wifi_reconnects\":%lu,\"journal\":%lu}",
                        (unsigned long)(millis() / 1000), (unsigned long)health.boots, (unsigned long)health.watchdogResets,
                        resetCause, (unsigned long)freeRam(), (unsigned long)wifiReconnects, (unsigned long)journalPending()));
  n = room(n + snprintf(line + n, sizeof line - n, ",\"body\":{"));
  n = room(n + bodyJson(line + n, sizeof line - n));
  snprintf(line + n, sizeof line - n, "}}");
  out();
}

static void emitBody(const char *why)
{
  size_t n = room(snprintf(line, sizeof line, "{\"type\":\"body\",\"t\":%lu,", (unsigned long)millis()));
  n = room(n + bodyJson(line + n, sizeof line - n));
  snprintf(line + n, sizeof line - n, ",\"why\":\"%s\"}", why);
  out();
}

static void emitStatus()
{
  char ip[20]; linkIp(ip, sizeof ip);
  snprintf(line, sizeof line,
           "{\"type\":\"status\",\"t\":%lu,\"unit\":\"%s\",\"ssid\":\"%s\",\"joined\":%s,\"ip\":\"%s\",\"rssi\":%d,"
           "\"bridge_host\":\"%s\",\"bridge_port\":%u,\"bridge\":%s}",
           (unsigned long)millis(), linkCfg.unit, linkCfg.ssid, linkJoined() ? "true" : "false", ip, linkRssi(),
           linkCfg.host, (unsigned)(linkCfg.port ? linkCfg.port : 8778), linkConnected() ? "true" : "false");
  out();
}

static void emitCalib()
{
  size_t n = room(snprintf(line, sizeof line, "{\"type\":\"calib\",\"t\":%lu,", (unsigned long)millis()));
  n = room(n + bodyCalibJson(line + n, sizeof line - n));
  snprintf(line + n, sizeof line - n, "}");
  out();
}

// raw audio out: base64 lines of 256 samples (512 bytes), streamed while recording
static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static uint32_t capSeq = 0;

static void pumpCapture()
{
  static int16_t chunk[256];
  static uint32_t have = 0;
  for (int rounds = 0; rounds < 16; rounds++) {      // drain everything the ring has; audio arrives at 78 chunks/s
  if (!soundCaptureActive() && have == 0) { capSeq = 0; return; }
  have += soundCaptureRead(chunk + have, 256 - have);
  bool last = !soundCaptureActive();
  if (have < 256 && !last) return;
  if (have == 0) { capSeq = 0; return; }
  uint32_t of = (soundCaptureTotal() + 255) / 256;
  const uint8_t *bytes = (const uint8_t *)chunk; uint32_t len = have * 2;
  size_t p = room(snprintf(line, sizeof line, "{\"type\":\"audio\",\"seq\":%lu,\"of\":%lu,\"rate\":%lu,\"dropped\":%lu,\"b64\":\"",
                           (unsigned long)capSeq, (unsigned long)of, (unsigned long)soundSampleRate(), (unsigned long)soundCaptureDropped()));
  for (uint32_t i = 0; i < len && p + 5 < sizeof line; i += 3) {
    uint32_t v = bytes[i] << 16 | (i + 1 < len ? bytes[i + 1] : 0) << 8 | (i + 2 < len ? bytes[i + 2] : 0);
    line[p++] = B64[(v >> 18) & 63]; line[p++] = B64[(v >> 12) & 63];
    line[p++] = i + 1 < len ? B64[(v >> 6) & 63] : '=';
    line[p++] = i + 2 < len ? B64[v & 63] : '=';
  }
  snprintf(line + p, sizeof line - p, "\"}");
  Serial.println(line);                 // training clips go over the cable only
  capSeq++; have = 0;
  if (last) { capSeq = 0; return; }
  }
}

// sensors
static void initSensors()
{
  uint8_t id = 0;
  hts.begin();
  if (hts.ReadID(&id) == HTS221_STATUS_OK && id == 0xBC) { hts.Enable(); haveHts = true; }
  id = 0; lps.begin();
  if (lps.ReadID(&id) == LPS22HB_STATUS_OK && id == 0xB1) { lps.Enable(); haveLps = true; }
  id = 0; mag.begin();
  if (mag.ReadID(&id) == LIS3MDL_STATUS_OK && id == 0x3D) { mag.Enable(); haveMag = true; }
  id = 0; imu.begin();
  if (imu.ReadID(&id) == LSM6DSL_STATUS_OK && id == 0x6A) {
    imu.Set_X_FS(2.0f); imu.Set_X_ODR(104.0f); imu.Enable_X();
    imu.Enable_Single_Tap_Detection();
    haveImu = true;
  }
  tof.begin(); tof.VL53L0X_Off();
  if (tof.InitSensor(0x10) == 0) haveTof = true;
  haveMic = soundBegin();
  kwsBegin();
}

static void readFast()
{
  if (haveTof) {
    uint32_t mm = 0;
    int status = tof.GetDistance(&mm);
    st.tof_mm = (status == 0 && mm > 0 && mm < 2000) ? (int)mm : -1;
    gestureSample(st.tof_mm);
    bool near = st.tof_mm > 0 && st.tof_mm < PRESENCE_MM;
    if (near) { nearTicks++; farTicks = 0; } else { farTicks++; nearTicks = 0; }
    if (!presence && nearTicks >= PRESENCE_ON_TICKS_SLOW) {
      presence = true;
      char extra[24]; snprintf(extra, sizeof extra, "\"mm\":%d", st.tof_mm);
      emitEvent("someone_in_front", extra);
      bodyOnPresence(true);
    } else if (presence && farTicks >= PRESENCE_OFF_TICKS) {
      presence = false;
      emitEvent("someone_left");
      bodyOnPresence(false);
    }
  }
  if (haveImu) {
    int32_t a[3];
    if (imu.Get_X_Axes(a) == LSM6DSL_STATUS_OK) {
      float g = sqrtf((float)a[0]*a[0] + (float)a[1]*a[1] + (float)a[2]*a[2]) / 1000.0f;
      accMag[accIdx] = g; accIdx = (accIdx + 1) % MOTION_WINDOW;
      if (accCount < MOTION_WINDOW) accCount++;
      if (accCount == MOTION_WINDOW) {
        float mean = 0; for (int i = 0; i < MOTION_WINDOW; i++) mean += accMag[i];
        mean /= MOTION_WINDOW;
        float var = 0; for (int i = 0; i < MOTION_WINDOW; i++) { float d = accMag[i] - mean; var += d*d; }
        float sd = sqrtf(var / MOTION_WINDOW);
        uint32_t now = millis();
        if (sd > MOTION_THRESHOLD_G) lastMovingMs = now;
        bool moving = (now - lastMovingMs) < MOTION_HOLD_MS && lastMovingMs != 0;
        st.motion = moving ? 1 : 0;
        if (moving && !wasMoving) emitEvent("moved");
        wasMoving = moving;
        handlingSample(a, sd, moving);
      }
    }
    LSM6DSL_Event_Status_t ev;
    if (imu.Get_Event_Status(&ev) == LSM6DSL_STATUS_OK && ev.TapStatus) { emitEvent("knock"); bodyOnKnock(); chirpPlay(presence ? "purr" : "alert"); }
  }
}

static void readSlow()
{
  float v;
  if (haveHts) {
    if (hts.GetTemperature(&v) == HTS221_STATUS_OK) st.temp_c = v;
    if (hts.GetHumidity(&v) == HTS221_STATUS_OK) st.hum_pct = v;
  }
  if (haveLps && lps.GetPressure(&v) == LPS22HB_STATUS_OK) st.press_hpa = v;
  if (haveMag) {
    int32_t m[3];
    if (mag.GetAxes(m) == LIS3MDL_STATUS_OK) {
      float h = atan2f((float)m[1], (float)m[0]) * 180.0f / (float)M_PI;
      if (h < 0) h += 360.0f;
      st.heading_deg = h;
    }
  }
}

// commands (serial only)
static bool jsonStr(const char *src, const char *key, char *dst, size_t n)
{
  char pat[32]; snprintf(pat, sizeof pat, "\"%s\"", key);
  const char *p = strstr(src, pat);
  if (!p) return false;
  p = strchr(p + strlen(pat), ':'); if (!p) return false;
  p = strchr(p, '"'); if (!p) return false;
  p++;
  size_t i = 0;
  while (*p && *p != '"' && i < n - 1) {
    if (*p == '\\' && p[1]) p++;
    dst[i++] = *p++;
  }
  dst[i] = 0;
  return true;
}

static int jsonInt(const char *src, const char *key, int dflt)
{
  char pat[32]; snprintf(pat, sizeof pat, "\"%s\"", key);
  const char *p = strstr(src, pat);
  if (!p) return dflt;
  p = strchr(p + strlen(pat), ':'); if (!p) return dflt;
  return atoi(p + 1);
}

static void handleCommand(const char *cmdLine)
{
  char cmd[16];
  if (!jsonStr(cmdLine, "cmd", cmd, sizeof cmd)) return;
  if (!strcmp(cmd, "hello")) { emitHello(); return; }
  if (!strcmp(cmd, "status")) { emitStatus(); return; }
  if (!strcmp(cmd, "ping")) {
    snprintf(line, sizeof line, "{\"type\":\"pong\",\"t\":%lu}", (unsigned long)millis()); out(); return;
  }
  if (!strcmp(cmd, "name")) {
    char unit[24];
    if ((jsonStr(cmdLine, "name", unit, sizeof unit) || jsonStr(cmdLine, "unit", unit, sizeof unit)) && unit[0]) {
      linkSetUnit(unit); linkSave(); emitHello();
    }
    return;
  }
  if (!strcmp(cmd, "wifi")) {
    char ssid[33] = "", pass[64] = "";
    jsonStr(cmdLine, "ssid", ssid, sizeof ssid);
    jsonStr(cmdLine, "pass", pass, sizeof pass);
    linkSetWifi(ssid, pass); linkSave();
    emitStatus();
    linkPoll();                 // joins now (blocks a few seconds)
    emitStatus();
    return;
  }
  if (!strcmp(cmd, "express")) {
    char mood[16] = "";
    jsonStr(cmdLine, "mood", mood, sizeof mood);
    if (!bodyExpress(mood)) emitEvent("error", "\"what\":\"unknown mood\"");
    return;
  }
  if (!strcmp(cmd, "gesture")) {
    char g[12] = "";
    jsonStr(cmdLine, "name", g, sizeof g);
    if (!bodyGesture(g)) emitEvent("error", "\"what\":\"unknown gesture\"");
    return;
  }
  if (!strcmp(cmd, "look_at")) {
    bodyLookAt((float)jsonInt(cmdLine, "pan", 0), (float)jsonInt(cmdLine, "tilt", 0), 10000);
    return;
  }
  if (!strcmp(cmd, "cheek")) {
    char c[10] = "";
    if (jsonStr(cmdLine, "color", c, sizeof c)) bodyCheek((uint32_t)strtoul(c[0] == '#' ? c + 1 : c, nullptr, 16));
    return;
  }
  if (!strcmp(cmd, "servo")) {
    bool ok = bodyServoRaw(jsonInt(cmdLine, "ch", -1), jsonInt(cmdLine, "us", 0));
    if (!ok) emitEvent("error", "\"what\":\"no servo driver or bad channel\"");
    return;
  }
  if (!strcmp(cmd, "trim")) {
    static const char *names[5] = {"ear_l", "ear_r", "pan", "tilt", "tail"};
    char j[8] = ""; jsonStr(cmdLine, "joint", j, sizeof j);
    int idx = jsonInt(cmdLine, "joint", -1);
    for (int i = 0; i < 5; i++) if (!strcmp(j, names[i])) idx = i;
    if (!bodyTrim(idx, jsonInt(cmdLine, "us", 0), jsonInt(cmdLine, "invert", 0) != 0)) emitEvent("error", "\"what\":\"bad joint\"");
    else emitCalib();
    return;
  }
  if (!strcmp(cmd, "cheek_invert")) { bodyCheekInvert(jsonInt(cmdLine, "value", 0) != 0); emitCalib(); return; }
  if (!strcmp(cmd, "calib")) { emitCalib(); return; }
  if (!strcmp(cmd, "features")) {          // debug: one frame of the live log-mel window
    int f = jsonInt(cmdLine, "frame", 63);
    size_t n = room(snprintf(line, sizeof line, "{\"type\":\"features\",\"frame\":%d,\"mel\":", f));
    n = room(n + kwsFeaturesJson(line + n, sizeof line - n, f));
    snprintf(line + n, sizeof line - n, "}");
    out();
    return;
  }
  if (!strcmp(cmd, "scores")) {
    size_t n = room(snprintf(line, sizeof line, "{\"type\":\"scores\",\"model\":%s,\"scores\":", kwsHasModel() ? "true" : "false"));
    n = room(n + kwsScoresJson(line + n, sizeof line - n));
    snprintf(line + n, sizeof line - n, "}");
    out();
    return;
  }
  if (!strcmp(cmd, "record")) {
    int ms = jsonInt(cmdLine, "ms", 1000);
    if (!haveMic || !soundCaptureStart((uint32_t)ms)) emitEvent("error", "\"what\":\"record busy or no mic\"");
    return;
  }
  if (!strcmp(cmd, "scan")) {                    // Wi-Fi networks in range (blocks a few seconds)
    if (setupMode) { emitEvent("error", "\"what\":\"no Wi-Fi scan while Bluetooth is up\""); return; }
    int n = linkScanRobust();
    size_t p = room(snprintf(line, sizeof line, "{\"type\":\"scan\",\"n\":%d,\"networks\":[", n));
    for (int i = 0; i < n && i < 12 && p + 60 < sizeof line; i++) {
      char ssid[40]; int rssi; bool sec;
      if (!linkScanEntry(i, ssid, sizeof ssid, &rssi, &sec)) break;
      p = room(p + snprintf(line + p, sizeof line - p, "%s{\"ssid\":\"%s\",\"rssi\":%d,\"secured\":%d}", i ? "," : "", ssid, rssi, sec ? 1 : 0));
    }
    snprintf(line + p, sizeof line - p, "]}");
    out();
    return;
  }
  if (!strcmp(cmd, "ack")) {                     // the bridge has seen our events up to seq
    uint32_t seq = (uint32_t)jsonInt(cmdLine, "seq", 0);
    if (seq > ackedSeq) { ackedSeq = seq; journalAck(seq); health.ackedSeq = seq; healthDirty = true; }
    lastAckMs = millis();
    return;
  }
  if (!strcmp(cmd, "chirp")) {
    char nm[12] = ""; jsonStr(cmdLine, "name", nm, sizeof nm);
    if (!chirpPlay(nm)) emitEvent("error", "\"what\":\"unknown chirp\"");
    return;
  }
  if (!strcmp(cmd, "journal_dump")) {
    size_t p = room(snprintf(line, sizeof line, "{\"type\":\"journal_dump\",\"records\":"));
    p = room(p + journalDump((uint32_t)jsonInt(cmdLine, "from", 0), line + p, sizeof line - p));
    snprintf(line + p, sizeof line - p, "}");
    out();
    return;
  }
  if (!strcmp(cmd, "journal")) {
    char text[120]; uint32_t t = 0, boot = 0, seq = 0; bool found = journalNext(text, sizeof text, &t, &boot, &seq, ackedSeq);
    snprintf(line, sizeof line, "{\"type\":\"journal\",\"pending\":%lu,\"dropped\":%lu,\"acked\":%lu,\"last_seq\":%lu,\"next\":%s,\"next_seq\":%lu,\"next_age_s\":%ld,\"same_boot\":%s}",
             (unsigned long)journalPending(), (unsigned long)journalDropped(), (unsigned long)ackedSeq, (unsigned long)journalLastSeq(),
             found ? "true" : "false", (unsigned long)seq, found ? (long)((millis() - t) / 1000) : -1L, found && journalFromThisBoot(boot) ? "true" : "false");
    out();
    return;
  }
  if (!strcmp(cmd, "set_key")) {                 // only over the USB cable, never over Wi-Fi
    char hex[65] = "";
    if (!cmdFromSerial) { emitEvent("error", "\"what\":\"set_key needs the cable\""); return; }
    if (!jsonStr(cmdLine, "key", hex, sizeof hex) || strlen(hex) != 64 || !fromHex(hex, unitKey.key, 32)) {
      emitEvent("error", "\"what\":\"bad key\""); return;
    }
    unitKey.magic = UNITKEY_MAGIC; cfgSave(&unitKey, sizeof unitKey, UNITKEY_OFFSET); keyed = true;
    emitEvent("keyed");
    emitHello();
    return;
  }
  if (!strcmp(cmd, "restart")) { rebootSoon("command"); return; }
  if (!strcmp(cmd, "forget_wifi")) {            // clear the stored network and go into setup mode
    linkSetWifi("", ""); linkSave();
    rebootSoon("forget_wifi");
    return;
  }
  if (!strcmp(cmd, "provision")) {
    if (jsonInt(cmdLine, "on", 1)) { if (!setupMode) enterSetup("command"); }
    else if (setupMode) { provisionEnd(); setupMode = false; emitEvent("setup_cancelled"); rebootSoon("setup_cancelled"); }
    return;
  }
  if (!strcmp(cmd, "bridge")) {
    char host[40] = "";
    jsonStr(cmdLine, "host", host, sizeof host);
    linkSetBridge(host, (uint16_t)jsonInt(cmdLine, "port", 0)); linkSave();
    linkPoll();
    emitStatus();
    return;
  }
}

static void pollSerial()
{
  static char buf[200];
  static size_t len = 0;
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      if (len) { buf[len] = 0; cmdFromSerial = true; handleCommand(buf); cmdFromSerial = false; len = 0; }
    } else if (len < sizeof buf - 1) {
      buf[len++] = c;
    } else {
      len = 0;
    }
  }
}

void setup()
{
  Serial.begin(BAUD);
  pinMode(LED_BUILTIN, OUTPUT);
  pinMode(LED2, OUTPUT);
  bus.begin();
  bus.setClock(400000);
  delay(100);
  initSensors();
  bodyBegin();
  chirpBegin();
  healthBegin();
  cfgLoad(&unitKey, sizeof unitKey, UNITKEY_OFFSET);
  keyed = unitKey.magic == UNITKEY_MAGIC;
  journalBegin(health.boots, health.ackedSeq);  // boot counter tells this boot's records apart; acked seq survives reboots
  pinMode(USER_BTN, INPUT);
  bool buttonHeld = digitalRead(USER_BTN) == LOW;   // blue button held during boot
  if (buttonHeld) { uint32_t t0 = millis(); while (digitalRead(USER_BTN) == LOW && millis() - t0 < 3000) delay(10); buttonHeld = millis() - t0 >= 3000; }
  linkBegin(!buttonHeld);                       // button held: no join attempt, the module stays fresh for the scan
  if (buttonHeld || !linkCfg.ssid[0]) enterSetup(buttonHeld ? "button" : "no_network");
  wasConnected = linkConnected();
  freshNonce();                                 // also for the connection made during startup
  emitHello();
  { char extra[40]; snprintf(extra, sizeof extra, "\"reset\":\"%s\",\"boots\":%lu", resetCause, (unsigned long)health.boots); emitEvent("boot", extra); }
  IWatchdog.begin(32000000);            // 32 s: longer than any blocking Wi-Fi join or connect
}

void loop()
{
  static uint32_t nextFast = 0, nextState = 0, lastBlink = 0;
  uint32_t now = millis();

  IWatchdog.reload();
  if (healthDirty && millis() - lastHealthSave > 60000) {   // persist the acknowledged seq at most once a minute
    healthDirty = false; lastHealthSave = millis(); cfgSave(&health, sizeof health, HEALTH_OFFSET);
  }
  {                                              // blue button: a short press opens pairing on the hub
    static bool wasDown = false; static uint32_t downAt = 0, lastPress = 0;
    bool down = digitalRead(USER_BTN) == LOW;
    if (down && !wasDown) downAt = now;
    if (!down && wasDown && now - downAt >= 30 && now - downAt < 2000 && now - lastPress > 1000) {
      lastPress = now;
      emitEvent("button");
      bodyGesture("perk"); bodyCheek(0x6ea8ff); chirpPlay("ok");
    }
    wasDown = down;
  }
  pollSerial();
  if (setupMode) {
    provisionPoll();
    if (provisionTakeIdentify()) { bodyGesture("wag"); bodyCheek(0xffffff); chirpPlay("hello"); emitEvent("identify"); }
    { char n[96]; if (provisionTakeNote(n, sizeof n)) emitEvent("setup", n); }
    if (provisionDone()) leaveSetup();
  } else {
    linkPoll();
    replayJournal();
    if (linkConnected() && lastAckMs && millis() - lastAckMs > 45000) {   // bridge silent: the link is dead even if writes "succeed"
      lastAckMs = 0;
      linkStop();
      emitEvent("wifi_stale");
    }
  }
  chirpTick();
  { static char wifiCmd[200];
    if (!setupMode && !soundCaptureActive() && linkReadLine(wifiCmd, sizeof wifiCmd)) {   // the poll stalls 300 ms; not while recording
      const char *json = verifySigned(wifiCmd);
      if (json) {
        if (!strstr(json, "\"ack\"")) { char extra[24]; snprintf(extra, sizeof extra, "\"len\":%u", (unsigned)strlen(json)); emitEvent("wifi_cmd", extra); }
        handleCommand(json);
      }
    } }
  if (linkConnected() != wasConnected) {
    wasConnected = linkConnected();
    if (wasConnected) { wifiReconnects++; freshNonce(); emitHello(); lastAckMs = millis(); }   // the bridge learns our name over the new link
    emitEvent(wasConnected ? "wifi_connected" : "wifi_disconnected");
    if (wasConnected) chirpPlay("ok");
  }

  if (haveMic) {
    int ev = soundTakeEvents();
    if (ev & SOUND_CLAP) {
      // a clap is broadband; door thuds and clicks are low-frequency. Gate on the spectral tilt
      // of the last 150 ms (log units: hands ~ -1, thuds ~ -4). Rejections are reported for tuning.
      float tilt = kwsSpectralTilt(12);
      char extra[48]; snprintf(extra, sizeof extra, "\"dir\":%.2f,\"tilt\":%.2f", soundDirection(), tilt);
      if (tilt >= CLAP_TILT_MIN) { emitEvent("clap", extra); bodyOnClap(soundDirection()); }
      else emitEvent("clap_rejected", extra);
    }
    bodyOnSound(soundDirection(), soundLevelDb() > 38.0f);
    if (ev & SOUND_STARTED) emitEvent("sound_started");
    if (ev & SOUND_STOPPED) emitEvent("sound_stopped");
  }

  bodyTick();
  { char why[20]; if (bodyTakeChange(why, sizeof why)) emitBody(why); }
  if (haveMic) pumpCapture();
  if (haveMic) {
    kwsPoll();
    char lab[16]; float score;
    if (kwsTakeDetection(lab, sizeof lab, &score)) {
      char extra[48]; snprintf(extra, sizeof extra, "\"label\":\"%s\",\"score\":%.2f", lab, score);
      emitEvent("heard", extra);
      if (!strcmp(lab, "clap")) bodyOnClap(soundDirection());
      else if (!strcmp(lab, "knock")) bodyOnKnock();
      else if (!strcmp(lab, "creature")) { bodyExpress("alert"); bodyGesture("perk"); chirpPlay("hello"); }
    }
  }

  // fixed-period scheduling: a slow iteration (Wi-Fi write or poll) does not stretch the next period
  if ((int32_t)(now - nextFast) >= 0) { nextFast += FAST_PERIOD_MS; if ((int32_t)(now - nextFast) > 0) nextFast = now; readFast(); }
  if ((int32_t)(now - nextState) >= 0) { nextState += STATE_PERIOD_MS; if ((int32_t)(now - nextState) > 0) nextState = now + STATE_PERIOD_MS; readSlow(); emitState(); }
  if (now - lastBlink >= 1000) { lastBlink = now; digitalWrite(LED_BUILTIN, !digitalRead(LED_BUILTIN)); }
  digitalWrite(LED2, presence ? HIGH : LOW);
}
