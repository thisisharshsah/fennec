#include "sound.h"
#include <Arduino.h>
#include <math.h>
#include "stm32l4xx_hal.h"
#include "kws.h"

// DFSDM1 kernel clock is APB2 (80 MHz). Divider 32 gives a 2.5 MHz PDM clock,
// sinc3 with oversampling 125 gives 20 kHz 16-bit samples per microphone.
static const uint32_t PDM_DIVIDER   = 32;
static const uint32_t OVERSAMPLING  = 125;
static const uint32_t SAMPLE_RATE   = 80000000 / PDM_DIVIDER / OVERSAMPLING;   // 20000
static const uint32_t BLOCK         = 1024;                                      // samples per half buffer, 51 ms
static const uint32_t MAX_LAG       = 4;                                         // 6 cm mic spacing = 3.5 samples

static DFSDM_Channel_HandleTypeDef chLeft, chRight;
static DFSDM_Filter_HandleTypeDef  fltLeft, fltRight;
static DMA_HandleTypeDef           dmaLeft, dmaRight;

// 32-bit regular conversions: the 24-bit sample sits in bits 31:8.
static int32_t bufLeft[2 * BLOCK];
static int32_t bufRight[2 * BLOCK];
static const float DB_REF = 60.0f;   // chosen so a quiet room reads about 30 dB (uncalibrated)

static volatile float    g_levelDb = 0, g_floorRms = 2000.0f, g_dir = 0;
static volatile int      g_clip = 0;
static volatile int      g_events = 0;
static volatile uint32_t g_blocks = 0;

// capture (left mic) streams out live through a small ring; the serial port at
// 921600 baud drains faster than 20 kHz 16-bit audio arrives (40 KB/s raw, 53 KB/s as base64).
static const uint32_t CAP_RING = 8192;     // 16 KB: rides through a 300 ms stall of the main loop
static int16_t  cap[CAP_RING];
static volatile uint32_t capHead = 0, capTail = 0, capWant = 0, capDone = 0, capDropped = 0;
static volatile bool capBusy = false;

static float   prevRms = 0;
static int     candidateAge = -1;       // blocks since a candidate impulse, -1 = none
static float   candidateRms = 0;
static int     loudBlocks = 0, quietBlocks = 0;
static bool    sounding = false;

extern "C" void DMA1_Channel4_IRQHandler(void) { HAL_DMA_IRQHandler(&dmaLeft); }
extern "C" void DMA1_Channel5_IRQHandler(void) { HAL_DMA_IRQHandler(&dmaRight); }

static bool initChannel(DFSDM_Channel_HandleTypeDef &h, DFSDM_Channel_TypeDef *inst, bool rising, bool ownPins)
{
  h.Instance = inst;
  h.Init.OutputClock.Activation = ENABLE;
  h.Init.OutputClock.Selection  = DFSDM_CHANNEL_OUTPUT_CLOCK_SYSTEM;
  h.Init.OutputClock.Divider    = PDM_DIVIDER;
  h.Init.Input.Multiplexer      = DFSDM_CHANNEL_EXTERNAL_INPUTS;
  h.Init.Input.DataPacking      = DFSDM_CHANNEL_STANDARD_MODE;
  h.Init.Input.Pins             = ownPins ? DFSDM_CHANNEL_SAME_CHANNEL_PINS : DFSDM_CHANNEL_FOLLOWING_CHANNEL_PINS;
  h.Init.SerialInterface.Type   = rising ? DFSDM_CHANNEL_SPI_RISING : DFSDM_CHANNEL_SPI_FALLING;
  h.Init.SerialInterface.SpiClock = DFSDM_CHANNEL_SPI_CLOCK_INTERNAL;
  h.Init.Awd.FilterOrder        = DFSDM_CHANNEL_FASTSINC_ORDER;
  h.Init.Awd.Oversampling       = 10;
  h.Init.Offset                 = 0;
  h.Init.RightBitShift          = 0;
  return HAL_DFSDM_ChannelInit(&h) == HAL_OK;
}

