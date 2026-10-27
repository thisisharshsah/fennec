#!/usr/bin/env python3
"""
Plot a bedsense session and run the first-pass detectors.

    python tools/plot_session.py data/session_20261026_2130.csv
    python tools/plot_session.py data/night1.csv -t 12 -q

Panels: 1) accelerometer (g)   2) gyro magnitude with detected turns
        3) breathing band (0.1 to 0.7 Hz) with detected breaths
A PNG is saved next to the CSV.
"""
import argparse
import csv
import pathlib
import sys

import numpy as np
from scipy import signal

ACC_G_PER_LSB = 0.061e-3      # +/-2 g full scale
GYR_DPS_PER_LSB = 17.5e-3     # +/-500 dps full scale


def load(path):
    t, acc, gyr, marks = [], [], [], []
    with open(path, newline="") as f:
        rdr = csv.reader(f)
        header = next(rdr)
        has_marker = len(header) >= 8
        for row in rdr:
            if len(row) < 7:
                continue
            try:
                vals = [int(v) for v in row[:7]]
            except ValueError:
                continue
            t.append(vals[0])
            acc.append(vals[1:4])
            gyr.append(vals[4:7])
            if has_marker and len(row) >= 8 and row[7]:
                marks.append((len(t) - 1, row[7]))
    if len(t) < 10:
        sys.exit("Not enough samples in the file.")
    t = (np.array(t, dtype=float) - t[0]) / 1000.0
    acc = np.array(acc, dtype=float) * ACC_G_PER_LSB
    gyr = np.array(gyr, dtype=float) * GYR_DPS_PER_LSB
    return t, acc, gyr, marks


def moving_rms(x, n):
    n = max(int(n), 1)
    k = np.ones(n) / n
    return np.sqrt(np.convolve(x * x, k, mode="same"))


def detect_turns(t, acc, gyr, fs, thr_dps, min_angle_deg):
    """Bursts of rotation that end in a new static orientation."""
    gm = np.linalg.norm(gyr, axis=1)
    env = moving_rms(gm, 0.5 * fs)
    active = env > thr_dps

    # group active samples into events, merging gaps under 2 s
    events = []
    i = 0
    n = len(active)
    while i < n:
        if not active[i]:
            i += 1
            continue
        j = i
        while j < n and (active[j] or (j + int(2 * fs) < n and active[j:j + int(2 * fs)].any())):
            j += 1
        events.append((i, j))
        i = j

    w = int(2 * fs)
    turns, shifts = [], []
    for s, e in events:
        if (e - s) / fs < 0.3:
            continue
        before = acc[max(0, s - w):s]
        after = acc[e:e + w]
        if len(before) < w // 2 or len(after) < w // 2:
            continue
        vb, va = before.mean(axis=0), after.mean(axis=0)
        cosang = np.dot(vb, va) / (np.linalg.norm(vb) * np.linalg.norm(va) + 1e-9)
        ang = float(np.degrees(np.arccos(np.clip(cosang, -1, 1))))
        (turns if ang >= min_angle_deg else shifts).append((t[s], t[e - 1], ang))
    return gm, env, turns, shifts


def still_segments(t, fs, exclude, margin_s=5.0, min_len_s=15.0):
    """Index ranges between movement events, with a margin on each side."""
    cuts = sorted((s - margin_s, e + margin_s) for s, e in exclude)
    segs, start = [], 0.0
    for s, e in cuts:
        if s > start:
            segs.append((start, s))
        start = max(start, e)
    if t[-1] > start:
        segs.append((start, t[-1]))
    out = []
    for s, e in segs:
        if e - s >= min_len_s:
            i0, i1 = int(np.searchsorted(t, s)), int(np.searchsorted(t, e))
            if i1 - i0 >= int(min_len_s * fs):
                out.append((i0, i1))
    return out


