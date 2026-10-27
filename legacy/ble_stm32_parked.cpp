// PARKED 2026-10-27: passive BLE scan on the SPBTLE-RF worked for about 50 s alongside the
// Wi-Fi module and then stalled; both share SPI3 and the two libraries do not arbitrate
// the bus. Phone counting moves to the ear chip (ESP32-S3, own radio). Kept for reference.
#include "ble_stm32_parked.h"
#include <Arduino.h>
#include <STM32duinoBLE.h>
#include <string.h>

static const int      TABLE = 48;
static const uint32_t WINDOW_MS = 30000;
static const int      NEAR_RSSI = -75;
static const uint32_t POLL_MS = 50;

struct Seen { char addr[18]; int rssi; uint32_t ms; };
static Seen table[TABLE];
static int  used = 0;
static bool running = false;
static uint32_t lastPoll = 0, lastSeenMs = 0;
static int restarts = 0;

bool bleBegin()
{
  if (!BLE.begin()) return false;
  running = BLE.scan(true) == 1;        // with duplicates, so RSSI keeps updating
  return running;
}

static void remember(const char *addr, int rssi)
{
  uint32_t now = millis();
  int oldest = 0;
  for (int i = 0; i < used; i++) {
    if (!strcmp(table[i].addr, addr)) { table[i].rssi = rssi; table[i].ms = now; return; }
    if (table[i].ms < table[oldest].ms) oldest = i;
  }
  int slot = used < TABLE ? used++ : oldest;
  strncpy(table[slot].addr, addr, sizeof table[slot].addr - 1);
  table[slot].addr[sizeof table[slot].addr - 1] = 0;
  table[slot].rssi = rssi; table[slot].ms = now;
}

void blePoll()
{
  if (!running) return;
  uint32_t now = millis();
  if (now - lastPoll < POLL_MS) return;
  lastPoll = now;
  BLE.poll();
  for (int n = 0; n < 8; n++) {                // bounded work per call
    BLEDevice d = BLE.available();
    if (!d) break;
    remember(d.address().c_str(), d.rssi());
    lastSeenMs = now;
  }
  if (now - lastSeenMs > 20000) {              // nothing for 20 s: the scan has stalled (shared SPI bus); restart it
    lastSeenMs = now;
    BLE.stopScan();
    if (BLE.scan(true) != 1) { BLE.end(); running = BLE.begin() && BLE.scan(true) == 1; }
    restarts++;
  }
}

int bleRestarts() { return restarts; }

static int countSince(uint32_t windowMs, int minRssi)
{
  uint32_t now = millis(); int c = 0;
  for (int i = 0; i < used; i++) if (now - table[i].ms <= windowMs && table[i].rssi >= minRssi) c++;
  return c;
}

int bleNearby() { return running ? countSince(WINDOW_MS, NEAR_RSSI) : -1; }
int bleSeenTotal() { return running ? countSince(WINDOW_MS, -127) : -1; }
