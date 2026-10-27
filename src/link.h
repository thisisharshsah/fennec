// Wi-Fi link to the bridge over the on-board ISM43362 module, plus the
// persistent settings (network, bridge address, unit name) in emulated EEPROM.
#pragma once
#include <stdint.h>
#include <stddef.h>

struct LinkConfig {
  uint32_t magic;
  char     ssid[33];
  char     pass[64];
  char     host[40];     // bridge address, set by setup_unit.py (the module cannot listen for a beacon without blocking)
  uint16_t port;         // bridge unit port, 0 = default 8778
  char     unit[24];
};

extern LinkConfig linkCfg;

void linkBegin(bool join = true);                  // load config, bring the module up, first join attempt (skipped when join is false)
void linkPoll();                                   // rate-limited reconnects; call from loop()
bool linkSend(const char *line);                   // one JSON line, newline added; false if not connected
bool linkReadLine(char *dst, size_t n);            // polls the bridge for a command line every ~2 s (costs ~0.2 s)
bool linkJoined();                                 // on the network
bool linkConnected();                              // TCP session with the bridge is up
int  linkRssi();                                   // dBm, 0 if unknown
void linkIp(char *out, size_t n);                  // dotted IP or ""
const char *linkModuleFw();                        // module firmware version or ""
void linkSetWifi(const char *ssid, const char *pass);
void linkSetBridge(const char *host, uint16_t port);
void linkSetUnit(const char *unit);
void linkSave();
void linkStop();                                   // Wi-Fi off (setup mode)
bool linkJoinNow();                                // blocking join attempt with the stored settings
bool linkConnectNow();                             // blocking connect to the stored bridge
int  linkScan();                                   // blocking scan; number of networks found
int  linkScanRobust();                             // scan; on an empty result reinitialise the module and retry (a few seconds)
bool linkScanEntry(int i, char *ssid, size_t n, int *rssi, bool *secured);
void linkMac(char *out, size_t n);                 // "A1B2C3D4E5F6"

// settings storage shared with other modules (emulated EEPROM, one flash page)
void cfgLoad(void *dst, size_t n, size_t offset);
void cfgSave(const void *src, size_t n, size_t offset);