def breathing(t, acc, fs, exclude, min_mg=1.0):
    """Band-pass 0.1 to 0.7 Hz inside each still segment (so turn transients
    cannot leak in), keep the axis with most energy, count peaks.

    A rate is only reported when the band has real amplitude (RMS >= min_mg;
    an unloaded board on a desk sits around 0.3 mg) and the peak intervals are
    regular. find_peaks with a relative prominence always finds peaks in pure
    noise, so without this gate every recording "breathes"."""
    if t[-1] < 20:
        return None, None, None, None, None
    segs = still_segments(t, fs, exclude)
    x = np.full(len(t), np.nan)
    if not segs:
        return x, None, None, None, 0.0

    sos = signal.butter(2, [0.1, 0.7], btype="band", fs=fs, output="sos")
    filt = []
    for i0, i1 in segs:
        seg = acc[i0:i1] - acc[i0:i1].mean(axis=0)
        filt.append((i0, i1, signal.sosfiltfilt(sos, seg, axis=0)))

    energy = sum(f.var(axis=0) * (i1 - i0) for i0, i1, f in filt)
    axis = int(np.argmax(energy))

    peaks, intervals = [], []
    edge = int(2 * fs)                      # drop filter edges inside each segment
    for i0, i1, f in filt:
        xs = f[:, axis]
        x[i0:i1] = xs
        pk, _ = signal.find_peaks(xs, distance=int(1.5 * fs), prominence=0.5 * xs.std())
        pk = pk[(pk > edge) & (pk < len(xs) - edge)]
        peaks.extend((pk + i0).tolist())
        intervals.extend(np.diff(t[pk + i0]).tolist())

    peaks = np.array(peaks, dtype=int)
    iv = np.array([v for v in intervals if v < 10])
    band_mg = float(np.sqrt(np.mean(x[np.isfinite(x)] ** 2))) * 1000.0
    rate = None
    if len(iv) >= 3 and band_mg >= min_mg:
        q1, q3 = np.percentile(iv, [25, 75])
        if (q3 - q1) / np.median(iv) < 0.5:          # breaths are roughly regular, noise peaks are not
            rate = 60.0 / np.median(iv)
    return x, axis, peaks, rate, band_mg


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv")
    ap.add_argument("-t", dest="turn_thr", type=float, default=15.0, help="gyro RMS threshold, dps (default 15)")
    ap.add_argument("-a", dest="min_angle", type=float, default=10.0, help="tilt change that counts as a turn, deg (default 10)")
    ap.add_argument("-b", dest="breath_min_mg", type=float, default=1.0,
                    help="smallest 0.1 to 0.7 Hz band RMS (mg) that counts as breathing (default 1.0; an empty board reads about 0.3)")
    ap.add_argument("-q", dest="no_show", action="store_true")
    args = ap.parse_args()

    path = pathlib.Path(args.csv)
    t, acc, gyr, marks = load(path)
    fs = (len(t) - 1) / (t[-1] - t[0])
    print(f"{path.name}: {len(t)} samples, {t[-1]:.1f} s, {fs:.1f} Hz")

    gm, env, turns, shifts = detect_turns(t, acc, gyr, fs, args.turn_thr, args.min_angle)
    print(f"turns detected: {len(turns)}  (small shifts: {len(shifts)})")
    for s, e, a in turns:
        print(f"  turn  {s:7.1f} s -> {e:7.1f} s   tilt change {a:5.1f} deg")
    for i, label in marks:
        print(f"  marker '{label}' at {t[i]:.1f} s")

    exclude = [(s, e) for s, e, _ in turns + shifts]
    bx, axis, peaks, rate, band_mg = breathing(t, acc, fs, exclude, args.breath_min_mg)
    if rate:
        print(f"breathing: about {rate:.1f} breaths/min (axis {'xyz'[axis]}, {len(peaks)} breaths counted, band RMS {band_mg:.2f} mg)")
    elif bx is None:
        print("breathing: recording shorter than 20 s, skipped")
    elif axis is None:
        print("breathing: no still stretch of 15 s or more to estimate from (lie still longer between moves)")
    else:
        print(f"breathing: no estimate; band RMS {band_mg:.2f} mg on axis {'xyz'[axis]} is under -b {args.breath_min_mg:g} "
              f"or the peaks are irregular (empty-board noise is about 0.3 mg)")

    import matplotlib
    if args.no_show:
        matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, ax = plt.subplots(3, 1, figsize=(12, 8), sharex=True)
    for k, lab in enumerate("xyz"):
        ax[0].plot(t, acc[:, k], lw=0.6, label=lab)
    ax[0].set_ylabel("accel (g)")
    ax[0].legend(loc="upper right", ncol=3, fontsize=8)

    ax[1].plot(t, gm, lw=0.5, color="0.6", label="gyro |w|")
    ax[1].plot(t, env, lw=1.0, color="C3", label="0.5 s RMS")
    ax[1].axhline(args.turn_thr, ls=":", color="C3", lw=0.8)
    for s, e, a in turns:
        ax[1].axvspan(s, e, color="C3", alpha=0.25)
        ax[1].text(s, ax[1].get_ylim()[1] * 0.9 if ax[1].get_ylim()[1] > 0 else 1, f"{a:.0f}°", fontsize=8, color="C3")
    for s, e, a in shifts:
        ax[1].axvspan(s, e, color="C1", alpha=0.15)
    ax[1].set_ylabel("rotation (dps)")
    ax[1].legend(loc="upper right", fontsize=8)

    if bx is not None:
        ax[2].plot(t, bx * 1000, lw=0.7, color="C2")
        if rate and peaks is not None and len(peaks):
            ax[2].plot(t[peaks], bx[peaks] * 1000 + 0.3, "v", color="C2", ms=5)
        title = f"breathing band, axis {'xyz'[axis] if axis is not None else '?'}"
        if rate:
            title += f"  ~{rate:.1f} breaths/min  (band RMS {band_mg:.2f} mg)"
        elif axis is not None:
            title += f"  no estimate (band RMS {band_mg:.2f} mg)"
        ax[2].set_title(title, fontsize=10, loc="left")
    ax[2].set_ylabel("0.1 to 0.7 Hz (mg)")
    ax[2].set_xlabel("time (s)")

    for i, label in marks:
        for a_ in ax:
            a_.axvline(t[i], color="k", ls=(0, (5, 3)), lw=0.8, alpha=0.6)
        ax[0].text(t[i], ax[0].get_ylim()[1], label, fontsize=8, rotation=90, va="top")

    fig.suptitle(f"{path.name}   {t[-1]:.0f} s @ {fs:.0f} Hz   turns: {len(turns)}", fontsize=11)
    fig.tight_layout()
    png = path.with_suffix(".png")
    fig.savefig(png, dpi=130)
    print(f"saved {png}")
    if not args.no_show:
        plt.show()


if __name__ == "__main__":
    main()
