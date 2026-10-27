// On-board hearing: log-mel features from the microphone stream and a small
// convolutional classifier whose weights come from ml/train.py (model_weights.h).
// Feature pipeline mirrors ml/features.py exactly.
#pragma once
#include <stdint.h>
#include <stddef.h>

void kwsBegin();
void kwsFeedBlock(const int32_t *left, uint32_t n);   // called from the DMA callback with 24-bit samples
void kwsPoll();                                       // call often: computes frames, runs the model
bool kwsHasModel();
bool kwsTakeDetection(char *label, size_t n, float *score);   // one detection per call
size_t kwsFeaturesJson(char *dst, size_t n, int frame);       // one frame of the current window (debug)
size_t kwsScoresJson(char *dst, size_t n);                    // last scores per class
float  kwsSpectralTilt(int frames);                           // max over the last N frames of mean(high bands) - mean(low bands), log units; clap ~ -1, thud ~ -4
