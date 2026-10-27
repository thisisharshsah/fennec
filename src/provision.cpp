#include "provision.h"
#include "link.h"
#include <Arduino.h>
#include <STM32duinoBLE.h>
#include <IWatchdog.h>
#include <string.h>

static const char *UUID_SVC   = "00467768-6228-2272-4663-277478268000";
static const char *UUID_STATE = "00467768-6228-2272-4663-277478268001";
static const char *UUID_ERROR = "00467768-6228-2272-4663-277478268002";
static const char *UUID_RPC   = "00467768-6228-2272-4663-277478268003";
static const char *UUID_RES   = "00467768-6228-2272-4663-277478268004";
static const char *UUID_CAPS  = "00467768-6228-2272-4663-277478268005";
static const char *UUID_NCNT  = "00467768-6228-2272-4663-277478268010";
static const char *UUID_NIDX  = "00467768-6228-2272-4663-277478268011";
static const char *UUID_NENT  = "00467768-6228-2272-4663-277478268012";
static const char *UUID_BRIDGE= "00467768-6228-2272-4663-277478268013";

enum { ST_AUTHORIZED = 0x02, ST_PROVISIONING = 0x03, ST_PROVISIONED = 0x04 };
enum { ERR_NONE = 0, ERR_INVALID = 1, ERR_UNKNOWN_CMD = 2, ERR_CONNECT = 3 };

static BLEService svc(UUID_SVC);
static BLEByteCharacteristic chState(UUID_STATE, BLERead | BLENotify);
static BLEByteCharacteristic chError(UUID_ERROR, BLERead | BLENotify);
static BLECharacteristic     chRpc(UUID_RPC, BLEWrite, 160);
static BLECharacteristic     chResult(UUID_RES, BLERead | BLENotify, 64);
static BLEByteCharacteristic chCaps(UUID_CAPS, BLERead);
static BLEByteCharacteristic chNetCount(UUID_NCNT, BLERead);
static BLEByteCharacteristic chNetIndex(UUID_NIDX, BLEWrite);
static BLECharacteristic     chNetEntry(UUID_NENT, BLERead, 40);
static BLECharacteristic     chBridge(UUID_BRIDGE, BLEWrite, 32);

static bool active = false, done = false, identify = false;
static char note[96] = "";
static void setNote(const char *fmt, const char *a, int b) { snprintf(note, sizeof note, fmt, a, b); }
static uint32_t doneAt = 0, lastScan = 0;
static int netCount = 0;

static void setState(uint8_t s) { chState.writeValue(s); }
static void setError(uint8_t e) { chError.writeValue(e); }

// networks sorted strongest first, duplicates (same name, several access points) merged
static uint8_t order[32];

static void scanNetworks()
{
  int n = linkScanRobust();
  if (n > 32) n = 32;
  char seen[32][21]; int kept = 0;
  int rssiOf[32];
  for (int i = 0; i < n; i++) {
    char ssid[40]; int rssi; bool sec;
    if (!linkScanEntry(i, ssid, sizeof ssid, &rssi, &sec) || !ssid[0]) continue;
    ssid[20] = 0;
    int dup = -1;
    for (int k = 0; k < kept; k++) if (!strcmp(seen[k], ssid)) dup = k;
    if (dup >= 0) { if (rssi > rssiOf[dup]) { rssiOf[dup] = rssi; order[dup] = (uint8_t)i; } continue; }
    strcpy(seen[kept], ssid); rssiOf[kept] = rssi; order[kept] = (uint8_t)i; kept++;
  }
  for (int a = 1; a < kept; a++)                       // insertion sort by signal
    for (int b = a; b > 0 && rssiOf[b] > rssiOf[b - 1]; b -= 1) {
      int t = rssiOf[b]; rssiOf[b] = rssiOf[b - 1]; rssiOf[b - 1] = t;
      uint8_t o = order[b]; order[b] = order[b - 1]; order[b - 1] = o;
      char tmp[21]; strcpy(tmp, seen[b]); strcpy(seen[b], seen[b - 1]); strcpy(seen[b - 1], tmp);
    }
  netCount = kept;
  chNetCount.writeValue((uint8_t)netCount);
  lastScan = millis();
  setNote("\"step\":\"%s\",\"networks\":%d", "scanned", netCount);
}

static void loadEntry(int i)
{
  // "secured|rssi|ssid"; secured is "1" or "0", with an "s" appended for the network this unit last joined
  char ssid[40]; int rssi; bool sec; char out[32];
  if (i < netCount && linkScanEntry(order[i], ssid, sizeof ssid, &rssi, &sec)) {
    bool saved = linkCfg.ssid[0] && !strncmp(ssid, linkCfg.ssid, 20);
    ssid[20] = 0;
    snprintf(out, sizeof out, "%d%s|%d|%s", sec ? 1 : 0, saved ? "s" : "", rssi, ssid);
  } else out[0] = 0;
  chNetEntry.writeValue((const uint8_t *)out, strlen(out));
}

