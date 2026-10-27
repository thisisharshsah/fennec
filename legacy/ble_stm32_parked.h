// Phones nearby: passive Bluetooth LE scan on the on-board SPBTLE-RF, counting
// distinct advertisers seen recently and close enough. A presence hint, not identity.
#pragma once
#include <stdint.h>
bool bleBegin();
void blePoll();                 // call often
int  bleNearby();               // advertisers seen in the last 30 s with RSSI above the threshold
int  bleSeenTotal();
int  bleRestarts();             // scan restarts after stalls            // distinct advertisers seen in the last 30 s at any strength
