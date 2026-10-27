// A voice of its own: short tone patterns on a piezo or small speaker on header
// pin D5 (PB4, PWM) through a 100 ohm resistor (piezo) or a transistor (speaker).
#pragma once
void chirpBegin();
bool chirpPlay(const char *name);   // hello, happy, sad, alert, purr, ok, no, sleepy; false if unknown
void chirpTick();                   // call often (non-blocking sequencer)
bool chirpBusy();
