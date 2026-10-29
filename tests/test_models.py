"""Unit tests for the Python reference models."""
import numpy as np
import pytest

from jesdldpc import enc8b10b as e8
from jesdldpc import jesd, ldpc, thermal


# ------------------------------------------------------------------ 8b/10b
def test_known_symbols():
    assert e8.encode(e8.K_K, True, -1)[0] == 0b0011111010
    assert e8.encode(e8.K_K, True, +1)[0] == 0b1100000101
    assert e8.encode(0x00, False, -1)[0] == 0b1001110100    # D0.0 RD-


def test_disparity_and_roundtrip():
    for rd in (-1, 1):
        for code, (b, k, rdo) in e8.TABLE[rd].items():
            d = 2 * bin(code).count("1") - 10
            assert d in (-2, 0, 2)
            if d != 0:
                assert (d > 0) == (rd < 0)          # unbalanced symbols push RD back
            r = e8.decode(code, rd)
            assert (r.byte, r.k, r.code_err, r.disp_err, r.rd_out) == (b, k, False, False, rdo)


def test_run_length_and_no_false_comma():
    rng = np.random.default_rng(0)
    data = rng.integers(0, 256, 20000).tolist()
    syms, _ = e8.encode_stream(data, [False] * len(data))
    assert e8.max_run_length(syms) <= 5
    bits = "".join(f"{s:010b}" for s in syms)
    for comma in ("0011111", "1100000"):
        assert bits.find(comma) == -1           # commas only occur in K28.x


def test_decode_errors():
    assert e8.decode(0, -1).code_err
    k_plus = e8.encode(e8.K_K, True, +1)[0]
    assert e8.decode(k_plus, -1).disp_err


# --------------------------------------------------------------- scrambler
def test_scrambler_inverse_and_self_sync():
    rng = np.random.default_rng(1)
    data = rng.integers(0, 256, 500).tolist()
    st_t, st_r, st_bad = 0, 0, 0x5A5A
    out_ok, out_bad = [], []
    for d in data:
        s, st_t = jesd.scramble_octet(d, st_t)
        r, st_r = jesd.descramble_octet(s, st_r)
        rb, st_bad = jesd.descramble_octet(s, st_bad)
        out_ok.append(r)
        out_bad.append(rb)
    assert out_ok == data
    assert out_bad[2:] == data[2:]              # resynchronised after 15 bits


# ------------------------------------------------------------------- JESD
@pytest.mark.parametrize("scr", [True, False])
def test_link_model_roundtrip(scr):
    p = jesd.LinkParams(L=2, SCR=scr)
    rng = np.random.default_rng(3)
    # low-entropy data makes frame-end replacement frequent
    data = rng.choice([0x00, 0x7C, 0xFC, 0x12], size=3000).tolist()
    tx, rx = jesd.TxLane(p, 0), jesd.RxLane(p)
    sent = [tx.data(d) for d in data]
    assert any(k for _, k in sent)              # replacement actually happened
    got = [rx.data(o, k) for o, k in sent]
    assert got == data and rx.align_errors == 0


def test_ilas_layout():
    p = jesd.LinkParams(L=4, F=2, K=16)
    o = jesd.ilas_octets(p, 3)
    assert len(o) == 4 * 32
    for mf in range(4):
        assert o[mf * 32] == (e8.K_R, True) and o[mf * 32 + 31] == (e8.K_A, True)
    assert o[33] == (e8.K_Q, True)
    cfg = [v for v, _ in o[34:48]]
    assert cfg[2] == 3 and cfg[3] == 0x83 and cfg[13] == sum(cfg[:13]) & 0xFF


# ------------------------------------------------------------------- LDPC
def test_code_structure():
    assert ldpc.girth_ok(ldpc.BASE)
    h = ldpc.H()
    assert h.shape == (64, 128)
    rng = np.random.default_rng(4)
    m = rng.integers(0, 2, (20, ldpc.K), dtype=np.uint8)
    c = ldpc.encode(m)
    assert not ((h.astype(int) @ c.T.astype(int)) % 2).any()
    assert (c[:, :ldpc.K] == m).all()
    # linearity
    assert (ldpc.encode(m[0] ^ m[1]) == (c[0] ^ c[1])).all()


def test_decoders_correct_light_noise():
    rng = np.random.default_rng(5)
    m = rng.integers(0, 2, (50, ldpc.K), dtype=np.uint8)
    c = ldpc.encode(m)
    llr = 4.0 * (1 - 2.0 * c)
    llr[:, 5] *= -1                             # one hard error per frame
    hq, it, ok = ldpc.decode_fixed(ldpc.quantize_llr(llr))
    hf, _, okf = ldpc.decode_float(llr)
    assert ok.all() and okf.all()
    assert (hq == c).all() and (hf == c).all()
    assert it.max() <= 3


def test_quantizer_saturates():
    q = ldpc.quantize_llr(np.array([-100.0, -0.2, 0.0, 0.3, 100.0]))
    assert q.tolist() == [-31, 0, 0, 1, 31]


# ----------------------------------------------------------------- thermal
def test_thermal_monotonic():
    cool = thermal.COOLING[0]
    t1, _ = thermal.junction_temp(1, 1, 122.88, 25.0, cool)
    t8, _ = thermal.junction_temp(8, 4, 245.76, 25.0, cool)
    assert t8 > t1 > 25.0
    t_hs, _ = thermal.junction_temp(8, 4, 245.76, 25.0, thermal.COOLING[2])
    assert t_hs < t8
