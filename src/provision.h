// Setup mode: Improv Wi-Fi over BLE plus a network list, see docs/protocol.md.
// Bluetooth and Wi-Fi never run at the same time (they share SPI3).
#pragma once
#include <stdint.h>
#include <stddef.h>
bool provisionBegin();            // Wi-Fi off, scan, BLE on; false if the BLE module is missing
void provisionPoll();             // call often while in setup mode
bool provisionActive();
bool provisionDone();             // true once joined and 10 s have passed: time to leave setup mode
void provisionEnd();              // BLE off
bool provisionTakeIdentify();     // the phone asked "which one are you"
bool provisionTakeNote(char *dst, size_t n);   // one progress note per call: JSON fields for a setup event
