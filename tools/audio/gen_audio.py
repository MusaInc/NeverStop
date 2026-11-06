"""Synthesises every sound in City Swing from code (no samples, no licences).

    python3 tools/audio/gen_audio.py assets/audio [name ...]

Needs numpy + scipy (e.g. a venv: python3 -m venv v && v/bin/pip install numpy scipy).

v2 (2026-11-05): the first set was bare sine tones through one-pole filters and
sounded like test beeps. Every sound is now built the way foley is layered:

  * a transient (the first 5–20 ms: click, crack or thump with a pitch drop),
  * a body (filtered noise shaped by resonant band-passes, plucked strings via
    Karplus-Strong, bubbles as rising damped sines for water),
  * a tail (a short synthetic room or a long city "slap" reverb),
  * gentle saturation and a fade so nothing clicks.

Writes 16-bit WAVs at 44.1 kHz: one-shots mono, ambience/music stereo. Loops
are made seamless by crossfading the tail into the head. Loudness is set per
sound (RMS target + peak ceiling) so the in-game mix stays where it was.
"""
import os
import sys
import wave

import numpy as np
from scipy import signal

SR = 44100
OUT = sys.argv[1] if len(sys.argv) > 1 else "assets/audio"
os.makedirs(OUT, exist_ok=True)
rng = np.random.default_rng(1207)


# ------------------------------------------------------------------ helpers
def t(sec):
    return np.arange(int(sec * SR)) / SR


def n_(sec):
    return int(sec * SR)


def noise(sec):
    return rng.standard_normal(n_(sec))


def pink(sec):
    """1/f noise (Voss-McCartney-ish via FFT shaping)."""
    n = n_(sec)
    f = np.fft.rfft(rng.standard_normal(n))
    k = np.arange(len(f))
    k[0] = 1
    x = np.fft.irfft(f / np.sqrt(k), n)
    return x / (np.std(x) + 1e-9)


def brown(sec):
    x = np.cumsum(rng.standard_normal(n_(sec)))
    x = hp(x, 20)
    return x / (np.std(x) + 1e-9)


def _sos(kind, f, order=2):
    nyq = SR / 2
    if kind == "band":
        lo, hi = max(f[0], 10) / nyq, min(f[1], nyq * 0.98) / nyq
        return signal.butter(order, [lo, hi], btype="band", output="sos")
    return signal.butter(order, min(f, nyq * 0.98) / nyq, btype=kind, output="sos")


def lp(x, f, order=2):
    return signal.sosfilt(_sos("low", f, order), x)


def hp(x, f, order=2):
    return signal.sosfilt(_sos("high", f, order), x)


def bp(x, lo, hi, order=2):
    return signal.sosfilt(_sos("band", (lo, hi), order), x)


def peak(x, f, q=4.0, gain_db=9.0):
    """RBJ peaking EQ (a resonance) at f."""
    a = 10 ** (gain_db / 40)
    w = 2 * np.pi * f / SR
    al = np.sin(w) / (2 * q)
    b = [1 + al * a, -2 * np.cos(w), 1 - al * a]
    aa = [1 + al / a, -2 * np.cos(w), 1 - al / a]
    return signal.lfilter(b, aa, x)


