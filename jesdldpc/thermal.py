"""First-order FPGA power and junction-temperature model (MODELED).

    Tj = Ta + P_total * theta_JA,eff

P_total = static + transceivers + link-layer logic + LDPC cores + base logic.
Every coefficient below is an assumption chosen to be in a plausible range
for a mid-size 16 nm FPGA; none is taken from a vendor datasheet or from a
measurement. Use the structure, not the absolute numbers, and replace the
coefficients with the vendor power estimator's output for a real design.
"""
from __future__ import annotations

from dataclasses import dataclass

# --- assumed power coefficients ------------------------------------------
P_STATIC_W = 0.60            # device static power at nominal temperature
STATIC_TEMPCO = 0.012        # fractional static-power increase per degC above 25 degC
P_GT_PER_LANE_W = 0.11       # per transceiver channel at ~2.5 Gb/s (TX+RX)
P_GT_PER_GBPS_W = 0.015      # extra per lane per Gb/s of line rate
C_LANE_MW_PER_MHZ = 0.08     # JESD link-layer logic per lane (TX + RX)
C_DEC_MW_PER_MHZ = 0.45      # one layered min-sum core
C_BASE_MW_PER_MHZ = 0.30     # encoder, clocking, glue
TOGGLE = 0.25                # average activity relative to the coefficients


@dataclass(frozen=True)
class Cooling:
    name: str
    theta_ja: float          # degC/W, junction to ambient (effective)


# Assumed effective thermal resistances for a ~35 mm flip-chip BGA.
COOLING = [
    Cooling("no heatsink, still air", 9.5),
    Cooling("passive heatsink, natural convection", 4.8),
    Cooling("heatsink + 200 LFM airflow", 2.6),
]


def power_w(lanes: int, num_dec: int, clk_mhz: float, tj_c: float = 25.0) -> dict:
    line_gbps = clk_mhz * 10 / 1000
    dyn_logic = TOGGLE * clk_mhz * (lanes * C_LANE_MW_PER_MHZ + num_dec * C_DEC_MW_PER_MHZ
                                    + C_BASE_MW_PER_MHZ) / 1000
    gt = lanes * (P_GT_PER_LANE_W + P_GT_PER_GBPS_W * line_gbps)
    static = P_STATIC_W * (1 + STATIC_TEMPCO * max(tj_c - 25.0, 0.0))
    return {"static_w": static, "gt_w": gt, "logic_w": dyn_logic, "total_w": static + gt + dyn_logic}


def junction_temp(lanes: int, num_dec: int, clk_mhz: float, ta_c: float,
                  cooling: Cooling, iters: int = 20) -> tuple[float, dict]:
    """Solve the static-power / temperature coupling by fixed-point iteration."""
    tj = ta_c
    p = power_w(lanes, num_dec, clk_mhz, tj)
    for _ in range(iters):
        p = power_w(lanes, num_dec, clk_mhz, tj)
        tj_new = ta_c + p["total_w"] * cooling.theta_ja
        if abs(tj_new - tj) < 1e-6:
            tj = tj_new
            break
        tj = tj_new
    return tj, p
