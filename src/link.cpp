#include "link.h"
#include <Arduino.h>
#include <SPI.h>
#include <WiFiST.h>
#include <utility/stm32_eeprom.h>
#include <string.h>

static const uint32_t CFG_MAGIC      = 0x524D4331;   // "RMC1"
static const uint16_t UNIT_PORT      = 8778;
static const uint32_t JOIN_RETRY_MS  = 20000;
static const uint32_t CONN_RETRY_MS  = 10000;
static const uint32_t CMD_POLL_MS    = 2000;    // how often to ask the module for inbound bytes
static const uint32_t CMD_READ_MS    = 400;     // driver budget per poll; the module waits 300 ms of it

LinkConfig linkCfg;

static SPIClass  spi3(PC12, PC11, PC10);
static WiFiClass wifi(&spi3, PE0, PE1, PE8, PB13);
static WiFiClient client;

static bool     haveModule = false, joined = false, connected = false;
static int8_t   sock = -1;
static uint32_t lastCmdPoll = 0;
static char     rx[200]; static size_t rxLen = 0;
static uint32_t lastJoinTry = 0, lastConnTry = 0;
static char     moduleFw[24] = "";

static void loadConfig()
{
  eeprom_buffer_fill();
  uint8_t *p = (uint8_t *)&linkCfg;
  for (size_t i = 0; i < sizeof linkCfg; i++) p[i] = eeprom_buffered_read_byte(i);
  if (linkCfg.magic != CFG_MAGIC) {
    memset(&linkCfg, 0, sizeof linkCfg);
    linkCfg.magic = CFG_MAGIC;
    strcpy(linkCfg.unit, "desk");
  }
  linkCfg.ssid[sizeof linkCfg.ssid - 1] = 0;
  linkCfg.pass[sizeof linkCfg.pass - 1] = 0;
  linkCfg.host[sizeof linkCfg.host - 1] = 0;
  linkCfg.unit[sizeof linkCfg.unit - 1] = 0;
  if (!linkCfg.unit[0]) strcpy(linkCfg.unit, "desk");
}

void cfgLoad(void *dst, size_t n, size_t offset)
{
  eeprom_buffer_fill();
  uint8_t *p = (uint8_t *)dst;
  for (size_t i = 0; i < n; i++) p[i] = eeprom_buffered_read_byte(offset + i);
}

void cfgSave(const void *src, size_t n, size_t offset)
{
  eeprom_buffer_fill();
  const uint8_t *p = (const uint8_t *)src;
  for (size_t i = 0; i < n; i++) eeprom_buffered_write_byte(offset + i, p[i]);
  eeprom_buffer_flush();
}

void linkSave()
{
  eeprom_buffer_fill();
  const uint8_t *p = (const uint8_t *)&linkCfg;
  for (size_t i = 0; i < sizeof linkCfg; i++) eeprom_buffered_write_byte(i, p[i]);
  eeprom_buffer_flush();
}

void linkSetWifi(const char *ssid, const char *pass)
{
  strncpy(linkCfg.ssid, ssid, sizeof linkCfg.ssid - 1);
  strncpy(linkCfg.pass, pass, sizeof linkCfg.pass - 1);
  joined = false; connected = false; lastJoinTry = 0;
}

void linkSetBridge(const char *host, uint16_t port)
{
  strncpy(linkCfg.host, host, sizeof linkCfg.host - 1);
  linkCfg.port = port;
  connected = false; lastConnTry = 0;
}

void linkSetUnit(const char *unit) { strncpy(linkCfg.unit, unit, sizeof linkCfg.unit - 1); }

static bool tryJoin()
{
  lastJoinTry = millis();
  if (!haveModule || !linkCfg.ssid[0]) return false;
  int st = wifi.begin(linkCfg.ssid, linkCfg.pass);
  joined = (st == WL_CONNECTED);
  return joined;
}

static bool tryConnect()
{
  lastConnTry = millis();
  if (!joined) return false;
  IPAddress ip; uint16_t port = linkCfg.port ? linkCfg.port : UNIT_PORT;
  if (!linkCfg.host[0] || !ip.fromString(linkCfg.host)) return false;   // no address yet: setup_unit.py sets it
  client.stop();
  sock = DrvWiFi->getFreeSocket();            // connect() takes this same index
  connected = client.connect(ip, port) == 1;
  rxLen = 0;
  return connected;
}

