#!/usr/bin/env python3
"""
Train the small sound classifier from ml/data/<label>/*.wav and export it
for the firmware as src/model_weights.h.

    bridge/.venv/bin/python ml/train.py                 # all labels found in ml/data
    bridge/.venv/bin/python ml/train.py -e 40 -l quiet,speech,noise,alert,clap,knock,creature

Model: 3 small 3x3 convolutions (stride 2) + global average pool + dense.
About 6k parameters; a few hundred thousand multiply-adds per inference.
"""
import argparse
import pathlib
import random
import sys
import wave

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import features as F  # noqa: E402

HERE = pathlib.Path(__file__).resolve().parent
OUT_H = HERE.parent / "src" / "model_weights.h"


def load_clip(path):
    with wave.open(str(path)) as w:
        assert w.getframerate() == F.RATE, path
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)


def augment(pcm, rng, noise_bank):
    x = pcm.astype(np.float32)
    x *= rng.uniform(0.4, 2.0)                                     # gain
    shift = rng.integers(-F.RATE // 8, F.RATE // 8)                 # time shift up to 125 ms
    x = np.roll(x, shift)
    if noise_bank and rng.random() < 0.5:                           # mix a little room noise
        nz = noise_bank[rng.integers(len(noise_bank))].astype(np.float32)
        x = x + nz[:len(x)] * rng.uniform(0.1, 0.6)
    return np.clip(x, -32768, 32767).astype(np.int16)


def windows_for(pcm, rng, n=2):
    feats = F.logmel(pcm)
    out = []
    for _ in range(n):
        start = rng.integers(0, max(1, len(feats) - F.FRAMES + 1))
        out.append(F.window(feats, start))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-l", dest="labels", help="comma list; default: every folder in ml/data")
    ap.add_argument("-e", dest="epochs", type=int, default=40)
    ap.add_argument("-s", dest="seed", type=int, default=1)
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    random.seed(args.seed)

    import torch
    import torch.nn as nn
    torch.manual_seed(args.seed)

    data_dir = HERE / "data"
    labels = args.labels.split(",") if args.labels else sorted(d.name for d in data_dir.iterdir() if d.is_dir() and not d.name.startswith("_"))
    clips = {lab: sorted((data_dir / lab).glob("*.wav")) for lab in labels}
    for lab in labels:
        print(f"{lab:10s} {len(clips[lab])} clips")
        if len(clips[lab]) < 5:
            sys.exit(f"need at least 5 clips of '{lab}' (have {len(clips[lab])}); record more with ml/record.py")

    # split by clip, 80/20
    train_items, test_items = [], []
    for li, lab in enumerate(labels):
        files = list(clips[lab])
        rng.shuffle(files)
        k = max(1, len(files) // 5)
        test_items += [(f, li) for f in files[:k]]
        train_items += [(f, li) for f in files[k:]]
    noise_bank = [load_clip(f) for f, li in train_items if labels[li] in ("quiet", "noise")][:40]

    def build(items, aug_copies):
        X, y = [], []
        for f, li in items:
            pcm = load_clip(f)
            for w in windows_for(pcm, rng, 1):
                X.append(w); y.append(li)
            for _ in range(aug_copies):
                for w in windows_for(augment(pcm, rng, noise_bank), rng, 1):
                    X.append(w); y.append(li)
        return torch.tensor(np.stack(X))[:, None], torch.tensor(y)

    Xtr, ytr = build(train_items, 4)
    Xte, yte = build(test_items, 0)
    print(f"train windows {len(Xtr)}, test windows {len(Xte)}")

    C = len(labels)
    model = nn.Sequential(
        nn.Conv2d(1, 8, 3, stride=2, padding=1), nn.ReLU(),
        nn.Conv2d(8, 16, 3, stride=2, padding=1), nn.ReLU(),
        nn.Conv2d(16, 32, 3, stride=2, padding=1), nn.ReLU(),
        nn.AdaptiveAvgPool2d(1), nn.Flatten(),
        nn.Linear(32, C),
    )
    opt = torch.optim.Adam(model.parameters(), lr=2e-3, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, args.epochs)
    lossf = nn.CrossEntropyLoss()
    bs = 32
    for ep in range(args.epochs):
        model.train()
        perm = torch.randperm(len(Xtr))
        tot = 0.0
        for i in range(0, len(Xtr), bs):
            idx = perm[i:i + bs]
            opt.zero_grad()
            loss = lossf(model(Xtr[idx]), ytr[idx])
            loss.backward()
            opt.step()
            tot += loss.item() * len(idx)
        sched.step()
        model.eval()
        with torch.no_grad():
            acc = (model(Xte).argmax(1) == yte).float().mean().item() if len(Xte) else float("nan")
        if ep % 5 == 4 or ep == args.epochs - 1:
            print(f"epoch {ep + 1:3d}  loss {tot / len(Xtr):.3f}  test acc {acc:.3f}")

    model.eval()
    with torch.no_grad():
        pred = model(Xte).argmax(1)
    cm = np.zeros((C, C), dtype=int)
    for t, p in zip(yte.tolist(), pred.tolist()):
        cm[t, p] += 1
    print("confusion (rows = truth):")
    for li, lab in enumerate(labels):
        print(f"  {lab:10s} " + " ".join(f"{v:4d}" for v in cm[li]))

    torch.save({"labels": labels, "state": model.state_dict()}, HERE / "model.pt")
    export_header(model, labels)
    print(f"exported {OUT_H.relative_to(HERE.parent)}; rebuild and flash the firmware to use it")


def export_header(model, labels):
    import torch
    convs = [m for m in model if isinstance(m, torch.nn.Conv2d)]
    dense = [m for m in model if isinstance(m, torch.nn.Linear)][0]
    lines = ["// Generated by ml/train.py. Do not edit.", "#pragma once", "#include <stdint.h>", ""]
    lines.append(f"#define KWS_N_CLASSES {len(labels)}")
    lines.append("static const char *KWS_LABELS[KWS_N_CLASSES] = {" + ", ".join(f'"{l}"' for l in labels) + "};")
    lines.append(f"#define KWS_N_CONV {len(convs)}")
    for i, c in enumerate(convs):
        w = c.weight.detach().numpy()          # (out, in, 3, 3)
        b = c.bias.detach().numpy()
        lines.append(f"#define KWS_C{i}_IN {w.shape[1]}")
        lines.append(f"#define KWS_C{i}_OUT {w.shape[0]}")
        lines.append(f"static const float KWS_C{i}_W[{w.size}] = {{" + ",".join(f"{v:.6g}" for v in w.ravel()) + "};")
        lines.append(f"static const float KWS_C{i}_B[{b.size}] = {{" + ",".join(f"{v:.6g}" for v in b) + "};")
    w = dense.weight.detach().numpy(); b = dense.bias.detach().numpy()
    lines.append(f"#define KWS_DENSE_IN {w.shape[1]}")
    lines.append(f"static const float KWS_DENSE_W[{w.size}] = {{" + ",".join(f"{v:.6g}" for v in w.ravel()) + "};")
    lines.append(f"static const float KWS_DENSE_B[{b.size}] = {{" + ",".join(f"{v:.6g}" for v in b) + "};")
    OUT_H.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
