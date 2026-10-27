#include "chirp.h"
#include <Arduino.h>
#include <string.h>

static const int PIN = PB4;          // Arduino D5

struct Note { uint16_t hz; uint16_t ms; };     // hz 0 = rest
struct Tune { const char *name; const Note *notes; int n; };

static const Note HELLO[] = {{880, 90}, {1175, 110}, {0, 40}, {1568, 140}};
static const Note HAPPY[] = {{1319, 60}, {1568, 60}, {1760, 60}, {2093, 60}, {1760, 60}, {2093, 120}};
static const Note SAD[]   = {{988, 160}, {880, 160}, {740, 260}};
static const Note ALERT[] = {{1760, 80}, {0, 60}, {1760, 80}};
static const Note PURR[]  = {{220, 40}, {0, 25}, {220, 40}, {0, 25}, {220, 40}, {0, 25}, {220, 40}, {0, 25}, {220, 40}, {0, 25}, {220, 40}};
static const Note OK[]    = {{1319, 70}, {1760, 110}};
static const Note NO[]    = {{660, 120}, {0, 50}, {660, 120}};
static const Note SLEEPY[]= {{784, 200}, {659, 220}, {523, 320}};
static const Tune TUNES[] = {
  {"hello", HELLO, 4}, {"happy", HAPPY, 6}, {"sad", SAD, 3}, {"alert", ALERT, 3},
  {"purr", PURR, 11}, {"ok", OK, 2}, {"no", NO, 3}, {"sleepy", SLEEPY, 3},
};

static const Tune *cur = nullptr; static int idx = 0; static uint32_t noteEnd = 0;

void chirpBegin() { pinMode(PIN, OUTPUT); digitalWrite(PIN, LOW); }

bool chirpPlay(const char *name)
{
  for (const Tune &t : TUNES) if (!strcmp(t.name, name)) { cur = &t; idx = -1; noteEnd = 0; return true; }
  return false;
}

void chirpTick()
{
  if (!cur) return;
  uint32_t now = millis();
  if ((int32_t)(now - noteEnd) < 0) return;
  idx++;
  if (idx >= cur->n) { noTone(PIN); cur = nullptr; return; }
  const Note &n = cur->notes[idx];
  if (n.hz) tone(PIN, n.hz); else noTone(PIN);
  noteEnd = now + n.ms;
}

bool chirpBusy() { return cur != nullptr; }