static bool initFilter(DFSDM_Filter_HandleTypeDef &f, DFSDM_Filter_TypeDef *inst, DMA_HandleTypeDef &d,
                       DMA_Channel_TypeDef *dch, IRQn_Type irq, bool master, uint32_t channel)
{
  __HAL_RCC_DMA1_CLK_ENABLE();
  d.Instance                 = dch;
  d.Init.Request             = DMA_REQUEST_0;
  d.Init.Direction           = DMA_PERIPH_TO_MEMORY;
  d.Init.PeriphInc           = DMA_PINC_DISABLE;
  d.Init.MemInc              = DMA_MINC_ENABLE;
  d.Init.PeriphDataAlignment = DMA_PDATAALIGN_WORD;
  d.Init.MemDataAlignment    = DMA_MDATAALIGN_WORD;
  d.Init.Mode                = DMA_CIRCULAR;
  d.Init.Priority            = DMA_PRIORITY_HIGH;
  if (HAL_DMA_Init(&d) != HAL_OK) return false;
  HAL_NVIC_SetPriority(irq, 5, 0);
  HAL_NVIC_EnableIRQ(irq);

  f.Instance                          = inst;
  f.Init.RegularParam.Trigger         = master ? DFSDM_FILTER_SW_TRIGGER : DFSDM_FILTER_SYNC_TRIGGER;
  f.Init.RegularParam.FastMode        = ENABLE;
  f.Init.RegularParam.DmaMode         = ENABLE;
  f.Init.InjectedParam.Trigger        = DFSDM_FILTER_SW_TRIGGER;
  f.Init.InjectedParam.ScanMode       = DISABLE;
  f.Init.InjectedParam.DmaMode        = DISABLE;
  f.Init.InjectedParam.ExtTrigger     = DFSDM_FILTER_EXT_TRIG_TIM1_TRGO;
  f.Init.InjectedParam.ExtTriggerEdge = DFSDM_FILTER_EXT_TRIG_RISING_EDGE;
  f.Init.FilterParam.SincOrder        = DFSDM_FILTER_SINC3_ORDER;
  f.Init.FilterParam.Oversampling     = OVERSAMPLING;
  f.Init.FilterParam.IntOversampling  = 1;
  __HAL_LINKDMA(&f, hdmaReg, d);
  if (HAL_DFSDM_FilterInit(&f) != HAL_OK) return false;
  return HAL_DFSDM_FilterConfigRegChannel(&f, channel, DFSDM_CONTINUOUS_CONV_ON) == HAL_OK;
}

bool soundBegin()
{
  __HAL_RCC_GPIOE_CLK_ENABLE();
  __HAL_RCC_DFSDM1_CLK_ENABLE();
  GPIO_InitTypeDef g = {};
  g.Pin = GPIO_PIN_7 | GPIO_PIN_9;             // PE7 DATIN2, PE9 CKOUT
  g.Mode = GPIO_MODE_AF_PP;
  g.Pull = GPIO_NOPULL;
  g.Speed = GPIO_SPEED_FREQ_HIGH;
  g.Alternate = GPIO_AF6_DFSDM1;
  HAL_GPIO_Init(GPIOE, &g);

  // Left mic clocks data on the rising edge into channel 2; the right mic shares the
  // same data pin and is read on the falling edge by channel 1 using channel 2's pins.
  if (!initChannel(chLeft,  DFSDM1_Channel2, true,  true))  return false;
  if (!initChannel(chRight, DFSDM1_Channel1, false, false)) return false;
  if (!initFilter(fltLeft,  DFSDM1_Filter0, dmaLeft,  DMA1_Channel4, DMA1_Channel4_IRQn, true,  DFSDM_CHANNEL_2)) return false;
  if (!initFilter(fltRight, DFSDM1_Filter1, dmaRight, DMA1_Channel5, DMA1_Channel5_IRQn, false, DFSDM_CHANNEL_1)) return false;

  // The slave filter must be armed first; it starts when the master does.
  if (HAL_DFSDM_FilterRegularStart_DMA(&fltRight, bufRight, 2 * BLOCK) != HAL_OK) return false;
  if (HAL_DFSDM_FilterRegularStart_DMA(&fltLeft,  bufLeft,  2 * BLOCK) != HAL_OK) return false;
  return true;
}

static inline int32_t S(int32_t raw) { return raw >> 8; }

static void captureBlock(const int32_t *l)
{
  if (!capBusy) return;
  for (uint32_t i = 0; i < BLOCK && capDone < capWant; i++, capDone++) {
    uint32_t next = (capHead + 1) % CAP_RING;
    if (next == capTail) { capDropped++; continue; }           // reader fell behind
    cap[capHead] = (int16_t)(S(l[i]) >> 6);                    // 24-bit -> ~16-bit with a little gain
    capHead = next;
  }
}

