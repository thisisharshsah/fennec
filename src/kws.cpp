#include "kws.h"
#include <Arduino.h>
#include <math.h>
#include <string.h>

#if __has_include("model_weights.h")
#include "model_weights.h"
#define KWS_HAVE_MODEL 1
#else
#define KWS_HAVE_MODEL 0
#define KWS_N_CLASSES 1
static const char *KWS_LABELS[1] = {"none"};
#endif

// feature spec (ml/features.py)
static const int   RATE = 20000, N_FFT = 512, HOP = 256, N_MEL = 32, FRAMES = 64;
static const float F_MIN = 80.0f, F_MAX = 8000.0f, LOG_FLOOR = 1e-6f;
static const int   INFER_EVERY_FRAMES = 16;          // about every 205 ms
static const float DETECT_THRESHOLD = 0.80f;
static const uint32_t DETECT_HOLD_MS = 1500;        // same label not repeated sooner

// audio in: pending blocks from the ISR, 512-sample overlap for framing
static const int PEND = 2048;                        // two DMA blocks
static int16_t  pend[PEND]; static volatile int pendHead = 0, pendTail = 0;
static float    frameBuf[N_FFT]; static int frameFill = 0;

// features ring
static int16_t mel[FRAMES][N_MEL]; static int melHead = 0, melCount = 0, sinceInfer = 0;   // log-mel x 256
static const float MEL_SCALE = 256.0f;
static float   win[N_FFT];
static uint16_t fbLo[N_MEL], fbC[N_MEL], fbHi[N_MEL];

// model scratch
static float scores[KWS_N_CLASSES];
static char  detLabel[16]; static float detScore = 0; static bool detPending = false;
static uint32_t lastDetMs[KWS_N_CLASSES];

// FFT (iterative radix-2, complex, N_FFT points; real input, imag = 0)
static float re[N_FFT], im[N_FFT];
static uint16_t bitrev[N_FFT];
static float twr[N_FFT / 2], twi[N_FFT / 2];

static void fftInit()
{
  int bits = 0; while ((1 << bits) < N_FFT) bits++;
  for (int i = 0; i < N_FFT; i++) {
    int r = 0; for (int b = 0; b < bits; b++) if (i & (1 << b)) r |= 1 << (bits - 1 - b);
    bitrev[i] = (uint16_t)r;
  }
  for (int k = 0; k < N_FFT / 2; k++) { twr[k] = cosf(-2.0f * (float)M_PI * k / N_FFT); twi[k] = sinf(-2.0f * (float)M_PI * k / N_FFT); }
  for (int n = 0; n < N_FFT; n++) win[n] = 0.5f - 0.5f * cosf(2.0f * (float)M_PI * n / N_FFT);
}

static void fft()
{
  for (int i = 0; i < N_FFT; i++) { int j = bitrev[i]; if (j > i) { float t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; } }
  for (int len = 2; len <= N_FFT; len <<= 1) {
    int half = len >> 1, step = N_FFT / len;
    for (int i = 0; i < N_FFT; i += len) {
      for (int k = 0; k < half; k++) {
        float wr = twr[k * step], wi = twi[k * step];
        int a = i + k, b = a + half;
        float xr = re[b] * wr - im[b] * wi, xi = re[b] * wi + im[b] * wr;
        re[b] = re[a] - xr; im[b] = im[a] - xi; re[a] += xr; im[a] += xi;
      }
    }
  }
}

static float hzToMel(float f) { return 2595.0f * log10f(1.0f + f / 700.0f); }
static float melToHz(float m) { return 700.0f * (powf(10.0f, m / 2595.0f) - 1.0f); }

static void melInit()
{
  float m0 = hzToMel(F_MIN), m1 = hzToMel(F_MAX);
  int bins[N_MEL + 2];
  for (int i = 0; i < N_MEL + 2; i++) bins[i] = (int)floorf((N_FFT + 1) * melToHz(m0 + (m1 - m0) * i / (N_MEL + 1)) / RATE);
  for (int m = 0; m < N_MEL; m++) {
    int lo = bins[m], c = bins[m + 1], hi = bins[m + 2];
    if (c < lo + 1) c = lo + 1;
    if (hi < c + 1) hi = c + 1;
    fbLo[m] = lo; fbC[m] = c; fbHi[m] = hi;
  }
}

