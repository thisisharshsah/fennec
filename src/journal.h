// Offline memory: events are kept in internal flash while the Wi-Fi link to the
// bridge is down and replayed when it is back, with how old they are.
// Region: 0x080C0000 .. 0x080FF800 (254 KB, 127 pages of 2 KB), a ring of
// 128-byte records, below the EEPROM emulation page.
#pragma once
#include <stdint.h>
#include <stddef.h>
void journalBegin(uint32_t bootId, uint32_t ackedSeq);   // bootId: the boot counter; ackedSeq: last confirmed seq from settings
uint32_t journalWrite(const char *line, uint32_t t_ms);   // returns the record's seq (0 on failure); line up to 110 chars
uint32_t journalLastSeq();
bool journalNext(char *line, size_t n, uint32_t *t_ms, uint32_t *bootId, uint32_t *seq, uint32_t skipBelowSeq); // oldest unread with seq > skipBelowSeq
void journalAck(uint32_t seq);                         // the bridge confirmed everything up to seq
uint32_t journalAcked();
int  journalDump(uint32_t fromSeq, char *dst, size_t n);   // debug: up to 4 records as JSON array
uint32_t journalPending();
bool journalFromThisBoot(uint32_t bootId);
uint32_t journalDropped();