static void processBlock(const int32_t *l, const int32_t *r)
{
  captureBlock(l);
  kwsFeedBlock(l, BLOCK);
  int64_t sl = 0, sr = 0;
  for (uint32_t i = 0; i < BLOCK; i++) { sl += S(l[i]); sr += S(r[i]); }
  int32_t ml = (int32_t)(sl / (int64_t)BLOCK), mr = (int32_t)(sr / (int64_t)BLOCK);

  float el = 0, er = 0; int peak = 0;
  for (uint32_t i = 0; i < BLOCK; i++) {
    float a = (float)(S(l[i]) - ml), b = (float)(S(r[i]) - mr);
    el += a * a; er += b * b;
    int p = abs(S(l[i]) - ml); if (p > peak) peak = p;
  }
  float rmsL = sqrtf(el / BLOCK), rmsR = sqrtf(er / BLOCK);
  float rms = 0.5f * (rmsL + rmsR);
  g_clip = peak > 1800000;

  // bearing: lag of best cross-correlation, only when there is something to hear
  if (rms > 3.0f * g_floorRms) {
    float best = -1e30f; int bestLag = 0;
    for (int lag = -(int)MAX_LAG; lag <= (int)MAX_LAG; lag++) {
      float c = 0;
      for (uint32_t i = MAX_LAG; i < BLOCK - MAX_LAG; i += 2)
        c += (float)(S(l[i]) - ml) * (float)(S(r[i + lag]) - mr);
      if (c > best) { best = c; bestLag = lag; }
    }
    g_dir = 0.8f * g_dir + 0.2f * ((float)bestLag / (float)MAX_LAG);
  } else {
    g_dir *= 0.9f;
  }

  // slow noise floor; only tracks when nothing loud is happening
  if (rms < 2.0f * g_floorRms) g_floorRms = 0.98f * g_floorRms + 0.02f * rms;
  if (g_floorRms < 300.0f) g_floorRms = 300.0f;

  float db = 20.0f * log10f(rms / DB_REF + 1.0f);
  g_levelDb = 0.7f * g_levelDb + 0.3f * db;

  // clap: a short impulse at least 8x the floor, quiet before and after
  float loud = 8.0f * g_floorRms;
  if (candidateAge >= 0) {
    candidateAge++;
    if (rms < 0.3f * candidateRms || rms < 3.0f * g_floorRms) {
      if (candidateAge <= 3) g_events |= SOUND_CLAP;
      candidateAge = -1;
    } else if (candidateAge > 3) {
      candidateAge = -1;                         // too long for a clap
    }
  } else if (rms > loud && prevRms < 3.0f * g_floorRms) {
    candidateAge = 0; candidateRms = rms;
  }

  // sustained sound (speech, music, a machine): mostly above 3x floor for about
  // a second, allowing for the pauses in speech; stops after 2 s of quiet
  if (rms > 3.0f * g_floorRms) { if (loudBlocks < 20) loudBlocks++; quietBlocks = 0; }
  else { if (loudBlocks > 0) loudBlocks -= 1; quietBlocks++; }
  if (!sounding && loudBlocks >= 12) { sounding = true; g_events |= SOUND_STARTED; }
  if (sounding && quietBlocks >= 40) { sounding = false; loudBlocks = 0; g_events |= SOUND_STOPPED; }

  prevRms = rms;
  g_blocks++;
}

extern "C" void HAL_DFSDM_FilterRegHalfCpltCallback(DFSDM_Filter_HandleTypeDef *h)
{
  if (h == &fltLeft) processBlock(bufLeft, bufRight);
}

extern "C" void HAL_DFSDM_FilterRegConvCpltCallback(DFSDM_Filter_HandleTypeDef *h)
{
  if (h == &fltLeft) processBlock(bufLeft + BLOCK, bufRight + BLOCK);
}

bool soundCaptureStart(uint32_t ms)
{
  if (capBusy || ms == 0 || ms > 5000) return false;
  capWant = ms * SAMPLE_RATE / 1000; capDone = 0; capDropped = 0; capHead = capTail = 0; capBusy = true;
  return true;
}
bool soundCaptureActive() { return capBusy; }
uint32_t soundCaptureTotal() { return capWant; }
uint32_t soundCaptureDropped() { return capDropped; }
uint32_t soundCaptureRead(int16_t *dst, uint32_t n)
{
  uint32_t got = 0;
  while (got < n && capTail != capHead) { dst[got++] = cap[capTail]; capTail = (capTail + 1) % CAP_RING; }
  if (capBusy && capDone >= capWant && capTail == capHead) capBusy = false;   // everything delivered
  return got;
}
uint32_t soundSampleRate() { return SAMPLE_RATE; }

float soundLevelDb() { return g_levelDb; }
float soundDirection() { float d = g_dir; return d > 1 ? 1 : (d < -1 ? -1 : d); }
int   soundClipping() { return g_clip; }

int soundTakeEvents()
{
  __disable_irq();
  int e = g_events; g_events = 0;
  __enable_irq();
  return e;
}
