"""JESD204B link-layer subset: reference model.

Covers what the RTL implements: 1 + x^14 + x^15 self-synchronous
scrambler, code group synchronisation (/K/ = K28.5), the 4-multiframe
initial lane alignment sequence (ILAS) with the 14-octet link configuration
in the second multiframe, and the end-of-frame / end-of-multiframe control
character replacement (/F/, /A/) for both scrambled and unscrambled links.

One octet per lane per character clock is modelled (the RTL datapath width).
"""
from __future__ import annotations

from dataclasses import dataclass, field

from . import enc8b10b as e8


# --------------------------------------------------------------------------
# Scrambler: state bit 0 = most recent scrambled bit, bit 14 = S(n-15)
# --------------------------------------------------------------------------
def scramble_octet(d: int, state: int) -> tuple[int, int]:
    out = 0
    for i in range(7, -1, -1):          # MSB first
        bit = ((d >> i) & 1) ^ ((state >> 13) & 1) ^ ((state >> 14) & 1)
        state = ((state << 1) | bit) & 0x7FFF
        out = (out << 1) | bit
    return out, state


def descramble_octet(s: int, state: int) -> tuple[int, int]:
    out = 0
    for i in range(7, -1, -1):
        bit = (s >> i) & 1
        d = bit ^ ((state >> 13) & 1) ^ ((state >> 14) & 1)
        state = ((state << 1) | bit) & 0x7FFF
        out = (out << 1) | d
    return out, state


@dataclass
class LinkParams:
    L: int = 2           # lanes
    F: int = 2           # octets per frame per lane
    K: int = 16          # frames per multiframe
    M: int = 2           # converters (reported in ILAS only)
    N: int = 14          # converter resolution (ILAS only)
    NP: int = 16         # bits per sample (ILAS only)
    S: int = 1
    DID: int = 0x5A
    BID: int = 0x3
    SCR: bool = True
    SUBCLASS: int = 1
    JESDV: int = 1

    @property
    def mf_len(self) -> int:
        return self.F * self.K


def ilas_config(p: LinkParams, lane_id: int) -> list[int]:
    """14 configuration octets (JESD204B table 20), FCHK last."""
    c = [
        p.DID & 0xFF,
        p.BID & 0x0F,
        lane_id & 0x1F,
        (int(p.SCR) << 7) | ((p.L - 1) & 0x1F),
        (p.F - 1) & 0xFF,
        (p.K - 1) & 0x1F,
        (p.M - 1) & 0xFF,
        (p.N - 1) & 0x1F,                       # CS = 0
        ((p.SUBCLASS & 7) << 5) | ((p.NP - 1) & 0x1F),
        ((p.JESDV & 7) << 5) | ((p.S - 1) & 0x1F),
        0x00,                                   # HD = 0, CF = 0
        0x00, 0x00,
    ]
    c.append(sum(c) & 0xFF)
    return c


def ilas_octets(p: LinkParams, lane_id: int) -> list[tuple[int, bool]]:
    """The 4 ILAS multiframes as (octet, is_k) pairs."""
    out = []
    cfg = ilas_config(p, lane_id)
    for mf in range(4):
        for i in range(p.mf_len):
            if i == 0:
                out.append((e8.K_R, True))
            elif i == p.mf_len - 1:
                out.append((e8.K_A, True))
            elif mf == 1 and i == 1:
                out.append((e8.K_Q, True))
            elif mf == 1 and 2 <= i < 16:
                out.append((cfg[i - 2], False))
            else:
                out.append((i & 0xFF, False))   # ramp filler
    return out


@dataclass
class TxLane:
    p: LinkParams
    lane_id: int
    scr_state: int = 0
    pos: int = 0                      # octet position within multiframe
    prev_frame_last: int | None = None

    def data(self, d: int) -> tuple[int, bool]:
        """Map one user octet in the DATA phase to (octet, is_k)."""
        p = self.p
        o = d
        if p.SCR:
            o, self.scr_state = scramble_octet(d, self.scr_state)
        end_frame = (self.pos % p.F) == p.F - 1
        end_mf = self.pos == p.mf_len - 1
        res = (o, False)
        if p.SCR:
            if end_mf and o == 0x7C:
                res = (e8.K_A, True)
            elif end_frame and o == 0xFC:
                res = (e8.K_F, True)
        elif end_frame:
            if self.prev_frame_last is not None and d == self.prev_frame_last:
                res = (e8.K_A, True) if end_mf else (e8.K_F, True)
        if end_frame:
            self.prev_frame_last = d
        self.pos = (self.pos + 1) % p.mf_len
        return res


@dataclass
class RxLane:
    """Reverse of TxLane for the DATA phase (alignment already known)."""
    p: LinkParams
    scr_state: int = 0
    pos: int = 0
    prev_frame_last: int | None = None
    align_errors: int = 0

    def data(self, o: int, k: bool) -> int:
        p = self.p
        end_frame = (self.pos % p.F) == p.F - 1
        end_mf = self.pos == p.mf_len - 1
        if k:
            if (o == e8.K_A and not end_mf) or (o == e8.K_F and not end_frame) or \
               o not in (e8.K_A, e8.K_F):
                self.align_errors += 1
            if p.SCR:
                o = 0x7C if o == e8.K_A else 0xFC
            else:
                o = self.prev_frame_last if self.prev_frame_last is not None else 0
        d = o
        if p.SCR:
            d, self.scr_state = descramble_octet(o, self.scr_state)
        if end_frame:
            self.prev_frame_last = d
        self.pos = (self.pos + 1) % p.mf_len
        return d


def tx_lane_stream(p: LinkParams, lane_id: int, n_k: int, data: list[int],
                   rd: int = -1) -> tuple[list[tuple[int, bool]], list[int]]:
    """Full lane output: n_k x /K/, ILAS, then data. Returns (octets, symbols)."""
    octs = [(e8.K_K, True)] * n_k + ilas_octets(p, lane_id)
    tx = TxLane(p, lane_id)
    octs += [tx.data(d) for d in data]
    syms, _ = e8.encode_stream([o for o, _ in octs], [k for _, k in octs], rd)
    return octs, syms
