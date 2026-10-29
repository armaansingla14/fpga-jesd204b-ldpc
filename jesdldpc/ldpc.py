"""Quasi-cyclic LDPC code, encoder and min-sum decoders.

Code: rate-1/2 QC-LDPC, base matrix 4 x 8, lifting factor Z = 16
(n = 128, k = 64). The parity part is dual-diagonal (IRA style), so
encoding is an accumulation of cyclically shifted message blocks and needs
no matrix inversion.

Shift convention: base entry s >= 0 is the Z x Z identity cyclically
shifted so that check row r of the block connects to variable column
(r + s) mod Z. Entry -1 is the all-zero block.

Decoders:
  * decode_float  - layered offset min-sum in floating point
  * decode_fixed  - the bit-exact model of rtl/ldpc/ldpc_decoder.sv
Both process the 4 layers in order, stop early when the syndrome is zero
and report the number of iterations used.
"""
from __future__ import annotations

import numpy as np

Z = 16
MB, NB = 4, 8
KB = NB - MB
N, K = NB * Z, KB * Z

# Information part chosen by `scripts/gen_code.py --search`: best of 200
# girth >= 6 candidates (seeded search) on a short Monte-Carlo FER run.
# Column weights 3,3,3,2. Parity part is dual-diagonal with zero shifts.
BASE_INFO = np.array([
    [6, 13, 3, -1],
    [7, -1, 5, 3],
    [-1, 6, 9, 14],
    [11, 12, -1, -1],
])


def base_matrix() -> np.ndarray:
    b = -np.ones((MB, NB), dtype=int)
    b[:, :KB] = BASE_INFO
    for i in range(MB):
        b[i, KB + i] = 0
        if i > 0:
            b[i, KB + i - 1] = 0
    return b


BASE = base_matrix()


def edges() -> list[tuple[int, int, int]]:
    """(row, col, shift) for every non-zero block, row-major order."""
    return [(r, c, int(BASE[r, c])) for r in range(MB) for c in range(NB) if BASE[r, c] >= 0]


EDGES = edges()


def H() -> np.ndarray:
    h = np.zeros((MB * Z, N), dtype=np.uint8)
    for r, c, s in EDGES:
        for i in range(Z):
            h[r * Z + i, c * Z + (i + s) % Z] = 1
    return h


def girth_ok(base: np.ndarray, z: int = Z) -> bool:
    """True if the lifted graph has no 4-cycles."""
    rows, cols = base.shape
    for r1 in range(rows):
        for r2 in range(r1 + 1, rows):
            for c1 in range(cols):
                for c2 in range(c1 + 1, cols):
                    a, b, c, d = base[r1, c1], base[r1, c2], base[r2, c1], base[r2, c2]
                    if min(a, b, c, d) < 0:
                        continue
                    if (a - b + d - c) % z == 0:
                        return False
    return True


def _rot(block: np.ndarray, s: int) -> np.ndarray:
    """out[..., r] = block[..., (r + s) % Z]"""
    return np.roll(block, -s, axis=-1)


def encode(msg: np.ndarray) -> np.ndarray:
    """msg: (..., K) bits -> codeword (..., N)."""
    msg = np.asarray(msg, dtype=np.uint8)
    blocks = msg.reshape(msg.shape[:-1] + (KB, Z))
    parity = np.zeros(msg.shape[:-1] + (MB, Z), dtype=np.uint8)
    prev = np.zeros(msg.shape[:-1] + (Z,), dtype=np.uint8)
    for r in range(MB):
        lam = np.zeros_like(prev)
        for c in range(KB):
            s = BASE[r, c]
            if s >= 0:
                lam ^= _rot(blocks[..., c, :], s)
        prev = lam ^ prev
        parity[..., r, :] = prev
    return np.concatenate([msg, parity.reshape(msg.shape[:-1] + (MB * Z,))], axis=-1)


def syndrome(bits: np.ndarray) -> np.ndarray:
    """bits (..., N) -> (..., MB*Z) parity checks."""
    v = bits.reshape(bits.shape[:-1] + (NB, Z))
    out = np.zeros(bits.shape[:-1] + (MB, Z), dtype=np.uint8)
    for r, c, s in EDGES:
        out[..., r, :] ^= _rot(v[..., c, :], s)
    return out.reshape(bits.shape[:-1] + (MB * Z,))


# ---------------------------------------------------------------------------
# Fixed-point format shared with the RTL
# ---------------------------------------------------------------------------
LLR_BITS = 6      # channel LLR, signed, saturated to +-31
APP_BITS = 8      # posterior L, signed, saturated to +-127
MSG_MAX = 31      # check-to-variable magnitude limit (5 bits + sign)
OFFSET = 1        # offset min-sum correction, in LSBs
LLR_SCALE = 2.0   # LSBs per natural-log LLR unit used by quantize_llr

APP_MAX = 2 ** (APP_BITS - 1) - 1
LLR_MAX = 2 ** (LLR_BITS - 1) - 1


def quantize_llr(llr: np.ndarray, scale: float = LLR_SCALE) -> np.ndarray:
    return np.clip(np.round(llr * scale), -LLR_MAX, LLR_MAX).astype(np.int32)


