#include "journal.h"
#include <Arduino.h>
#include <string.h>
#include "stm32l4xx_hal.h"

static const uint32_t REGION_START = 0x080C0000UL, REGION_END = 0x080FF800UL;
static const uint32_t PAGE = FLASH_PAGE_SIZE, REC = 128, RECS_PER_PAGE = PAGE / REC;   // 2 KB on the L475
static const uint32_t N_PAGES = (REGION_END - REGION_START) / PAGE;        // 127
static const uint32_t MAGIC = 0x4A524E32;                                   // "JRN2" (record layout: 128 bytes)

struct __attribute__((packed)) Record {
  uint32_t magic;      // MAGIC when written
  uint32_t seq;        // monotonically increasing
  uint32_t t_ms;       // unit uptime when the event happened
  uint32_t boot;       // boot id (random per boot)
  uint8_t  flags;      // bit0: read (programmed to 0 after a successful replay: 1 -> 0 is allowed on erased flash... we use a separate marker)
  uint8_t  len;
  char     text[110];
};
static_assert(sizeof(Record) == 128, "a record must fill exactly one 128-byte slot");

static uint32_t writeSeq = 0, bootId = 0, dropped = 0, acked = 0;
static uint32_t headAddr = 0;        // next record slot to write
static uint32_t tailAddr = 0;        // oldest unread record

static inline const Record *at(uint32_t addr) { return (const Record *)addr; }
static inline uint32_t next(uint32_t addr) { addr += REC; return addr >= REGION_END ? REGION_START : addr; }
static inline uint32_t pageOf(uint32_t addr) { return (addr - 0x08080000UL) / PAGE; }      // bank 2 page number

static void erasePage(uint32_t addr)
{
  FLASH_EraseInitTypeDef e = {};
  e.TypeErase = FLASH_TYPEERASE_PAGES; e.Banks = FLASH_BANK_2; e.Page = pageOf(addr); e.NbPages = 1;
  uint32_t err = 0;
  HAL_FLASH_Unlock();
  __HAL_FLASH_CLEAR_FLAG(FLASH_FLAG_ALL_ERRORS);
  HAL_FLASHEx_Erase(&e, &err);
  HAL_FLASH_Lock();
}

static bool program(uint32_t addr, const void *data, size_t n)
{
  const uint64_t *src = (const uint64_t *)data;
  HAL_FLASH_Unlock();
  __HAL_FLASH_CLEAR_FLAG(FLASH_FLAG_ALL_ERRORS);
  bool ok = true;
  for (size_t i = 0; i < n / 8 && ok; i++) ok = HAL_FLASH_Program(FLASH_TYPEPROGRAM_DOUBLEWORD, addr + i * 8, src[i]) == HAL_OK;
  HAL_FLASH_Lock();
  return ok;
}

void journalBegin(uint32_t id, uint32_t ackedSeq)
{
  bootId = id; acked = ackedSeq;
  // find the newest record (highest seq) and the oldest one newer than the acknowledged seq
  uint32_t best = 0, bestAddr = 0; bool any = false;
  uint32_t oldest = 0xFFFFFFFFu, oldestAddr = 0;
  for (uint32_t a = REGION_START; a < REGION_END; a += REC) {
    const Record *r = at(a);
    if (r->magic != MAGIC) continue;
    any = true;
    if (!bestAddr || (int32_t)(r->seq - best) > 0) { best = r->seq; bestAddr = a; }
    if ((int32_t)(r->seq - acked) > 0 && (oldestAddr == 0 || (int32_t)(r->seq - oldest) < 0)) { oldest = r->seq; oldestAddr = a; }
  }
  if (!any) { headAddr = REGION_START; tailAddr = REGION_START; writeSeq = acked + 1; return; }
  writeSeq = best + 1;
  if ((int32_t)(writeSeq - acked) <= 0) writeSeq = acked + 1;      // flash was wiped but settings kept the ack
  headAddr = next(bestAddr);
  tailAddr = oldestAddr ? oldestAddr : headAddr;
}

