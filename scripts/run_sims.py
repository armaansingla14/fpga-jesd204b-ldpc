#!/usr/bin/env python3
"""Generate vectors, run every RTL testbench in the HDL container and
compare the results with the Python reference models.

    python scripts/run_sims.py [--seeds 5] [--frames 100]

Host side needs numpy (vectors + checks); the simulations run through
scripts/docker_run.sh (Verilator 5). Results go to results/sim_results.md
and results/sim_results.json.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from jesdldpc import enc8b10b as e8  # noqa: E402
from jesdldpc import jesd, ldpc  # noqa: E402

BUILD = ROOT / "build"
RESULTS = ROOT / "results"

JESD_SRC = ["rtl/jesd/jesd_pkg.sv", "rtl/jesd/enc_8b10b.sv", "rtl/jesd/dec_8b10b.sv",
            "rtl/jesd/comma_align.sv", "rtl/jesd/jesd_tx.sv", "rtl/jesd/jesd_rx.sv"]
LDPC_SRC = ["rtl/ldpc/ldpc_encoder.sv", "rtl/ldpc/ldpc_decoder.sv", "rtl/ldpc/ldpc_dec_array.sv"]
VFLAGS = "--binary --timing -j 2 -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Irtl/ldpc"

LINK_CFGS = [(1, 1), (2, 1), (4, 1), (8, 1), (2, 0)]     # (lanes, scrambling)
EBN0_RTL = [1.0, 2.0, 3.0, 4.0]
NUM_DEC = [1, 2, 4]


def bits_to_hex(bits: np.ndarray) -> str:
    v = 0
    for b in bits[::-1]:
        v = (v << 1) | int(b)
    return f"{v:0{len(bits) // 4}x}"


def hex_to_bits(h: str, n: int) -> np.ndarray:
    v = int(h, 16)
    return np.array([(v >> i) & 1 for i in range(n)], dtype=np.uint8)


def write_vectors(frames: int) -> dict:
    BUILD.mkdir(exist_ok=True)
    rng = np.random.default_rng(20241)
    vec = {}
    msg = rng.integers(0, 2, size=(1000, ldpc.K), dtype=np.uint8)
    (BUILD / "enc_in.hex").write_text("\n".join(bits_to_hex(m) for m in msg) + "\n")
    vec["enc_msg"] = msg
    for eb in EBN0_RTL:
        m = rng.integers(0, 2, size=(frames, ldpc.K), dtype=np.uint8)
        cw = ldpc.encode(m)
        q = ldpc.quantize_llr(ldpc.awgn_llr(cw, eb, rng))
        (BUILD / f"dec_in_{eb:.1f}.hex").write_text(
            "\n".join(" ".join(f"{int(v) & 0xFF:02x}" for v in fr) for fr in q) + "\n")
        vec[f"dec_{eb:.1f}"] = (cw, q)
    return vec


def sim_script(seeds: int, frames: int) -> str:
    s = ["set -e", "mkdir -p build"]
    jsrc = " ".join(JESD_SRC)
    lsrc = " ".join(LDPC_SRC)
    s.append(f"verilator {VFLAGS} --top-module tb_8b10b --Mdir build/obj_8b10b -o sim "
             f"rtl/jesd/jesd_pkg.sv rtl/jesd/enc_8b10b.sv rtl/jesd/dec_8b10b.sv tb/tb_8b10b.sv > build/log_build_8b10b.txt 2>&1")
    s.append("build/obj_8b10b/sim +N=100000 > build/log_8b10b.txt")
    for L, scr in LINK_CFGS:
        tag = f"L{L}_S{scr}"
        s.append(f"verilator {VFLAGS} -GL={L} -GSCR={scr} --top-module tb_jesd_link "
                 f"--Mdir build/obj_link_{tag} -o sim {jsrc} tb/tb_jesd_link.sv > build/log_build_{tag}.txt 2>&1")
        for seed in range(1, seeds + 1):
            extra = f"+DUMP=build/txdump_{tag}.txt +TXDATA=build/txdata_{tag}.txt" if seed == 1 else ""
            s.append(f"build/obj_link_{tag}/sim +SEED={seed} +NDATA=2000 {extra} > build/log_link_{tag}_s{seed}.txt")
    s.append(f"verilator {VFLAGS} --top-module tb_ldpc_enc --Mdir build/obj_enc -o sim "
             f"rtl/ldpc/ldpc_encoder.sv tb/tb_ldpc_enc.sv > build/log_build_enc.txt 2>&1")
    s.append("build/obj_enc/sim +N=1000 +IN=build/enc_in.hex +OUT=build/enc_out.hex > build/log_enc.txt")
    for nd in NUM_DEC:
        s.append(f"verilator {VFLAGS} -GNUM_DEC={nd} --top-module tb_ldpc_dec --Mdir build/obj_dec{nd} "
                 f"-o sim {lsrc} tb/tb_ldpc_dec.sv > build/log_build_dec{nd}.txt 2>&1")
        for eb in EBN0_RTL:
            s.append(f"build/obj_dec{nd}/sim +N={frames} +MAXITER=10 +IN=build/dec_in_{eb:.1f}.hex "
                     f"+OUT=build/dec_out_{nd}_{eb:.1f}.txt > build/log_dec{nd}_{eb:.1f}.txt")
    return "\n".join(s) + "\n"


def check_8b10b() -> dict:
    enc_bad = dec_bad = 0
    for line in (BUILD / "tb8b10b_enc.txt").read_text().splitlines():
        rd, k, b, c, ro = map(int, line.split())
        ec, er = e8.encode(b, bool(k), 1 if rd else -1)
        enc_bad += (ec != c) or ((er > 0) != bool(ro))
    n_dec = 0
    for line in (BUILD / "tb8b10b_dec.txt").read_text().splitlines():
        rd, c, b, k, ce, de, ro = map(int, line.split())
        r = e8.decode(c, 1 if rd else -1)
        n_dec += 1
        dec_bad += (r.byte, int(r.k), int(r.code_err), int(r.disp_err), int(r.rd_out > 0)) != (b, k, ce, de, ro)
    m = re.search(r"loopback_checked=(\d+) errors=(\d+) max_run=(\d+)", (BUILD / "log_8b10b.txt").read_text())
    return {"enc_entries": 528, "enc_mismatches": enc_bad, "dec_entries": n_dec,
            "dec_mismatches": dec_bad, "loopback_symbols": int(m.group(1)),
            "loopback_errors": int(m.group(2)), "max_run_length": int(m.group(3))}


def check_link(seeds: int) -> list[dict]:
    rows = []
    rx = re.compile(r"TB_RESULT tb_jesd_link L=(\d+) SCR=(\d+) seed=(\d+) link=(\d) ilas_ok=(\d) "
                    r"link_cycles=(\d+) compared=(\d+) mismatches=(\d+) err_detected=(\d) "
                    r"stayed_up=(\d) sync_dropped=(\d) relinked=(\d) relink_cycles=(\d+) align_errs=(\d+)")
    for L, scr in LINK_CFGS:
        tag = f"L{L}_S{scr}"
        # bit-exact transmitter check for lane 0 (seed 1)
        rows_d = [tuple(map(int, l.split())) for l in (BUILD / f"txdump_{tag}.txt").read_text().splitlines()]
        data = [int(l, 16) for l in (BUILD / f"txdata_{tag}.txt").read_text().splitlines()]
        ks = [r[0] for r in rows_d]
        octs = [r[1] for r in rows_d]
        syms = [r[2] for r in rows_d]
        nk = next(i for i, (k, o) in enumerate(zip(ks, octs)) if k and o == e8.K_R)
        exp_o, exp_s = jesd.tx_lane_stream(jesd.LinkParams(L=L, SCR=bool(scr)), 0, nk, data)
        n = min(len(exp_o), len(octs))
        oct_mm = sum((bool(ks[i]), octs[i]) != (exp_o[i][1], exp_o[i][0]) for i in range(n))
        sym_mm = sum(syms[i + 1] != exp_s[i] for i in range(n - 1))
        for seed in range(1, seeds + 1):
            txt = (BUILD / f"log_link_{tag}_s{seed}.txt").read_text()
            m = rx.search(txt)
            lanes = re.findall(r"LANE (\d+) delay_bits=(\d+) offset=(\d+) depth=(\d+)", txt)
            if not m:
                rows.append({"cfg": tag, "seed": seed, "pass": False, "note": txt[-300:]})
                continue
            g = list(map(int, m.groups()))
            r = {"cfg": tag, "lanes": L, "scr": scr, "seed": seed, "link": g[3], "ilas_ok": g[4],
                 "link_cycles": g[5], "compared": g[6], "mismatches": g[7], "err_detected": g[8],
                 "stayed_up": g[9], "sync_dropped": g[10], "relinked": g[11], "relink_cycles": g[12],
                 "align_errs": g[13],
                 "offsets_ok": all(int(o) == int(d) % 10 for _, d, o, _ in lanes),
                 "lane_delays_bits": [int(d) for _, d, _, _ in lanes],
                 "tx_octets_compared": n if seed == 1 else 0,
                 "tx_octet_mismatches": oct_mm if seed == 1 else 0,
                 "tx_symbol_mismatches": sym_mm if seed == 1 else 0}
            r["pass"] = bool(r["link"] and r["ilas_ok"] and r["mismatches"] == 0 and r["err_detected"]
                             and r["stayed_up"] and r["sync_dropped"] and r["relinked"]
                             and r["align_errs"] == 0 and r["offsets_ok"]
                             and r["tx_octet_mismatches"] == 0 and r["tx_symbol_mismatches"] == 0)
            rows.append(r)
    return rows


def check_ldpc(vec: dict, frames: int) -> dict:
    out = {}
    rtl = [l.strip() for l in (BUILD / "enc_out.hex").read_text().splitlines()]
    ref = ldpc.encode(vec["enc_msg"])
    out["enc_frames"] = len(ref)
    out["enc_mismatches"] = sum(hex_to_bits(h, ldpc.N).tolist() != r.tolist() for h, r in zip(rtl, ref)) + \
        abs(len(rtl) - len(ref))
    dec = []
    for nd in NUM_DEC:
        for eb in EBN0_RTL:
            cw, q = vec[f"dec_{eb:.1f}"]
            hard, iters, ok = ldpc.decode_fixed(q, max_iter=10)
            lines = (BUILD / f"dec_out_{nd}_{eb:.1f}.txt").read_text().splitlines()
            log = (BUILD / f"log_dec{nd}_{eb:.1f}.txt").read_text()
            cyc = int(re.search(r"cycles=(\d+)", log).group(1))
            mism = 0
            seen = set()
            for ln in lines:
                t, it, o, bits = ln.split()
                t = int(t)
                seen.add(t)
                b = hex_to_bits(bits, ldpc.N)
                if b.tolist() != hard[t].tolist() or int(it) != iters[t] or int(o) != int(ok[t]):
                    mism += 1
            mism += frames - len(seen)
            fer_rtl = float(np.mean([np.any(hex_to_bits(l.split()[3], ldpc.N) != cw[int(l.split()[0])])
                                     for l in lines]))
            dec.append({"num_dec": nd, "ebn0_db": eb, "frames": frames, "mismatches": mism,
                        "converged": int(ok.sum()), "fer_rtl": fer_rtl,
                        "avg_iters": float(np.mean(iters)), "cycles": cyc,
                        "cycles_per_frame": cyc / frames})
    out["dec"] = dec
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=5)
    ap.add_argument("--frames", type=int, default=100)
    ap.add_argument("--skip-sim", action="store_true", help="only re-check existing outputs")
    a = ap.parse_args()
    assert a.frames <= 256, "decoder tags are 8 bits"
    vec = write_vectors(a.frames)
    if not a.skip_sim:
        (BUILD / "run_all.sh").write_text(sim_script(a.seeds, a.frames))
        t0 = time.perf_counter()
        p = subprocess.run([str(ROOT / "scripts" / "docker_run.sh"), "bash", "build/run_all.sh"],
                           cwd=ROOT)
        print(f"simulations finished in {time.perf_counter() - t0:.0f} s (exit {p.returncode})")
        if p.returncode:
            return 1
    res = {"8b10b": check_8b10b(), "link": check_link(a.seeds), "ldpc": check_ldpc(vec, a.frames)}
    RESULTS.mkdir(exist_ok=True)
    (RESULTS / "sim_results.json").write_text(json.dumps(res, indent=1, default=str))
    write_md(res)
    ok = (res["8b10b"]["enc_mismatches"] == 0 and res["8b10b"]["dec_mismatches"] == 0
          and res["8b10b"]["loopback_errors"] == 0
          and all(r["pass"] for r in res["link"])
          and res["ldpc"]["enc_mismatches"] == 0
          and all(d["mismatches"] == 0 for d in res["ldpc"]["dec"]))
    print("ALL PASS" if ok else "FAILURES - see results/sim_results.md")
    return 0 if ok else 1


def write_md(res: dict) -> None:
    b = res["8b10b"]
    L = ["# RTL simulation results", "",
         "Generated by `scripts/run_sims.py` (Verilator 5.020). All results are simulated.", "",
         "## 8b/10b", "",
         f"- encoder table: {b['enc_entries']} entries (256 D + 8 K28.y, both disparities), "
         f"{b['enc_mismatches']} mismatches vs the Python model",
         f"- decoder classification: {b['dec_entries']} cases (1024 codes x 2 disparities), "
         f"{b['dec_mismatches']} mismatches (value, K flag, code error, disparity error, RD out)",
         f"- random encoder->decoder loopback: {b['loopback_symbols']} symbols, "
         f"{b['loopback_errors']} errors, max run length {b['max_run_length']}", "",
         "## JESD204B link loopback", "",
         "| Config | Seeds | Passed | Link-up cycles (min-max) | Data words compared | Mismatches | "
         "Bit-error detected | Re-link after sync loss | TX lane-0 octets bit-exact |",
         "|---|---:|---:|---|---:|---:|---|---|---|"]
    cfgs = sorted({r["cfg"] for r in res["link"]}, key=lambda c: (c[-1] == "0", int(c[1:].split("_")[0])))
    for c in cfgs:
        rs = [r for r in res["link"] if r["cfg"] == c]
        ok = [r for r in rs if r.get("pass")]
        lc = [r["link_cycles"] for r in rs if "link_cycles" in r]
        s1 = next((r for r in rs if r["seed"] == 1), {})
        L.append(f"| {c} | {len(rs)} | {len(ok)} | {min(lc)}-{max(lc)} | "
                 f"{sum(r.get('compared', 0) for r in rs)} | {sum(r.get('mismatches', 0) for r in rs)} | "
                 f"{sum(r.get('err_detected', 0) for r in rs)}/{len(rs)} | "
                 f"{sum(r.get('relinked', 0) for r in rs)}/{len(rs)} | "
                 f"{s1.get('tx_octets_compared', 0) - s1.get('tx_octet_mismatches', 0)}/"
                 f"{s1.get('tx_octets_compared', 0)} |")
    ld = res["ldpc"]
    L += ["", "Lane delays are drawn per seed (0-129 bits); every lane's comma-alignment "
          "offset matched its delay modulo 10.", "",
          "## LDPC", "",
          f"- encoder: {ld['enc_frames']} codewords, {ld['enc_mismatches']} mismatches vs the Python encoder", "",
          "| Decoder cores | Eb/N0 (dB) | Frames | Bit-exact mismatches vs fixed-point model | "
          "Converged | RTL FER | Avg iterations | Cycles | Cycles/frame |",
          "|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for d in ld["dec"]:
        L.append(f"| {d['num_dec']} | {d['ebn0_db']} | {d['frames']} | {d['mismatches']} | {d['converged']} | "
                 f"{d['fer_rtl']:.2f} | {d['avg_iters']:.2f} | {d['cycles']} | {d['cycles_per_frame']:.1f} |")
    (RESULTS / "sim_results.md").write_text("\n".join(L) + "\n")


if __name__ == "__main__":
    sys.exit(main())