def sweep_bp(x, f0, f1, q=2.5, steps=48, curve=1.0):
    """Band-pass whose centre glides f0 → f1 (log), processed in overlapping blocks."""
    n = len(x)
    out = np.zeros(n)
    blk = max(256, n // steps)
    win = np.hanning(blk * 2)
    for s in range(-blk, n, blk):
        a, b = max(0, s), min(n, s + blk * 2)
        if b <= a:
            continue
        frac = np.clip((s + blk) / n, 0, 1) ** curve
        fc = f0 * (f1 / f0) ** frac
        bw = fc / q
        seg = bp(x[a:b], max(fc - bw / 2, 20), fc + bw / 2)
        w = win[(a - s):(b - s)]
        out[a:b] += seg * w
    return out


def env(n, a, d, curve=5.0):
    """Linear attack a (s), exponential decay over d (s); zero after."""
    e = np.zeros(n)
    na = max(1, int(a * SR))
    nd = max(1, int(d * SR))
    e[:min(na, n)] = np.linspace(0, 1, na)[:n]
    end = min(n, na + nd)
    if end > na:
        e[na:end] = np.exp(-curve * np.linspace(0, 1, end - na))
    return e


def adsr(n, a, hold, r):
    e = np.zeros(n)
    na, nh, nr = int(a * SR), int(hold * SR), int(r * SR)
    e[:na] = np.linspace(0, 1, na) ** 2 if na else 0
    e[na:na + nh] = 1
    tail = min(nr, n - na - nh)
    if tail > 0:
        e[na + nh:na + nh + tail] = np.linspace(1, 0, nr)[:tail] ** 2
    return e


def chirp(sec, f0, f1, curve=3.0):
    """Sine whose pitch falls (or rises) exponentially from f0 to f1."""
    n = n_(sec)
    k = np.exp(-curve * np.linspace(0, 1, n))
    f = f1 + (f0 - f1) * k
    return np.sin(2 * np.pi * np.cumsum(f) / SR)


def thump(sec, f0, f1, decay, curve=6.0):
    """Kick-drum style body hit: pitch-dropping sine with an exponential tail."""
    n = n_(sec)
    return chirp(sec, f0, f1, curve) * env(n, 0.0008, decay, 5)


def pluck(sec, f, damp=0.996, bright=0.5):
    """Karplus-Strong string: a taut line / cable twang."""
    n = n_(sec)
    p = max(2, int(SR / f))
    buf = rng.uniform(-1, 1, p)
    buf = lp(buf, 2000 + 6000 * bright, 1)
    out = np.zeros(n)
    for i in range(n):
        j = i % p
        out[i] = buf[j]
        buf[j] = damp * 0.5 * (buf[j] + buf[(j + 1) % p])
    return out


def bubbles(sec, count, fmin, fmax, size=1.0):
    """Minnaert bubbles: short sines that rise in pitch as they decay."""
    n = n_(sec)
    x = np.zeros(n)
    for _ in range(count):
        st = int(rng.uniform(0, sec * 0.8) ** 1.6 / (sec * 0.8) ** 0.6 * SR)
        f = rng.uniform(fmin, fmax)
        d = rng.uniform(0.015, 0.06) * size
        m = n_(d)
        tt = t(d)
        fr = f * (1 + 2.5 * tt / d)
        b = np.sin(2 * np.pi * np.cumsum(fr) / SR) * np.exp(-tt / (d * 0.3))
        e = min(n, st + m)
        x[st:e] += b[: e - st] * rng.uniform(0.3, 1.0)
    return x


def room(x, size=0.35, decay=0.4, mix=0.18, damp=5000, pre=0.008):
    """Synthetic reverb: convolve with a decaying, low-passed noise IR."""
    ln = n_(size + decay)
    ir = rng.standard_normal(ln) * np.exp(-np.linspace(0, 6.5, ln) * (size + decay) / max(decay, 0.05))
    ir = lp(ir, damp, 1)
    # Early reflections.
    for d, g in ((0.007, 0.5), (0.013, 0.35), (0.021, 0.25), (0.034, 0.18)):
        i = n_(d * size / 0.35)
        if i < ln:
            ir[i] += g * 6
    ir = np.concatenate([np.zeros(n_(pre)), ir])
    ir /= np.sqrt(np.sum(ir ** 2)) + 1e-9
    wet = signal.fftconvolve(x, ir)[: len(x) + len(ir) - 1]
    dry = np.concatenate([x, np.zeros(len(wet) - len(x))])
    return dry * (1 - mix) + wet * mix * 2.0


def sat(x, drive=1.5):
    return np.tanh(x * drive) / np.tanh(drive)


def fade(x, a=0.002, r=0.02):
    x = x.copy()
    na, nr = n_(a), n_(r)
    if na:
        x[:na] *= np.linspace(0, 1, na)
    if nr and nr < len(x):
        x[-nr:] *= np.linspace(1, 0, nr) ** 2
    return x


def trim(x, floor=1e-3):
    """Drop silent tail."""
    idx = np.where(np.abs(x) > floor * np.max(np.abs(x)))[0]
    return x[: idx[-1] + 1] if len(idx) else x


def level(x, rms_db, peak_ceiling=0.95):
    """Scale to an RMS target (dBFS, measured over the loud part), peak-limited."""
    x = x - np.mean(x)
    a = np.abs(x)
    loud = x[a > 0.1 * a.max()] if a.max() > 0 else x
    rms = np.sqrt(np.mean(loud ** 2)) + 1e-12
    x = x * (10 ** (rms_db / 20) / rms)
    pk = np.max(np.abs(x))
    if pk > peak_ceiling:  # soft limit the overs instead of hard scaling everything
        x = np.tanh(x / peak_ceiling * 1.2) / np.tanh(1.2) * peak_ceiling
    return x


def loopify(x, fade_s=0.5):
    n = n_(fade_s)
    if x.ndim == 1:
        head = x[:n].copy()
        tail = x[-n:]
        w = np.sin(np.linspace(0, np.pi / 2, n)) ** 2
        y = x[:-n].copy()
        y[:n] = head * w + tail * (1 - w)
        return y
    return np.stack([loopify(x[:, c], fade_s) for c in range(x.shape[1])], axis=1)


def place(dst, src, at, gain=1.0):
    i = n_(at)
    e = min(len(dst), i + len(src))
    if e > i:
        dst[i:e] += src[: e - i] * gain


def write(name, x, stereo=False):
    x = np.clip(np.nan_to_num(x), -1, 1)
    data = (x * 32767).astype(np.int16)
    with wave.open(os.path.join(OUT, name), "wb") as w:
        w.setnchannels(2 if stereo else 1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())
    print(f"AUDIO {name} {len(x) / SR:.2f}s")


def shot(name, x, rms_db, tail=0.03):
    write(name, fade(trim(level(x, rms_db)), 0.0005, tail))


def stereo_wide(x, delay=0.011, decor=True):
    r = np.roll(x, n_(delay))
    if decor:
        r = 0.85 * r + 0.15 * lp(x, 900)
    return np.stack([x, r], axis=1)


# ---------------------------------------------------------------- web / rope
def grapple_fire():
    """The web shot: a tight airy 'thwip' – resonant noise sweeping down fast,
    a soft pneumatic pop, and a faint stringy zip as the line pays out."""
    d = 0.3
    n = n_(d)
    air = sweep_bp(pink(d), 5200, 1300, q=3.0, curve=0.6) * env(n, 0.003, 0.2, 4)
    hiss = hp(noise(d), 6000) * env(n, 0.001, 0.06, 6) * 0.35
    pop = thump(d, 320, 90, 0.05) * 0.6 + lp(noise(d), 1200) * env(n, 0.0005, 0.012) * 0.9
    zip_ = hp(pluck(d, 1180, 0.985, 0.9), 900) * env(n, 0.004, 0.16, 4) * 0.18
    x = air * 1.2 + hiss + pop + zip_
    shot("grapple_fire.wav", room(sat(x, 1.3), 0.25, 0.2, 0.12), -15)


def grapple_attach():
    """Web catching a wall: a sticky 'thack', a muted thud through the line, and
    the line going taut – a low cable twang that dies quickly."""
    d = 0.42
    n = n_(d)
    thack = bp(noise(d), 600, 4500) * env(n, 0.0005, 0.035, 6) * 1.2
    splat = peak(bp(noise(d), 250, 2200), 900, 2.0, 8) * env(n, 0.002, 0.09, 5) * 0.5
    thud = thump(d, 160, 62, 0.14) * 0.9
    twang = lp(pluck(d, 98, 0.994, 0.35), 1600) * env(n, 0.01, 0.38, 4) * 0.55
    x = sat(thack + splat + thud + twang, 1.6)
    shot("grapple_attach.wav", room(x, 0.3, 0.35, 0.16), -12.5)


def grapple_miss():
    """Web flying off into nothing: thin air whiff falling away, no hit."""
    d = 0.5
    n = n_(d)
    x = sweep_bp(pink(d), 3400, 700, q=2.2, curve=0.8) * env(n, 0.004, 0.42, 3)
    x += hp(noise(d), 5000) * env(n, 0.001, 0.08) * 0.15
    shot("grapple_miss.wav", room(x, 0.4, 0.5, 0.2), -19)


def release():
    """Letting go at speed: a body of air rushing past – swells then falls,
    the band rising as you fly out of the arc. Pitched by speed at runtime."""
    d = 0.62
    n = n_(d)
    body = sweep_bp(pink(d), 380, 1500, q=1.4, curve=0.7)
    top = sweep_bp(noise(d), 1800, 4200, q=2.5, curve=0.9) * 0.3
    shape = adsr(n, 0.11, 0.06, 0.45)
    flutter = 1 + 0.18 * np.sin(2 * np.pi * 23 * t(d)) * shape
    x = (body + top) * shape * flutter
    shot("release_whoosh.wav", room(x, 0.3, 0.3, 0.1), -15, 0.06)


def rope_snap():
    """The line parting: a sharp crack and a bright twang whipping away."""
    d = 0.42
    n = n_(d)
    crack = hp(noise(d), 1500) * env(n, 0.0003, 0.012, 7) * 1.4
    twang = pluck(d, 196, 0.989, 0.8) * env(n, 0.001, 0.35, 4)
    whip = sweep_bp(pink(d), 2500, 600, q=3, curve=0.5) * env(n, 0.005, 0.22) * 0.4
    shot("rope_snap.wav", room(sat(crack + twang + whip, 1.5), 0.3, 0.3, 0.15), -15)


# ------------------------------------------------------------ body / ground
def landing():
    """Two feet landing on a roof: a weighty knock, grit under the soles,
    cloth settling."""
    d = 0.45
    n = n_(d)
    knock = thump(d, 140, 52, 0.12) * 1.1
    slap = bp(noise(d), 300, 2400) * env(n, 0.0005, 0.03, 6) * 0.9
    grit = bp(noise(d), 2000, 8000) * env(n, 0.003, 0.14, 5) * (0.5 + 0.5 * (rng.random(n) > 0.6)) * 0.35
    cloth = bp(pink(d), 500, 3000) * env(n, 0.02, 0.25, 4) * 0.25
    shot("land.wav", room(sat(knock + slap + grit + cloth, 1.4), 0.25, 0.25, 0.1), -12)


def roll():
    """Combat roll: shoulder-hip-feet thumps in sequence under a cloth rush."""
    d = 0.85
    n = n_(d)
    x = np.zeros(n)
    for at, f0, g in ((0.0, 120, 1.0), (0.17, 95, 0.7), (0.34, 110, 0.55), (0.55, 140, 0.6)):
        h = thump(0.2, f0, 50, 0.09) * g + bp(noise(0.2), 400, 2400) * env(n_(0.2), 0.0005, 0.025) * 0.6 * g
        place(x, h, at)
    cloth = bp(pink(d), 600, 4000) * adsr(n, 0.05, 0.2, 0.35) * 0.3
    grit = bp(noise(d), 2500, 8000) * adsr(n, 0.03, 0.4, 0.3) * (rng.random(n) > 0.7) * 0.2
    shot("roll.wav", room(sat(x + cloth + grit, 1.3), 0.3, 0.3, 0.1), -15)


def impact():
    """Hitting a wall hard: a deep body slam, a crunch of concrete grit and a
    little falling debris."""
    d = 0.9
    n = n_(d)
    slam = thump(d, 110, 38, 0.32) * 1.4
    crunch = sat(bp(noise(d), 500, 3500) * env(n, 0.0005, 0.07, 5), 3) * 0.9
    knock = bp(noise(d), 150, 800) * env(n, 0.0005, 0.05) * 0.8
    debris = np.zeros(n)
    for _ in range(14):
        at = rng.uniform(0.08, 0.6)
        g = bp(noise(0.03), 2500, 9000) * env(n_(0.03), 0.0003, 0.02) * rng.uniform(0.1, 0.35)
        place(debris, g, at)
    shot("impact.wav", room(sat(slam + crunch + knock + debris, 1.6), 0.35, 0.45, 0.14), -11)


def bump():
    """Glancing a wall: a padded shoulder thud, cloth brushing concrete."""
    d = 0.35
    n = n_(d)
    x = thump(d, 150, 70, 0.08) + bp(noise(d), 300, 1800) * env(n, 0.0008, 0.03) * 0.5
    x += bp(pink(d), 800, 4000) * env(n, 0.01, 0.18, 4) * 0.25
    shot("bump.wav", room(sat(x, 1.3), 0.25, 0.2, 0.1), -14)


def wall_kick():
    """A shoe planted on a facade and pushed off: tight knock + rubber scuff."""
    d = 0.32
    n = n_(d)
    knock = thump(d, 200, 85, 0.06) + bp(noise(d), 700, 3500) * env(n, 0.0005, 0.02, 6) * 0.9
    scuff = sweep_bp(noise(d), 2800, 1400, q=3, curve=1.0) * env(n, 0.012, 0.16, 4) * 0.4
    shot("wall_kick.wav", room(sat(knock + scuff, 1.4), 0.3, 0.3, 0.12), -13.5)


def knockout():
    """A full-speed crash: big body slam with a low boom, concrete crunch,
    debris, then a muffled ringing that fades (felt more than heard)."""
    d = 2.0
    n = n_(d)
    slam = thump(d, 90, 30, 0.6) * 1.6
    boom = lp(brown(d), 180) * env(n, 0.002, 0.8, 4) * 0.8
    crunch = sat(bp(noise(d), 400, 3000) * env(n, 0.0005, 0.12, 4), 3.5) * 1.0
    debris = np.zeros(n)
    for _ in range(26):
        at = rng.uniform(0.05, 1.0) ** 1.5
        g = bp(noise(0.04), 2000, 9000) * env(n_(0.04), 0.0003, 0.03) * rng.uniform(0.05, 0.3)
        place(debris, g, at)
    ring = lp(np.sin(2 * np.pi * 2900 * t(d)) + 0.4 * np.sin(2 * np.pi * 2937 * t(d)), 3500) \
        * adsr(n, 0.25, 0.3, 1.3) * 0.025
    shot("knockout.wav", room(sat(slam + boom + crunch + debris, 1.5) + ring, 0.5, 0.8, 0.15), -11, 0.2)


def splash():
    """Body into water: a slap on the surface, a churn of spray, then bubbles
    and the water settling."""
    d = 1.6
    n = n_(d)
    slap = bp(noise(d), 300, 5000) * env(n, 0.0005, 0.04, 5) * 1.3 + thump(d, 120, 45, 0.12) * 0.8
    spray = bp(pink(d), 800, 9000) * adsr(n, 0.01, 0.12, 0.7) * 0.6
    churn = lp(brown(d), 700) * adsr(n, 0.02, 0.2, 0.9) * 0.5
    bub = bubbles(d, 140, 350, 1600) * 0.35
    shot("splash.wav", room(sat(slap + spray + churn + bub, 1.3), 0.4, 0.6, 0.12), -13, 0.3)


def footsteps():
    """Three surfaces x 3 variations: heel then toe (two transients ~20 ms
    apart). Concrete: dry click + knock. Gravel (roof membrane/chippings):
    crunchy grain. Grass: soft brush + muffled thud."""
    for surf in ("concrete", "gravel", "grass"):
        for i in range(3):
            d = 0.22
            n = n_(d)
            pitch = (0.93, 1.0, 1.08)[i]
            gap = (0.018, 0.024, 0.021)[i]
            x = np.zeros(n)
            for at, g in ((0.0, 1.0), (gap, 0.55)):
                m = n_(0.12)
                knock = thump(0.12, 180 * pitch, 80 * pitch, 0.035)
                if surf == "concrete":
                    h = knock * 0.8 + bp(noise(0.12), 1500 * pitch, 7000) * env(m, 0.0003, 0.014, 6) * 0.8
                elif surf == "gravel":
                    grain = bp(noise(0.12), 1500, 8000) * env(m, 0.001, 0.07, 4) * (rng.random(m) > 0.55)
                    h = knock * 0.45 + grain * 1.1
                else:
                    h = lp(knock, 600) * 0.7 + bp(pink(0.12), 900, 5000) * env(m, 0.004, 0.08, 4) * 0.6
                place(x, h, at, g)
            r = 0.12 if surf == "concrete" else 0.06
            shot(f"step_{surf}_{i}.wav", room(x, 0.2, 0.15, r), -17, 0.02)


# ---------------------------------------------------------------- UI / score
def _bell(f, d, bright=1.0):
    """Soft FM bell (glassy but warm): carrier f, modulator 3.5 f."""
    tt = t(d)
    n = len(tt)
    idx = 1.6 * bright * np.exp(-tt * 6)
    m = np.sin(2 * np.pi * f * 3.5 * tt) * idx
    x = np.sin(2 * np.pi * f * tt + m) * env(n, 0.002, d, 4)
    x += 0.25 * np.sin(2 * np.pi * f * 2 * tt) * env(n, 0.002, d * 0.5, 5)
    return x


def _midi(m):
    return 440 * 2 ** ((m - 69) / 12)


def checkpoint():
    """Ring passed / perfect release: two quick rising bell notes (pitched up a
    semitone per streak at runtime), a soft shimmer."""
    d = 0.9
    x = np.zeros(n_(d))
    place(x, _bell(_midi(79), 0.7), 0.0, 0.8)
    place(x, _bell(_midi(86), 0.75), 0.07, 0.9)
    x += hp(noise(d), 7000) * env(n_(d), 0.001, 0.12) * 0.04
    shot("checkpoint.wav", room(x, 0.5, 0.6, 0.25, 7000), -16, 0.1)


def finish():
    """Course complete: a bright rising major arpeggio landing on a held chord."""
    d = 2.4
    x = np.zeros(n_(d))
    notes = (69, 73, 76, 81)
    for k, m in enumerate(notes):
        place(x, _bell(_midi(m), 1.4), k * 0.085, 0.75)
    for m in (69, 76, 81, 85):  # the held chord
        place(x, _bell(_midi(m), 2.0, 0.6), 0.36, 0.45)
    shot("finish.wav", room(x, 0.6, 1.0, 0.3, 7000), -15, 0.3)


def fail():
    """Run over: two falling, muffled notes – disappointing, not harsh."""
    d = 1.3
    x = np.zeros(n_(d))
    place(x, lp(_bell(_midi(64), 0.8, 0.5), 2200), 0.0, 0.8)
    place(x, lp(_bell(_midi(59), 1.0, 0.4), 1800), 0.18, 0.9)
    shot("fail.wav", room(x, 0.5, 0.7, 0.25, 5000), -17, 0.2)


def ui_click():
    """Menu tick: a short soft wooden click, not a beep."""
    d = 0.08
    n = n_(d)
    x = bp(noise(d), 1200, 6000) * env(n, 0.0003, 0.008, 6) * 0.8
    x += np.sin(2 * np.pi * 1100 * t(d)) * env(n, 0.0005, 0.025, 6) * 0.35
    x += thump(d, 400, 200, 0.015) * 0.3
    shot("ui_click.wav", room(x, 0.15, 0.1, 0.08), -19, 0.01)


# ------------------------------------------------------------ city / loops
def horn():
    """A car horn a block away: two-tone, slightly distorted, bounced off the
    street canyon."""
    d = 0.75
    n = n_(d)
    tt = t(d)
    tone = sum(signal.sawtooth(2 * np.pi * f * tt * (1 + 0.003 * np.sin(2 * np.pi * 6 * tt))) for f in (392, 494))
    x = peak(bp(sat(tone, 2.0), 300, 3000), 1400, 2, 6) * adsr(n, 0.015, 0.32, 0.12)
    x = lp(x, 2500)
    shot("horn.wav", room(x, 0.9, 1.0, 0.35, 3500, 0.03), -18, 0.15)


def thunder():
    """A close crack splitting into a long rolling rumble."""
    d = 7.0
    n = n_(d)
    crack = sat(bp(noise(d), 300, 4000) * env(n, 0.003, 0.25, 6), 2.5) * 0.7
    crackle = np.zeros(n)
    for _ in range(40):
        at = rng.uniform(0.0, 1.2) ** 1.3
        g = bp(noise(0.05), 400, 3000) * env(n_(0.05), 0.001, 0.04) * rng.uniform(0.1, 0.5)
        place(crackle, g, at)
    roll_ = lp(brown(d), 140) * 2.0
    rollenv = adsr(n, 0.3, 1.5, 5.0) * (0.55 + 0.45 * np.abs(lp(noise(d), 1.5)) / 0.3).clip(0, 1.6)
    shot("thunder.wav", room(crack + crackle + roll_ * rollenv, 1.2, 2.5, 0.3, 2500), -12, 0.5)


def _passby(d, f_peak, dur):
    """One vehicle passing: tyre noise + engine hum, swelling and fading with
    a slight doppler drop."""
    n = n_(d)
    tt = t(d)
    c = d / 2
    a = np.exp(-((tt - c) / (dur / 2.2)) ** 2)
    tyre = bp(pink(d), 300, 2000) * a
    f = f_peak * (1 + 0.06 * np.tanh(-(tt - c) * 3))
    eng = signal.sawtooth(2 * np.pi * np.cumsum(f) / SR) * a * 0.25
    return lp(tyre + lp(eng, 400), 2400)


def traffic_loop():
    """Street-level traffic: a bed of rumble with individual cars swishing by."""
    d = 14.0
    n = n_(d)
    bed = lp(brown(d), 200) * 0.7 + bp(pink(d), 400, 1800) * 0.15
    x = bed.copy()
    for _ in range(14):
        at = rng.uniform(-1, d - 2)
        pb = _passby(4.0, rng.uniform(60, 110), rng.uniform(1.4, 2.6)) * rng.uniform(0.6, 1.4)
        if at < 0:
            pb = pb[n_(-at):]
            at = 0
        place(x, pb, at)
    x = loopify(x, 1.5)
    write("traffic_loop.wav", level(x, -19))


def city_ambience():
    """The city from above: distant traffic wash, a far siren now and then,
    wind across rooftops – wide stereo."""
    sec = 24.0
    n = n_(sec)
    tt = t(sec)
    l = lp(brown(sec), 260) * 0.9 + bp(pink(sec), 300, 2200) * 0.18
    r = lp(brown(sec), 260) * 0.9 + bp(pink(sec), 300, 2200) * 0.18
    for start in (5.0, 15.5):  # far sirens (wail), heavily filtered
        d = 4.0
        f = 760 + 220 * np.sin(2 * np.pi * 0.35 * t(d))
        s = np.sin(2 * np.pi * np.cumsum(f) / SR) * adsr(n_(d), 1.2, 1.2, 1.6)
        s = lp(s, 1400) * 0.05
        place(l, s, start, 0.8)
        place(r, s, start + 0.02, 1.0)
    for start in rng.uniform(0, sec - 1.5, 5):  # distant horns
        h = lp(sum(signal.sawtooth(2 * np.pi * f * t(0.4)) for f in (415, 523)) * adsr(n_(0.4), 0.01, 0.25, 0.1), 900)
        place(l if rng.random() > 0.5 else r, room(h, 0.9, 1.0, 0.5, 2000)[: n_(1.5)], start, 0.025)
    gust = 0.75 + 0.25 * np.sin(2 * np.pi * tt * 0.06) * np.sin(2 * np.pi * tt * 0.023 + 1)
    l, r = l * gust, r * gust[::-1]
    st = np.stack([l, r], axis=1)
    st = loopify(st, 2.0)
    write("city_ambience.wav", level(st, -19), stereo=True)


def wind_loop():
    """Air past the ears at speed: a broad rush with turbulent gusts and two
    soft whistling resonances that drift. Pitch/volume follow speed at runtime."""
    d = 8.0
    tt = t(d)
    base = pink(d)
    rush = bp(base, 150, 1400) * 1.0
    turb = 0.65 + 0.35 * np.clip(lp(noise(d), 3.0) / 0.25, -1, 1)
    top = bp(noise(d), 1800, 6000) * 0.14 * turb ** 2
    whistle = np.zeros_like(tt)
    for fc, depth, rate in ((620, 90, 0.17), (1150, 140, 0.11)):
        seg = sweep_bp(noise(d), fc, fc + depth, q=18, curve=1.0)
        whistle += seg * (0.5 + 0.5 * np.sin(2 * np.pi * rate * tt)) * 0.8
    x = (rush * turb + top + whistle * 0.35)
    write("wind_loop.wav", level(loopify(x, 1.0), -16))


def rope_tension_loop():
    """Line under load: fibrous stretch noise ringing through the cable's
    resonances, with occasional creaks – no pure tones."""
    d = 4.0
    n = n_(d)
    tt = t(d)
    fib = bp(noise(d), 80, 900)
    for f in (96, 193, 288):  # cable modes
        fib = peak(fib, f, 25, 14)
    fib = lp(fib, 1100) * (0.8 + 0.2 * np.sin(2 * np.pi * 2.3 * tt))
    creak = np.zeros(n)
    for c in rng.uniform(0, d - 0.2, 7):
        ln = 0.12
        m = n_(ln)
        f0 = rng.uniform(260, 520)
        grain = (rng.random(m) > 0.75) * np.sin(2 * np.pi * f0 * t(ln))
        place(creak, bp(grain, 200, 2000) * env(m, 0.01, 0.1, 3), c, 0.2)
    write("rope_tension_loop.wav", level(loopify(fib + creak, 0.4), -19))


def rain_loop():
    """Steady rain on a city: wide hiss, dense patter on hard surfaces, drips
    from ledges – stereo-decorrelated so it surrounds you."""
    d = 12.0
    n = n_(d)

    def side():
        hiss = bp(pink(d), 1200, 9000) * 0.35
        clicks = (rng.random(n) > 0.996) * rng.uniform(-1, 1, n)
        patter = bp(clicks, 1800, 7000) * 3.0
        drips = np.zeros(n)
        for at in rng.uniform(0, d - 0.1, 60):
            m = n_(0.05)
            f = rng.uniform(900, 2400)
            dr = np.sin(2 * np.pi * f * (1 + 1.5 * t(0.05) / 0.05) * t(0.05)) * env(m, 0.0005, 0.03)
            place(drips, dr, at, rng.uniform(0.05, 0.2))
        low = lp(brown(d), 300) * 0.2
        return hiss + patter + drips + low
    st = np.stack([side(), side()], axis=1)
    st = loopify(st, 1.0)
    write("rain_loop.wav", level(st, -17), stereo=True)


def train_loop():
    """Elevated train going by: wheel roar, the double clack of rail joints,
    a faint flange squeal on the curve."""
    d = 8.4
    n = n_(d)
    tt = t(d)
    roar = lp(brown(d), 260) * 1.2 + bp(pink(d), 300, 1600) * 0.35
    clack = np.zeros(n)
    for k in range(12):
        for off, g in ((0.0, 1.0), (0.12, 0.8)):
            m = n_(0.08)
            h = thump(0.08, 260, 110, 0.03) * 0.8 + bp(noise(0.08), 500, 3000) * env(m, 0.0005, 0.025)
            place(clack, h, k * 0.7 + off, g * 1.3)
    squeal = bp(noise(d), 2600, 2900) * 0.3 * (0.5 + 0.5 * np.sin(2 * np.pi * 0.25 * tt)) ** 3
    x = roar + clack + squeal
    write("train_loop.wav", level(loopify(room(x, 0.6, 0.6, 0.15)[:n], 0.7), -17))


def music_loop():
    """Calm, forward-moving ambient bed (Am – F – C – G, 92 bpm, 8 bars):
    a warm detuned pad, a soft plucked arpeggio and a round bass, all in a
    big soft room. The pad is low-passed so it sits under the effects."""
    bpm = 92
    beat = 60 / bpm
    bars = 8
    sec = bars * 4 * beat
    n = n_(sec)
    tt = t(sec)
    chords = [(57, 60, 64, 71), (53, 57, 60, 67), (48, 52, 55, 64), (55, 59, 62, 69)]
    pad = np.zeros(n)
    arp = np.zeros(n)
    bass = np.zeros(n)
    for bar in range(bars):
        ch = chords[bar % 4]
        s = n_(bar * 4 * beat)
        e = n_((bar + 1) * 4 * beat)
        seg = tt[: e - s]
        swell = np.sin(np.pi * np.clip(seg / (4 * beat), 0, 1)) ** 0.8
        for note in ch:
            f = _midi(note)
            v = sum(signal.sawtooth(2 * np.pi * f * seg * (1 + det)) for det in (-0.004, 0.0, 0.0045)) / 3
            pad[s:e] += v * swell * 0.5
        for step in range(8):
            note = ch[[0, 1, 2, 3, 2, 1, 2, 3][step]] + 12
            i = s + n_(step * beat / 2)
            p = pluck(beat * 1.2, _midi(note), 0.997, 0.4) * (0.55 if step % 2 == 0 else 0.38)
            place(arp, p, i / SR)
        f = _midi(ch[0] - 24)
        m = n_(4 * beat)
        b = (np.sin(2 * np.pi * f * t(4 * beat)) + 0.3 * np.sin(2 * np.pi * 2 * f * t(4 * beat))) * adsr(m, 0.04, 2.6, 1.2)
        place(bass, b, bar * 4 * beat)
    pad = lp(pad, 1100, 2)
    arp = lp(arp, 3500)
    left = pad * 0.45 + arp * 0.5 + bass * 0.55
    right = pad * 0.45 + np.roll(arp, n_(0.19)) * 0.45 + bass * 0.55
    wl = room(left, 1.2, 2.2, 0.35, 4000)
    wr = room(right, 1.25, 2.2, 0.35, 4000)
    # Wrap the reverb tail round to the head so the loop is seamless.
    tail_l, tail_r = wl[n:], wr[n:]
    wl, wr = wl[:n].copy(), wr[:n].copy()
    wl[: len(tail_l)] += tail_l[: n]
    wr[: len(tail_r)] += tail_r[: n]
    st = np.stack([wl, wr], axis=1)
    write("music_loop.wav", level(st, -17, 0.85), stereo=True)


ALL = (rain_loop, thunder, train_loop, wind_loop, rope_tension_loop, city_ambience, music_loop, grapple_fire,
       grapple_attach, grapple_miss, release, rope_snap, landing, roll, impact, splash, checkpoint, finish, fail,
       ui_click, wall_kick, knockout, footsteps, bump, horn, traffic_loop)

if __name__ == "__main__":
    # gen_audio.py <outdir> [name ...]: only the named generators (default all).
    only = set(sys.argv[2:])
    for fn in ALL:
        if not only or fn.__name__ in only:
            fn()
    print("AUDIO DONE")