void linkBegin(bool join)
{
  loadConfig();
  haveModule = wifi.status() != WL_NO_SHIELD;
  if (haveModule) {
    const char *fw = wifi.firmwareVersion();
    if (fw) strncpy(moduleFw, fw, sizeof moduleFw - 1);
    if (join && tryJoin()) tryConnect();
  }
}

int linkScanRobust()
{
  int n = linkScan();
  for (int attempt = 0; n == 0 && attempt < 2; attempt++) {
    // after a failed join the module answers a scan with nothing; a fresh init clears that
    DrvWiFi->ES_WIFI_Init();
    delay(600);
    n = linkScan();
  }
  return n;
}

void linkPoll()
{
  if (!haveModule) return;
  uint32_t now = millis();
  if (!joined) {
    if (linkCfg.ssid[0] && now - lastJoinTry >= JOIN_RETRY_MS) { if (tryJoin()) tryConnect(); }
    return;
  }
  if (!connected && now - lastConnTry >= CONN_RETRY_MS) tryConnect();
}

bool linkSend(const char *line)
{
  if (!connected) return false;
  size_t n = strlen(line);
  size_t sent = client.write((const uint8_t *)line, n);
  if (sent == n) sent += client.write((const uint8_t *)"\n", 1) == 1 ? 1 : 0;
  if (sent != n + 1) {
    connected = false;
    client.stop();
    if (wifi.status() != WL_CONNECTED) joined = false;
    return false;
  }
  return true;
}

bool linkReadLine(char *dst, size_t n)
{
  if (!connected || sock < 0) return false;
  static uint8_t buf[240]; static uint16_t got = 0, pos = 0;
  uint32_t now = millis();
  if (pos >= got) {                                                   // nothing left over from the last read: ask the module
    if (now - lastCmdPoll < CMD_POLL_MS) return false;
    lastCmdPoll = now;
    got = 0; pos = 0;
    DrvWiFi->ES_WIFI_ReceiveData((uint8_t)sock, buf, sizeof buf, &got, CMD_READ_MS);
    // the driver's command timeout stays at CMD_READ_MS until the next write restores it (under 1 s away)
    if (DrvWiFi->getSocketState((uint8_t)sock) == SOCKET_FREE) {    // the driver frees the socket on an I/O error
      connected = false; client.stop(); got = 0; return false;
    }
  }
  while (pos < got) {                                                 // several lines may share one read; hand out one per call
    char c = (char)buf[pos++];
    if (c == '\n' || c == '\r') {
      if (rxLen) { rx[rxLen] = 0; rxLen = 0; strncpy(dst, rx, n - 1); dst[n - 1] = 0; return true; }
    } else if (rxLen < sizeof rx - 1) {
      rx[rxLen++] = c;
    } else {
      rxLen = 0;
    }
  }
  return false;
}

void linkStop()
{
  if (connected) { client.stop(); connected = false; }
  if (joined) { wifi.disconnect(); joined = false; }
}

bool linkJoinNow() { return tryJoin(); }
bool linkConnectNow() { return tryConnect(); }

int linkScan()
{
  if (!haveModule) return 0;
  int8_t n = wifi.scanNetworks();
  return n < 0 ? 0 : n;
}

bool linkScanEntry(int i, char *ssid, size_t n, int *rssi, bool *secured)
{
  const char *name = wifi.SSID((uint8_t)i);
  if (!name) return false;
  strncpy(ssid, name, n - 1); ssid[n - 1] = 0;
  *rssi = (int)wifi.RSSI((uint8_t)i);
  *secured = wifi.encryptionType((uint8_t)i) != ES_WIFI_SEC_OPEN;
  return true;
}

void linkMac(char *out, size_t n)
{
  uint8_t mac[6] = {0};
  wifi.macAddress(mac);
  snprintf(out, n, "%02X%02X%02X%02X%02X%02X", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
}

bool linkJoined() { return joined; }
bool linkConnected() { return connected; }
int  linkRssi() { return joined ? (int)wifi.RSSI() : 0; }
void linkIp(char *out, size_t n)
{
  if (!joined) { if (n) out[0] = 0; return; }
  IPAddress ip = wifi.localIP();
  snprintf(out, n, "%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3]);
}
const char *linkModuleFw() { return moduleFw; }