static void computeFrame()
{
  for (int n = 0; n < N_FFT; n++) { re[n] = frameBuf[n] * win[n]; im[n] = 0; }
  fft();
  int16_t *row = mel[melHead];
  for (int m = 0; m < N_MEL; m++) {
    float acc = 0;
    int lo = fbLo[m], c = fbC[m], hi = fbHi[m];
    for (int k = lo; k < c && k <= N_FFT / 2; k++) acc += (re[k] * re[k] + im[k] * im[k]) * (float)(k - lo) / (float)(c - lo);
    for (int k = c; k < hi && k <= N_FFT / 2; k++) acc += (re[k] * re[k] + im[k] * im[k]) * (float)(hi - k) / (float)(hi - c);
    float v = logf(acc + LOG_FLOOR) * MEL_SCALE;
    row[m] = (int16_t)(v < -32000 ? -32000 : (v > 32000 ? 32000 : v));
  }
  melHead = (melHead + 1) % FRAMES;
  if (melCount < FRAMES) melCount++;
  sinceInfer++;
}

// model
#if KWS_HAVE_MODEL
// activations: input 1x64x32 (read from the ring) -> 8x32x16 -> 16x16x8 -> 32x8x4 (reuses actA)
static float actA[8 * 32 * 16], actB[16 * 16 * 8];
static float inMean = 0;

static inline float inputAt(int f, int m) { return mel[(melHead + f) % FRAMES][m] / MEL_SCALE - inMean; }

static void conv1FromRing(const float *W, const float *B, int cout, float *out)
{
  const int h = FRAMES, w = N_MEL, oh = h / 2, ow = w / 2;
  for (int oc = 0; oc < cout; oc++) {
    const float *wk = W + oc * 9;
    for (int oy = 0; oy < oh; oy++) {
      for (int ox = 0; ox < ow; ox++) {
        float acc = B[oc];
        for (int ky = 0; ky < 3; ky++) {
          int iy = oy * 2 - 1 + ky; if (iy < 0 || iy >= h) continue;
          for (int kx = 0; kx < 3; kx++) {
            int ix = ox * 2 - 1 + kx; if (ix < 0 || ix >= w) continue;
            acc += inputAt(iy, ix) * wk[ky * 3 + kx];
          }
        }
        out[(oc * oh + oy) * ow + ox] = acc > 0 ? acc : 0;
      }
    }
  }
}

static void conv3x3s2(const float *in, int cin, int h, int w, const float *W, const float *B, int cout, float *out)
{
  int oh = (h + 1) / 2, ow = (w + 1) / 2;
  for (int oc = 0; oc < cout; oc++) {
    for (int oy = 0; oy < oh; oy++) {
      for (int ox = 0; ox < ow; ox++) {
        float acc = B[oc];
        for (int ic = 0; ic < cin; ic++) {
          const float *wk = W + ((oc * cin + ic) * 9);
          for (int ky = 0; ky < 3; ky++) {
            int iy = oy * 2 - 1 + ky; if (iy < 0 || iy >= h) continue;
            const float *irow = in + (ic * h + iy) * w;
            for (int kx = 0; kx < 3; kx++) {
              int ix = ox * 2 - 1 + kx; if (ix < 0 || ix >= w) continue;
              acc += irow[ix] * wk[ky * 3 + kx];
            }
          }
        }
        out[(oc * oh + oy) * ow + ox] = acc > 0 ? acc : 0;
      }
    }
  }
}