def _layer_fixed(L: np.ndarray, R: dict, row: int) -> None:
    """One layer of offset min-sum on integer arrays; L is (F, NB, Z)."""
    row_edges = [(c, s) for r, c, s in EDGES if r == row]
    Q = []
    for c, s in row_edges:
        q = _rot(L[:, c, :], s) - R[(row, c)]
        Q.append(np.clip(q, -APP_MAX, APP_MAX))
    Q = np.stack(Q, axis=1)                         # (F, deg, Z)
    mag = np.abs(Q)
    sign_neg = Q < 0
    idx = np.argmin(mag, axis=1)                    # first minimum wins
    min1 = np.take_along_axis(mag, idx[:, None, :], axis=1)[:, 0, :]
    mag2 = mag.copy()
    np.put_along_axis(mag2, idx[:, None, :], np.iinfo(np.int32).max, axis=1)
    min2 = mag2.min(axis=1)
    parity = np.bitwise_xor.reduce(sign_neg, axis=1)
    for k, (c, s) in enumerate(row_edges):
        m = np.where(idx == k, min2, min1)
        m = np.clip(m - OFFSET, 0, MSG_MAX)
        neg = parity ^ sign_neg[:, k, :]
        rnew = np.where(neg, -m, m)
        R[(row, c)] = rnew
        lnew = np.clip(Q[:, k, :] + rnew, -APP_MAX, APP_MAX)
        L[:, c, :] = np.roll(lnew, s, axis=-1)       # inverse rotation


def decode_fixed(llr_q: np.ndarray, max_iter: int = 10) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Bit-exact model of the RTL decoder.

    llr_q: (F, N) integer channel LLRs (positive = bit 0).
    Returns (hard bits (F, N), iterations used (F,), converged (F,)).
    """
    llr_q = np.atleast_2d(np.asarray(llr_q, dtype=np.int32))
    F = llr_q.shape[0]
    L = llr_q.reshape(F, NB, Z).copy()
    R = {(r, c): np.zeros((F, Z), dtype=np.int32) for r, c, _ in EDGES}
    iters = np.full(F, max_iter, dtype=np.int32)
    done = np.zeros(F, dtype=bool)
    hard_out = np.zeros((F, N), dtype=np.uint8)
    for it in range(1, max_iter + 1):
        active = ~done
        if not active.any():
            break
        La = L[active]
        Ra = {k: v[active] for k, v in R.items()}
        for row in range(MB):
            _layer_fixed(La, Ra, row)
        L[active] = La
        for k in R:
            R[k][active] = Ra[k]
        hard = (L.reshape(F, N) < 0).astype(np.uint8)
        ok = ~syndrome(hard).any(axis=1)
        newly = active & ok
        iters[newly] = it
        hard_out[active] = hard[active]
        done |= newly
    return hard_out, iters, done


def decode_float(llr: np.ndarray, max_iter: int = 10, offset: float = 0.5) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Floating-point layered offset min-sum (no saturation)."""
    llr = np.atleast_2d(np.asarray(llr, dtype=np.float64))
    F = llr.shape[0]
    L = llr.reshape(F, NB, Z).copy()
    R = {(r, c): np.zeros((F, Z)) for r, c, _ in EDGES}
    iters = np.full(F, max_iter, dtype=np.int32)
    done = np.zeros(F, dtype=bool)
    hard_out = np.zeros((F, N), dtype=np.uint8)
    for it in range(1, max_iter + 1):
        active = ~done
        if not active.any():
            break
        for row in range(MB):
            row_edges = [(c, s) for r, c, s in EDGES if r == row]
            Q = np.stack([_rot(L[:, c, :], s) - R[(row, c)] for c, s in row_edges], axis=1)
            mag = np.abs(Q)
            idx = np.argmin(mag, axis=1)
            min1 = np.take_along_axis(mag, idx[:, None, :], axis=1)[:, 0, :]
            mag2 = mag.copy()
            np.put_along_axis(mag2, idx[:, None, :], np.inf, axis=1)
            min2 = mag2.min(axis=1)
            sgn = np.where(Q < 0, -1.0, 1.0)
            prod = np.prod(sgn, axis=1)
            for k, (c, s) in enumerate(row_edges):
                m = np.maximum(np.where(idx == k, min2, min1) - offset, 0.0)
                rnew = prod * sgn[:, k, :] * m
                upd = active[:, None]
                R[(row, c)] = np.where(upd, rnew, R[(row, c)])
                L[:, c, :] = np.where(upd, np.roll(Q[:, k, :] + rnew, s, axis=-1), L[:, c, :])
        hard = (L.reshape(F, N) < 0).astype(np.uint8)
        ok = ~syndrome(hard).any(axis=1)
        newly = active & ok
        iters[newly] = it
        hard_out[active] = hard[active]
        done |= newly
    return hard_out, iters, done


def awgn_llr(codewords: np.ndarray, ebn0_db: float, rng: np.random.Generator,
             rate: float = K / N) -> np.ndarray:
    """BPSK (0 -> +1) over AWGN; returns channel LLRs 2y/sigma^2."""
    ebn0 = 10 ** (ebn0_db / 10)
    sigma2 = 1.0 / (2 * rate * ebn0)
    x = 1.0 - 2.0 * codewords
    y = x + rng.normal(0.0, np.sqrt(sigma2), size=x.shape)
    return 2.0 * y / sigma2
