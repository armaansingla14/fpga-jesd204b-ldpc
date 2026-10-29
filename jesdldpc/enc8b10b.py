"""8b/10b line code (Widmer-Franaszek) reference model.

Symbols are 10-bit integers with bit 9 = 'a' (first on the wire) down to
bit 0 = 'j', i.e. the 6b sub-block abcdei occupies bits 9..4 and fghj bits
3..0. Running disparity (RD) is represented as -1 or +1.

Only the K28.y control characters are supported, which is the set used by
JESD204B (/R/=K28.0, /A/=K28.3, /Q/=K28.4, /K/=K28.5, /F/=K28.7).
"""
from __future__ import annotations

from dataclasses import dataclass

# 5b/6b: x -> (code for RD-, code for RD+), written abcdei
_6B = {
    0: ("100111", "011000"), 1: ("011101", "100010"), 2: ("101101", "010010"),
    3: ("110001", "110001"), 4: ("110101", "001010"), 5: ("101001", "101001"),
    6: ("011001", "011001"), 7: ("111000", "000111"), 8: ("111001", "000110"),
    9: ("100101", "100101"), 10: ("010101", "010101"), 11: ("110100", "110100"),
    12: ("001101", "001101"), 13: ("101100", "101100"), 14: ("011100", "011100"),
    15: ("010111", "101000"), 16: ("011011", "100100"), 17: ("100011", "100011"),
    18: ("010011", "010011"), 19: ("110010", "110010"), 20: ("001011", "001011"),
    21: ("101010", "101010"), 22: ("011010", "011010"), 23: ("111010", "000101"),
    24: ("110011", "001100"), 25: ("100110", "100110"), 26: ("010110", "010110"),
    27: ("110110", "001001"), 28: ("001110", "001110"), 29: ("101110", "010001"),
    30: ("011110", "100001"), 31: ("101011", "010100"),
}
_K28_6B = ("001111", "110000")

# 3b/4b data: y -> (RD-, RD+), written fghj. 7 has primary and alternate.
_4B = {
    0: ("1011", "0100"), 1: ("1001", "1001"), 2: ("0101", "0101"),
    3: ("1100", "0011"), 4: ("1101", "0010"), 5: ("1010", "1010"),
    6: ("0110", "0110"), 7: ("1110", "0001"),
}
_4B_A7 = ("0111", "1000")
_4B_K = {
    0: ("1011", "0100"), 1: ("0110", "1001"), 2: ("1010", "0101"),
    3: ("1100", "0011"), 4: ("1101", "0010"), 5: ("0101", "1010"),
    6: ("1001", "0110"), 7: ("0111", "1000"),
}

K28 = {y: 0x1C | (y << 5) for y in range(8)}
K_R, K_A, K_Q, K_K, K_F = K28[0], K28[3], K28[4], K28[5], K28[7]


def _disp(bits: str) -> int:
    return 2 * bits.count("1") - len(bits)


def encode(byte: int, k: bool, rd: int) -> tuple[int, int]:
    """Encode one octet. Returns (10-bit symbol, new RD)."""
    x, y = byte & 0x1F, (byte >> 5) & 0x7
    col = 0 if rd < 0 else 1
    six = _K28_6B[col] if k else _6B[x][col]
    d6 = _disp(six)
    rd6 = rd if d6 == 0 else (1 if d6 > 0 else -1)
    col4 = 0 if rd6 < 0 else 1
    if k:
        four = _4B_K[y][col4]
    elif y == 7 and ((rd6 < 0 and x in (17, 18, 20)) or (rd6 > 0 and x in (11, 13, 14))):
        four = _4B_A7[col4]
    else:
        four = _4B[y][col4]
    d4 = _disp(four)
    rd_out = rd6 if d4 == 0 else (1 if d4 > 0 else -1)
    return int(six + four, 2), rd_out


def _build_tables():
    table = {-1: {}, 1: {}}       # rd -> {code: (byte, k, rd_out)}
    for rd in (-1, 1):
        for b in range(256):
            code, rdo = encode(b, False, rd)
            table[rd][code] = (b, False, rdo)
        for y in range(8):
            code, rdo = encode(K28[y], True, rd)
            table[rd][code] = (K28[y], True, rdo)
    return table


TABLE = _build_tables()


@dataclass
class Decoded:
    byte: int
    k: bool
    code_err: bool
    disp_err: bool
    rd_out: int


def decode(code: int, rd: int) -> Decoded:
    """Decode one symbol with the classification used by the RTL:
    valid for current RD -> no error; valid only for the opposite RD ->
    disparity error (RD follows that encoding); otherwise code error (RD
    follows the sign of the symbol's disparity, unchanged if balanced)."""
    if code in TABLE[rd]:
        b, k, rdo = TABLE[rd][code]
        return Decoded(b, k, False, False, rdo)
    if code in TABLE[-rd]:
        b, k, rdo = TABLE[-rd][code]
        return Decoded(b, k, False, True, rdo)
    d = 2 * bin(code).count("1") - 10
    rdo = rd if d == 0 else (1 if d > 0 else -1)
    return Decoded(0, False, True, False, rdo)


def encode_stream(octets, ks, rd: int = -1) -> tuple[list[int], int]:
    out = []
    for b, k in zip(octets, ks):
        c, rd = encode(b, k, rd)
        out.append(c)
    return out, rd


def max_run_length(symbols: list[int]) -> int:
    bits = "".join(f"{s:010b}" for s in symbols)
    best = run = 1
    for i in range(1, len(bits)):
        run = run + 1 if bits[i] == bits[i - 1] else 1
        best = max(best, run)
    return best
