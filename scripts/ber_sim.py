#!/usr/bin/env python3
"""Monte-Carlo BER/FER of the QC-LDPC code over BPSK/AWGN.

Compares, on the same noise realisations:
  * uncoded BPSK (simulated, plus the closed form Q(sqrt(2 Eb/N0)))
  * floating-point layered offset min-sum
  * the fixed-point decoder model that the RTL matches bit for bit

    python scripts/ber_sim.py [--max-frames 4000] [--min-errors 100]

Writes results/ber_fer.csv, results/ber_fer.md and results/ber_fer.png.
All numbers are simulated.
"""
from __future__ import annotations

import argparse
import csv
import sys
from math import erfc, sqrt
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from jesdldpc import ldpc  # noqa: E402

RESULTS = ROOT / "results"
COLORS = {"uncoded": "#2a78d6", "float": "#eb6834", "fixed": "#1baf7a"}


def run_point(ebn0: float, rng: np.random.Generator, max_frames: int, min_err: int,
              batch: int = 500) -> dict:
    acc = {k: [0, 0] for k in ("unc", "flt", "fix")}   # bit errors, frame errors
    frames = 0
    iters_fix = 0
    while frames < max_frames:
        msg = rng.integers(0, 2, size=(batch, ldpc.K), dtype=np.uint8)
        cw = ldpc.encode(msg)
        llr = ldpc.awgn_llr(cw, ebn0, rng)
        # uncoded reference: same Eb/N0 with rate 1 (sigma scaled accordingly)
        unc_llr = ldpc.awgn_llr(msg, ebn0, rng, rate=1.0)
        unc = (unc_llr < 0).astype(np.uint8)
        hf, _, _ = ldpc.decode_float(llr, max_iter=10)
        hq, it, _ = ldpc.decode_fixed(ldpc.quantize_llr(llr), max_iter=10)
        for key, est, ref in (("unc", unc, msg), ("flt", hf[:, :ldpc.K], msg), ("fix", hq[:, :ldpc.K], msg)):
            e = est != ref
            acc[key][0] += int(e.sum())
            acc[key][1] += int(e.any(axis=1).sum())
        iters_fix += int(it.sum())
        frames += batch
        if min(acc["flt"][1], acc["fix"][1]) >= min_err and frames >= 1000:
            break
    nb = frames * ldpc.K
    return {
        "ebn0_db": ebn0, "frames": frames,
        "ber_uncoded": acc["unc"][0] / nb,
        "ber_uncoded_theory": 0.5 * erfc(sqrt(10 ** (ebn0 / 10))),
        "ber_float": acc["flt"][0] / nb, "fer_float": acc["flt"][1] / frames,
        "ber_fixed": acc["fix"][0] / nb, "fer_fixed": acc["fix"][1] / frames,
        "frame_errors_float": acc["flt"][1], "frame_errors_fixed": acc["fix"][1],
        "avg_iters_fixed": iters_fix / frames,
    }


def plot(rows: list[dict], path: Path) -> None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    x = [r["ebn0_db"] for r in rows]
    fig, axes = plt.subplots(1, 2, figsize=(8.4, 3.4), dpi=110)
    for ax, kind in zip(axes, ("ber", "fer")):
        series = [("uncoded", "Uncoded BPSK", [r["ber_uncoded"] for r in rows])] if kind == "ber" else []
        series += [("float", "Min-sum (float)", [r[f"{kind}_float"] for r in rows]),
                   ("fixed", "Min-sum (fixed, = RTL)", [r[f"{kind}_fixed"] for r in rows])]
        for key, label, ys in series:
            xs = [a for a, b in zip(x, ys) if b > 0]
            yv = [b for b in ys if b > 0]
            ax.semilogy(xs, yv, color=COLORS[key], lw=2, marker="o", ms=4, label=label)
            if key == "uncoded":   # the two decoder curves overlap; legend names them
                ax.annotate("Uncoded", (xs[-1], yv[-1]), textcoords="offset points",
                            xytext=(4, 0), fontsize=7, color="#52514e", va="center")
        ax.set_xlabel("Eb/N0 (dB)", fontsize=8, color="#52514e")
        ax.set_ylabel(kind.upper(), fontsize=8, color="#52514e")
        ax.set_title(f"{kind.upper()}, (128,64) QC-LDPC, 10 iterations", fontsize=9, loc="left")
        ax.grid(True, which="major", color="#e6e5e1", lw=0.6)
        ax.tick_params(labelsize=7, colors="#52514e")
        for s in ("top", "right"):
            ax.spines[s].set_visible(False)
        ax.legend(fontsize=7, frameon=False, loc="lower left")
        ax.set_xlim(min(x) - 0.2, max(x) + 0.9)
    fig.tight_layout()
    fig.savefig(path)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--max-frames", type=int, default=4000)
    ap.add_argument("--min-errors", type=int, default=100)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--plot-only", action="store_true", help="redraw from results/ber_fer.csv")
    a = ap.parse_args()
    if a.plot_only:
        rows = [{k: float(v) for k, v in r.items()} for r in csv.DictReader(open(RESULTS / "ber_fer.csv"))]
        plot(rows, RESULTS / "ber_fer.png")
        return 0
    rng = np.random.default_rng(a.seed)
    rows = []
    for eb in np.arange(0.0, 5.01, 0.5):
        r = run_point(float(eb), rng, a.max_frames, a.min_errors)
        rows.append(r)
        print(f"Eb/N0={eb:.1f} frames={r['frames']} BERunc={r['ber_uncoded']:.2e} "
              f"FERflt={r['fer_float']:.3e} FERfix={r['fer_fixed']:.3e} BERfix={r['ber_fixed']:.2e}")
    RESULTS.mkdir(exist_ok=True)
    with open(RESULTS / "ber_fer.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    md = ["# BER / FER (Monte-Carlo, simulated)", "",
          f"Generated by `scripts/ber_sim.py --max-frames {a.max_frames} --min-errors {a.min_errors} "
          f"--seed {a.seed}`. BPSK over AWGN, (128,64) QC-LDPC, layered offset min-sum, "
          "max 10 iterations. Float and fixed-point decoders see the same noise.", "",
          "| Eb/N0 (dB) | Frames | Uncoded BER | Float BER | Float FER | Fixed BER | Fixed FER | "
          "Fixed avg iters |", "|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for r in rows:
        md.append(f"| {r['ebn0_db']:.1f} | {r['frames']} | {r['ber_uncoded']:.2e} | {r['ber_float']:.2e} | "
                  f"{r['fer_float']:.2e} | {r['ber_fixed']:.2e} | {r['fer_fixed']:.2e} | "
                  f"{r['avg_iters_fixed']:.2f} |")
    md.append("")
    md.append("A value of 0 means no errors were observed in the simulated frames, "
              "not that the error rate is zero.")
    (RESULTS / "ber_fer.md").write_text("\n".join(md) + "\n")
    plot(rows, RESULTS / "ber_fer.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())