uint32_t journalLastSeq() { return writeSeq - 1; }

uint32_t journalWrite(const char *line, uint32_t t_ms)
{
  if ((headAddr % PAGE) == 0) {                            // entering a fresh page: erase it (drops the oldest records)
    if (tailAddr >= headAddr && tailAddr < headAddr + PAGE) { dropped += RECS_PER_PAGE; tailAddr = headAddr + PAGE; if (tailAddr >= REGION_END) tailAddr = REGION_START; }
    erasePage(headAddr);
  }
  Record r; memset(&r, 0xFF, sizeof r);
  r.magic = MAGIC; r.seq = writeSeq++; r.t_ms = t_ms; r.boot = bootId; r.flags = 0xFF;   // bit0 = 1: unread
  size_t len = strlen(line); if (len > sizeof r.text) len = sizeof r.text;
  r.len = (uint8_t)len; memcpy(r.text, line, len);
  bool ok = program(headAddr, &r, sizeof r);
  headAddr = next(headAddr);
  return ok ? r.seq : 0;
}

bool journalNext(char *line, size_t n, uint32_t *t_ms, uint32_t *boot, uint32_t *seq, uint32_t skipBelowSeq)
{
  if ((int32_t)(skipBelowSeq - acked) < 0) skipBelowSeq = acked;
  for (uint32_t a = tailAddr, guard = 0; a != headAddr && guard < N_PAGES * RECS_PER_PAGE; a = next(a), guard++) {
    const Record *r = at(a);
    if (r->magic != MAGIC) continue;
    if ((int32_t)(r->seq - skipBelowSeq) <= 0) continue;
    size_t len = r->len > sizeof r->text ? sizeof r->text : r->len;
    if (len > n - 1) len = n - 1;
    memcpy(line, r->text, len); line[len] = 0;
    *t_ms = r->t_ms; *boot = r->boot; *seq = r->seq;
    return true;
  }
  return false;
}

void journalAck(uint32_t seq)
{
  if ((int32_t)(seq - acked) > 0) acked = seq;
  while (tailAddr != headAddr) {                           // drop the tail past everything acknowledged
    const Record *r = at(tailAddr);
    if (r->magic == MAGIC && (int32_t)(r->seq - acked) > 0) break;
    tailAddr = next(tailAddr);
  }
}

uint32_t journalAcked() { return acked; }

uint32_t journalPending()
{
  uint32_t c = 0;
  for (uint32_t a = tailAddr; a != headAddr; a = next(a)) { const Record *r = at(a); if (r->magic == MAGIC && (int32_t)(r->seq - acked) > 0) c++; }
  return c;
}

uint32_t journalDropped() { return dropped; }
bool journalFromThisBoot(uint32_t b) { return b == bootId; }

int journalDump(uint32_t fromSeq, char *dst, size_t n)
{
  size_t p = snprintf(dst, n, "[");
  int k = 0;
  for (uint32_t a = tailAddr, guard = 0; a != headAddr && guard < N_PAGES * RECS_PER_PAGE && k < 4; a = next(a), guard++) {
    const Record *r = at(a);
    if (r->magic != MAGIC || (int32_t)(r->seq - fromSeq) < 0) continue;
    size_t len = r->len > sizeof r->text ? sizeof r->text : r->len;
    char head[24]; memcpy(head, r->text, len < 23 ? len : 23); head[len < 23 ? len : 23] = 0;
    for (char *c = head; *c; c++) if (*c == '"' || *c == '\\') *c = '_';
    p += snprintf(dst + p, n - p, "%s{\"seq\":%lu,\"len\":%u,\"last\":%d,\"boot\":%lu,\"head\":\"%s\"}", k ? "," : "",
                  (unsigned long)r->seq, (unsigned)r->len, len ? (int)(unsigned char)r->text[len - 1] : -1, (unsigned long)r->boot, head);
    k++;
    if (p + 80 > n) break;
  }
  p += snprintf(dst + p, n - p, "]");
  return (int)p;
}