static void infer()
{
  // oldest frame first, mean-subtracted, like ml/features.window()
  float mean = 0;
  for (int f = 0; f < FRAMES; f++) for (int m = 0; m < N_MEL; m++) mean += mel[f][m];
  inMean = mean / (FRAMES * N_MEL) / MEL_SCALE;
  conv1FromRing(KWS_C0_W, KWS_C0_B, KWS_C0_OUT, actA);
  conv3x3s2(actA, KWS_C0_OUT, 32, 16, KWS_C1_W, KWS_C1_B, KWS_C1_OUT, actB);
  float *actC = actA;                                     // conv3 output fits in conv1's buffer
  conv3x3s2(actB, KWS_C1_OUT, 16, 8, KWS_C2_W, KWS_C2_B, KWS_C2_OUT, actC);
  float pooled[KWS_C2_OUT];
  for (int c = 0; c < KWS_C2_OUT; c++) { float s = 0; for (int i = 0; i < 32; i++) s += actC[c * 32 + i]; pooled[c] = s / 32.0f; }
  float mx = -1e30f;
  for (int k = 0; k < KWS_N_CLASSES; k++) {
    float s = KWS_DENSE_B[k];
    for (int c = 0; c < KWS_DENSE_IN; c++) s += KWS_DENSE_W[k * KWS_DENSE_IN + c] * pooled[c];
    scores[k] = s; if (s > mx) mx = s;
  }
  float sum = 0;
  for (int k = 0; k < KWS_N_CLASSES; k++) { scores[k] = expf(scores[k] - mx); sum += scores[k]; }
  int best = 0;
  for (int k = 0; k < KWS_N_CLASSES; k++) { scores[k] /= sum; if (scores[k] > scores[best]) best = k; }

  const char *lab = KWS_LABELS[best];
  bool background = !strcmp(lab, "quiet") || !strcmp(lab, "noise") || !strcmp(lab, "speech");
  uint32_t now = millis();
  if (!background && scores[best] >= DETECT_THRESHOLD && now - lastDetMs[best] > DETECT_HOLD_MS && !detPending) {
    lastDetMs[best] = now;
    strncpy(detLabel, lab, sizeof detLabel - 1); detLabel[sizeof detLabel - 1] = 0;
    detScore = scores[best]; detPending = true;
  }
}
#endif

void kwsBegin()
{
  fftInit();
  melInit();
  memset(mel, 0, sizeof mel);
}

void kwsFeedBlock(const int32_t *left, uint32_t n)
{
  for (uint32_t i = 0; i < n; i++) {
    int next = (pendHead + 1) % PEND;
    if (next == pendTail) return;                        // main loop fell behind; drop the rest
    pend[pendHead] = (int16_t)((left[i] >> 8) >> 6);
    pendHead = next;
  }
}

void kwsPoll()
{
  int budget = 1024;                                      // at most one DMA block per call
  while (pendTail != pendHead && budget > 0) {
    budget -= 1;
    float v = pend[pendTail] / 32768.0f;
    pendTail = (pendTail + 1) % PEND;
    frameBuf[frameFill++] = v;
    if (frameFill == N_FFT) {
      computeFrame();
      memmove(frameBuf, frameBuf + HOP, (N_FFT - HOP) * sizeof(float));
      frameFill = N_FFT - HOP;
    }
  }
#if KWS_HAVE_MODEL
  if (melCount == FRAMES && sinceInfer >= INFER_EVERY_FRAMES) { sinceInfer = 0; infer(); }
#endif
}

bool kwsHasModel() { return KWS_HAVE_MODEL; }

bool kwsTakeDetection(char *label, size_t n, float *score)
{
  if (!detPending) return false;
  detPending = false;
  strncpy(label, detLabel, n - 1); label[n - 1] = 0; *score = detScore;
  return true;
}

size_t kwsFeaturesJson(char *dst, size_t n, int frame)
{
  if (frame < 0 || frame >= FRAMES) return snprintf(dst, n, "[]");
  const int16_t *row = mel[(melHead + frame) % FRAMES];
  size_t p = snprintf(dst, n, "[");
  for (int m = 0; m < N_MEL && p + 12 < n; m++) p += snprintf(dst + p, n - p, "%s%.3f", m ? "," : "", row[m] / MEL_SCALE);
  if (p + 2 < n) p += snprintf(dst + p, n - p, "]");
  return p;
}

size_t kwsScoresJson(char *dst, size_t n)
{
  size_t p = snprintf(dst, n, "{");
  for (int k = 0; k < KWS_N_CLASSES && p + 24 < n; k++) p += snprintf(dst + p, n - p, "%s\"%s\":%.2f", k ? "," : "", KWS_LABELS[k], scores[k]);
  if (p + 2 < n) p += snprintf(dst + p, n - p, "}");
  return p;
}

float kwsSpectralTilt(int frames)
{
  if (melCount == 0) return -99.0f;
  if (frames > melCount) frames = melCount;
  float best = -99.0f;
  for (int k = 1; k <= frames; k++) {
    const int16_t *row = mel[(melHead - k + FRAMES) % FRAMES];
    float lo = 0, hi = 0;
    for (int m = 0; m < 8; m++) lo += row[m];            // about 80 Hz to 700 Hz
    for (int m = 18; m < N_MEL; m++) hi += row[m];       // about 2.5 kHz to 8 kHz
    float d = (hi / (N_MEL - 18) - lo / 8) / MEL_SCALE;
    if (d > best) best = d;
  }
  return best;
}