static void sendResult(uint8_t cmd, const char *str)
{
  uint8_t pkt[64]; int n = 0;
  size_t sl = strlen(str); if (sl > 56) sl = 56;
  pkt[n++] = cmd; pkt[n++] = (uint8_t)(sl + 1); pkt[n++] = (uint8_t)sl;
  memcpy(pkt + n, str, sl); n += sl;
  uint8_t sum = 0; for (int i = 0; i < n; i++) sum += pkt[i];
  pkt[n++] = sum;
  chResult.writeValue(pkt, n);
}

static void handleRpc(const uint8_t *d, int len)
{
  if (len < 3) { setError(ERR_INVALID); return; }
  uint8_t sum = 0; for (int i = 0; i < len - 1; i++) sum += d[i];
  if (sum != d[len - 1] || d[1] != len - 3) { setError(ERR_INVALID); return; }
  setError(ERR_NONE);
  if (d[0] == 0x02) { identify = true; return; }
  if (d[0] != 0x01) { setError(ERR_UNKNOWN_CMD); return; }
  const uint8_t *p = d + 2; int rem = d[1];
  if (rem < 1) { setError(ERR_INVALID); return; }
  int sl = p[0]; if (sl + 1 > rem) { setError(ERR_INVALID); return; }
  char ssid[33] = {0}; memcpy(ssid, p + 1, sl > 32 ? 32 : sl);
  p += 1 + sl; rem -= 1 + sl;
  char pass[64] = {0};
  if (rem >= 1) { int pl = p[0]; if (pl + 1 > rem) { setError(ERR_INVALID); return; } memcpy(pass, p + 1, pl > 63 ? 63 : pl); }

  setState(ST_PROVISIONING);
  BLE.poll();
  setNote("\"step\":\"credentials\",\"ssid\":\"%s\",\"pass_len\":%d", ssid, (int)strlen(pass));
  linkSetWifi(ssid, pass);
  IWatchdog.reload();
  bool ok = linkJoinNow();                       // blocks up to ~10 s
  IWatchdog.reload();
  if (ok) { linkSave(); linkConnectNow(); IWatchdog.reload(); }
  if (ok) {
    char ip[20]; linkIp(ip, sizeof ip);
    char url[40]; snprintf(url, sizeof url, "http://%s/", ip);
    sendResult(0x01, url);
    setState(ST_PROVISIONED);
    done = false; doneAt = millis() + 10000;
    setNote("\"step\":\"%s\",\"bridge\":%d", "joined", linkConnected() ? 1 : 0);
  } else {
    linkStop();
    setError(ERR_CONNECT);
    setState(ST_AUTHORIZED);
    setNote("\"step\":\"%s\",\"error\":%d", "join_failed", ERR_CONNECT);
  }
}

bool provisionBegin()
{
  char mac[13]; linkMac(mac, sizeof mac);
  char name[24]; snprintf(name, sizeof name, "creature-%s", mac + 8);
  scanNetworks();                              // before Bluetooth: both modules share the SPI bus
  linkStop();
  if (!BLE.begin()) return false;
  BLE.setLocalName(name);
  BLE.setDeviceName(name);
  BLE.setAdvertisedService(svc);
  svc.addCharacteristic(chState); svc.addCharacteristic(chError); svc.addCharacteristic(chRpc);
  svc.addCharacteristic(chResult); svc.addCharacteristic(chCaps);
  svc.addCharacteristic(chNetCount); svc.addCharacteristic(chNetIndex); svc.addCharacteristic(chNetEntry);
  svc.addCharacteristic(chBridge);
  BLE.addService(svc);
  chCaps.writeValue((uint8_t)0x01);
  setState(ST_AUTHORIZED); setError(ERR_NONE);
  chNetCount.writeValue((uint8_t)netCount);
  BLE.advertise();
  active = true; done = false; doneAt = 0;
  return true;
}

void provisionPoll()
{
  if (!active) return;
  BLE.poll();
  if (chNetIndex.written()) loadEntry(chNetIndex.value());
  if (chBridge.written()) {
    char buf[33] = {0}; int n = chBridge.valueLength(); if (n > 32) n = 32;
    memcpy(buf, chBridge.value(), n);
    char *colon = strrchr(buf, ':');
    uint16_t port = 0; if (colon) { *colon = 0; port = (uint16_t)atoi(colon + 1); }
    linkSetBridge(buf, port);
    setNote("\"step\":\"bridge_address\",\"host\":\"%s\",\"port\":%d", buf, (int)port);
  }
  if (chRpc.written()) handleRpc(chRpc.value(), chRpc.valueLength());
  if (doneAt && (int32_t)(millis() - doneAt) >= 0) done = true;
  (void)lastScan;                               // no rescans while Bluetooth owns the bus
}

bool provisionActive() { return active; }
bool provisionDone() { return done; }
void provisionEnd() { if (active) { BLE.stopAdvertise(); BLE.end(); } active = false; done = false; doneAt = 0; }
bool provisionTakeIdentify() { bool i = identify; identify = false; return i; }
bool provisionTakeNote(char *dst, size_t n) { if (!note[0]) return false; strncpy(dst, note, n - 1); dst[n - 1] = 0; note[0] = 0; return true; }
