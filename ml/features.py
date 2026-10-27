"""
The feature pipeline shared by the trainer and the firmware (src/kws.cpp).
Any change here must be mirrored there.

  20 kHz mono int16 -> frames of 512 samples (25.6 ms), hop 256 (12.8 ms),
  Hann window, power spectrum (257 bins), 32 triangular mel bands between
  80 Hz and 8 kHz, natural log of (energy + 1e-6), then subtract the mean
  over the whole window. A window is the last 64 frames (about 0.83 s).
"""
import numpy as np

RATE = 20000
N_FFT = 512
HOP = 256
N_MEL = 32
F_MIN, F_MAX = 80.0, 8000.0
FRAMES = 64
LOG_FLOOR = 1e-6


def hz_to_mel(f):
    return 2595.0 * np.log10(1.0 + f / 700.0)


def mel_to_hz(m):
    return 700.0 * (10.0 ** (m / 2595.0) - 1.0)


def mel_filterbank():
    """(N_MEL, N_FFT//2+1) triangular filters, un-normalized, as the firmware builds them."""
    mels = np.linspace(hz_to_mel(F_MIN), hz_to_mel(F_MAX), N_MEL + 2)
    hz = mel_to_hz(mels)
    bins = np.floor((N_FFT + 1) * hz / RATE).astype(int)
    fb = np.zeros((N_MEL, N_FFT // 2 + 1), dtype=np.float32)
    for m in range(N_MEL):
        lo, c, hi = bins[m], bins[m + 1], bins[m + 2]
        c = max(c, lo + 1)
        hi = max(hi, c + 1)
        for k in range(lo, c):
            fb[m, k] = (k - lo) / (c - lo)
        for k in range(c, hi):
            fb[m, k] = (hi - k) / (hi - c)
    return fb


def hann():
    n = np.arange(N_FFT)
    return (0.5 - 0.5 * np.cos(2 * np.pi * n / N_FFT)).astype(np.float32)   # periodic Hann


_FB = mel_filterbank()
_WIN = hann()


def frame_logmel(frame):
    """One 512-sample float frame (-1..1) -> 32 log-mel values."""
    x = frame.astype(np.float32) * _WIN
    spec = np.fft.rfft(x)
    power = (spec.real ** 2 + spec.imag ** 2).astype(np.float32)
    mel = _FB @ power
    return np.log(mel + LOG_FLOOR)


def logmel(pcm_int16):
    """Whole clip -> (n_frames, N_MEL) log-mel, not yet mean-normalized."""
    x = pcm_int16.astype(np.float32) / 32768.0
    n = (len(x) - N_FFT) // HOP + 1
    return np.stack([frame_logmel(x[i * HOP:i * HOP + N_FFT]) for i in range(n)])


def window(feats, start=None):
    """FRAMES consecutive frames, mean-subtracted, as the model sees them. Pads short clips."""
    if len(feats) < FRAMES:
        feats = np.concatenate([np.repeat(feats[:1], FRAMES - len(feats), axis=0), feats])
    if start is None:
        start = len(feats) - FRAMES
    w = feats[start:start + FRAMES]
    return (w - w.mean()).astype(np.float32)
