// Two PDM microphones (MP34DT01, on DFSDM1 channel 2 data line) -> sound level,
// crude left/right bearing, and events. Implemented against ST's HAL since the
// Arduino layer does not wrap DFSDM on this chip.
#pragma once
#include <stdint.h>

bool  soundBegin();            // false if the DFSDM/DMA setup failed
float soundLevelDb();          // smoothed level, uncalibrated dB: quiet room ~30, speech ~45, clap 70+
float soundDirection();        // -1 left .. +1 right, 0 centre/unknown
int   soundClipping();         // 1 if the last block was near full scale

// Raw capture for training data: one mono window from the left mic, 16-bit, 20 kHz,
// delivered through a ring while it is being recorded.
bool  soundCaptureStart(uint32_t ms);                   // false if busy or longer than 5 s
bool  soundCaptureActive();                             // true until the last sample has been read
uint32_t soundCaptureTotal();                           // samples in this capture
uint32_t soundCaptureDropped();                         // samples lost because the reader was slow
uint32_t soundCaptureRead(int16_t *dst, uint32_t n);    // pull up to n samples
uint32_t soundSampleRate();

// Event flags, cleared when read.
enum SoundEvent { SOUND_NONE = 0, SOUND_CLAP = 1, SOUND_STARTED = 2, SOUND_STOPPED = 4 };
int   soundTakeEvents();
