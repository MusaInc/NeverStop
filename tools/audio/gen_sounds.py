"""NEVER STOP's sound set, synthesised from code (numpy only: no samples, no
licences to track – every file here is original to this project).

    python3 tools/audio/gen_sounds.py assets/audio

Filters work in the frequency domain (FFT masks), so there's no scipy
dependency. Everything is 16-bit / 44.1 kHz WAV; loops are built from whole
periods of their fundamental (engines, rotors) or crossfaded (noise beds) so
they repeat without a click.

Engines are modelled as exhaust pulse trains: each firing is a short damped
resonant burst; cylinders get slightly different strengths (that unevenness
is what gives a V8 its burble), the train goes through exhaust/intake
formants, a little mechanical noise rides on top. Two layers per engine
(low and high firing rate) are crossfaded and pitch-shifted in Godot by rpm.
"""
import os
import sys
import wave

import numpy as np

SR = 44100
OUT = sys.argv[1] if len(sys.argv) > 1 else "assets/audio"
os.makedirs(OUT, exist_ok=True)
rng = np.random.default_rng(4242)


def tt(sec):
    return np.arange(int(sec * SR)) / SR


def noise(n):
    return rng.standard_normal(n)


def spectral(x, mask_fn):
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / SR)
    return np.fft.irfft(X * mask_fn(f), len(x))


def bp(x, lo, hi, soft=1.5):
    def m(f):
        g = np.ones_like(f)
        with np.errstate(divide="ignore"):
            g *= 1 / (1 + (lo / np.maximum(f, 1e-3)) ** (2 * soft)) if lo > 0 else 1
            g *= 1 / (1 + (f / hi) ** (2 * soft)) if hi else 1
        return g
    return spectral(x, m)


def lp(x, hi, soft=1.5):
    return bp(x, 0, hi, soft)


def hp(x, lo, soft=1.5):
    return bp(x, lo, None, soft)


def peaks(x, freqs, q=6.0, gain=4.0):
    def m(f):
        g = np.ones_like(f)
        for fc in freqs:
            g += gain * np.exp(-((f - fc) / (fc / q)) ** 2)
        return g
    return spectral(x, m)


def env(n, a, d, curve=5.0):
    e = np.ones(n)
    na = max(1, int(a * SR))
    e[:na] = np.linspace(0, 1, na)
    k = np.arange(n - na) / SR
    e[na:] = np.exp(-k / max(d, 1e-4) * curve / 5.0)
    return e


def sat(x, drive=1.5):
    return np.tanh(x * drive) / np.tanh(drive)


def norm(x, peak=0.9):
    m = np.max(np.abs(x)) or 1.0
    return x / m * peak


def level(x, rms_db, peak=0.95):
    rms = np.sqrt(np.mean(x ** 2)) or 1e-9
    x = x * (10 ** (rms_db / 20) / rms)
    m = np.max(np.abs(x))
    if m > peak:
        x = sat(x / m * 1.2, 1.2) * peak
    return x


def fade(x, a=0.003, r=0.02):
    x = x.copy()
    na, nr = int(a * SR), int(r * SR)
    if na:
        x[:na] *= np.linspace(0, 1, na)
    if nr:
        x[-nr:] *= np.linspace(1, 0, nr)
    return x


def loopify(x, fade_s=0.4):
    n = int(fade_s * SR)
    head, body, tail = x[:n], x[n:-n], x[-n:]
    w = np.linspace(0, 1, n)
    return np.concatenate([tail * (1 - w) + head * w, body])


def write(name, x, stereo=False):
    path = os.path.join(OUT, name + ".wav")
    if stereo and x.ndim == 1:
        x = np.stack([x, x], 1)
    data = (np.clip(x, -1, 1) * 32767).astype(np.int16)
    with wave.open(path, "wb") as w:
        w.setnchannels(2 if stereo else 1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())
    print("wrote", path, "%.2fs" % (len(data) / SR))


def room(x, size=0.25, mix=0.2):
    # A handful of early reflections + a noise tail convolved.
    n = int(size * SR)
    ir = np.zeros(n)
    for d, g in [(0.011, 0.5), (0.017, 0.4), (0.029, 0.32), (0.041, 0.25)]:
        k = int(d * SR)
        if k < n:
            ir[k] += g
    ir += noise(n) * np.exp(-np.arange(n) / (n / 5)) * 0.05
    wet = np.convolve(x, ir)[: len(x)]
    return x + wet * mix


# ------------------------------------------------------------------ engines
ENGINES = {
    # cylinders, cylinder unevenness, formants (Hz), noise, burst decay, grit
    "i4": (4, 0.12, [180, 520, 1400], 0.08, 0.006, 1.6),
    "v6": (6, 0.18, [140, 420, 1150], 0.06, 0.007, 1.8),
    "v8": (8, 0.45, [95, 300, 850], 0.05, 0.009, 2.4),
    "f6": (6, 0.25, [210, 640, 1900], 0.05, 0.005, 2.0),
    "v10": (10, 0.2, [260, 780, 2300], 0.04, 0.004, 1.9),
    "diesel": (4, 0.2, [110, 340, 900], 0.18, 0.012, 2.6),
}


def engine_layer(kind, fire_hz, sec=2.0):
    cyl, uneven, formants, nz, decay, grit = ENGINES[kind]
    period = SR / fire_hz
    n_periods = int(round(sec * fire_hz))
    n = int(round(n_periods * period))
    x = np.zeros(n)
    burst_n = int(min(period * 1.8, 0.05 * SR))
    k = np.arange(burst_n) / SR
    strengths = 1 + uneven * (rng.random(cyl) * 2 - 1)
    for i in range(n_periods):
        start = int(round(i * period))
        s = strengths[i % cyl]
        f0 = formants[0] * (1 + 0.05 * (rng.random() - 0.5))
        b = np.sin(2 * np.pi * f0 * k) * np.exp(-k / decay) * s
        b += noise(burst_n) * np.exp(-k / (decay * 0.6)) * 0.35 * s
        end = min(n, start + burst_n)
        x[start:end] += b[: end - start]
        # wrap the overflow to the start so the loop is seamless
        if start + burst_n > n:
            over = start + burst_n - n
            x[:over] += b[burst_n - over:]
    x = peaks(x, formants, q=3.0, gain=3.0)
    mech = bp(noise(n), 1800, 6000) * nz
    x = lp(x, 5000) + mech
    x = sat(norm(x) * grit, 1.0)
    return level(x, -14)


def engines():
    for kind in ENGINES:
        # Low layer: idle/cruise firing; high layer: near redline.
        write("engine_%s_low" % kind, engine_layer(kind, 45.0))
        write("engine_%s_high" % kind, engine_layer(kind, 150.0))


# ------------------------------------------------------------------ tyres, wind
def tyres():
    sec = 3.0
    n = int(sec * SR)
    base = bp(noise(n), 900, 3800, 2)
    base = peaks(base, [1250, 1900, 2700], q=14, gain=8)
    am = 0.75 + 0.25 * np.sin(2 * np.pi * 7.3 * tt(sec)) * np.sin(2 * np.pi * 1.1 * tt(sec))
    x = base * am
    write("tyre_squeal", level(loopify(x, 0.5), -16))
    # Skid on tarmac (scrub): lower, rougher.
    s = bp(noise(n), 200, 1400, 1.5) * (0.8 + 0.2 * np.sin(2 * np.pi * 13 * tt(sec)))
    write("tyre_scrub", level(loopify(s, 0.5), -18))
    w = lp(noise(int(4 * SR)), 700, 1.2) + hp(lp(noise(int(4 * SR)), 3000), 900) * 0.2
    write("wind", level(loopify(w, 0.8), -18))


# ------------------------------------------------------------------ sirens
def siren_tone(freq_curve, sec):
    phase = np.cumsum(freq_curve) / SR * 2 * np.pi
    # A slightly square-ish horn: odd harmonics, through a horn resonance.
    x = np.sin(phase) + 0.35 * np.sin(3 * phase) + 0.18 * np.sin(5 * phase) + 0.08 * np.sin(7 * phase)
    x = peaks(x, [1100, 2400], q=2, gain=1.5)
    return sat(x * 0.8, 1.6)


def sirens():
    sec = 4.0
    t = tt(sec)
    # Wail: slow up/down sweep (two cycles per loop).
    f = 650 + 650 * (0.5 - 0.5 * np.cos(2 * np.pi * t / 2.0))
    write("siren_wail", level(siren_tone(f, sec), -15))
    # Yelp: fast sweep.
    f = 700 + 700 * (0.5 - 0.5 * np.cos(2 * np.pi * t / 0.25))
    write("siren_yelp", level(siren_tone(f, sec), -15))
    # Air horn blast (one-shot).
    t2 = tt(0.7)
    ph = 2 * np.pi * 330 * t2
    h = np.sign(np.sin(ph)) * 0.6 + np.sin(ph * 2.01) * 0.4 + np.sin(ph * 1.5) * 0.3
    h = lp(h, 3000) * env(len(t2), 0.01, 0.6, 1.5)
    write("horn", level(fade(h), -12))


def heli():
    blade = 17.5  # slaps per second (4 blades)
    n_slaps = int(4.0 * blade)
    period = SR / blade
    n = int(round(n_slaps * period))
    x = np.zeros(n)
    k = np.arange(int(0.05 * SR)) / SR
    slap = noise(len(k)) * np.exp(-k / 0.012) + np.sin(2 * np.pi * 70 * k) * np.exp(-k / 0.02) * 1.5
    for i in range(n_slaps):
        s = int(round(i * period))
        e = min(n, s + len(k))
        x[s:e] += slap[: e - s] * (1.0 if i % 4 else 1.3)
    x = lp(x, 1600)
    whine = np.sin(2 * np.pi * 2650 * np.arange(n) / SR) * 0.04 + bp(noise(n), 2000, 4000) * 0.05
    write("heli_rotor", level(x + whine, -15))


# ------------------------------------------------------------------ impacts
def crash(seed, heavy=True):
    r = np.random.default_rng(seed)
    sec = 1.8 if heavy else 0.6
    n = int(sec * SR)
    t = tt(sec)
    thump = np.sin(2 * np.pi * (60 + 40 * np.exp(-t * 30)) * t) * np.exp(-t * (9 if heavy else 20))
    crunch = bp(r.standard_normal(n), 400, 5000) * np.exp(-t * (6 if heavy else 18))
    crunch = peaks(crunch, [620, 1500, 3100], q=8, gain=5)
    metal = np.zeros(n)
    for f in r.uniform(700, 4200, 6):
        metal += np.sin(2 * np.pi * f * t + r.uniform(0, 6)) * np.exp(-t * r.uniform(5, 14))
    debris = np.zeros(n)
    if heavy:
        for _ in range(26):
            at = int(r.uniform(0.05, 1.2) * SR)
            ln = int(0.03 * SR)
            if at + ln < n:
                debris[at:at + ln] += hp(r.standard_normal(ln), 2500) * np.exp(-np.arange(ln) / (0.006 * SR)) * r.uniform(0.1, 0.5)
    x = thump * 1.4 + crunch * 1.0 + metal * 0.25 + debris
    return level(fade(room(sat(x, 2.0), 0.3, 0.15), 0.0005, 0.1), -10 if heavy else -14)


def impacts():
    for i in range(3):
        write("crash_heavy_%d" % i, crash(100 + i, True))
    for i in range(3):
        write("crash_light_%d" % i, crash(200 + i, False))
    # Glass.
    sec = 1.0
    n = int(sec * SR)
    x = np.zeros(n)
    for _ in range(60):
        at = int(abs(rng.normal(0.02, 0.15)) * SR)
        ln = int(rng.uniform(0.01, 0.06) * SR)
        if at + ln < n:
            k = np.arange(ln) / SR
            f = rng.uniform(3000, 9000)
            x[at:at + ln] += np.sin(2 * np.pi * f * k) * np.exp(-k / 0.01) * rng.uniform(0.2, 1)
    x += hp(noise(n), 4000) * np.exp(-tt(sec) * 12) * 0.5
    write("glass", level(fade(x), -15))
    # Metal scrape loop.
    sec = 3.0
    n = int(sec * SR)
    s = bp(noise(n), 1500, 7000)
    s = peaks(s, [2200, 3400, 5100], q=20, gain=10)
    s *= 0.6 + 0.4 * np.abs(np.sin(2 * np.pi * 9 * tt(sec) + np.sin(2 * np.pi * 0.7 * tt(sec)) * 3))
    write("scrape", level(loopify(s, 0.4), -17))
    # Light prop hit (sign, cone, bin).
    t = tt(0.35)
    p = bp(noise(len(t)), 300, 3000) * np.exp(-t * 25) + np.sin(2 * np.pi * 180 * t) * np.exp(-t * 30)
    write("prop_hit", level(fade(p), -14))
    # Suspension thud on landing.
    t = tt(0.4)
    th = np.sin(2 * np.pi * (45 + 60 * np.exp(-t * 25)) * t) * np.exp(-t * 14) + lp(noise(len(t)), 500) * np.exp(-t * 30) * 0.5
    write("land", level(fade(th), -12))
    # Tyre pop.
    t = tt(0.5)
    pop = noise(len(t)) * np.exp(-t * 40) + lp(noise(len(t)), 900) * np.exp(-t * 6) * 0.4
    write("tyre_pop", level(fade(pop), -10))


# ------------------------------------------------------------------ car bits, ui
def misc():
    # Gear change: clutch clunk + short blip.
    t = tt(0.18)
    g = bp(noise(len(t)), 500, 2500) * np.exp(-t * 60) + np.sin(2 * np.pi * 120 * t) * np.exp(-t * 35) * 0.6
    write("gear", level(fade(g), -20))
    # Nitro: ignition whoosh.
    t = tt(1.2)
    w = bp(noise(len(t)), 300, 6000)
    w = w * np.minimum(1, t * 8) * np.exp(-t * 1.5)
    w = w * (0.7 + 0.3 * np.sin(2 * np.pi * 30 * t))
    write("nitro", level(fade(w), -12))
    # UI click.
    t = tt(0.06)
    c = np.sin(2 * np.pi * 1800 * t) * np.exp(-t * 120) + bp(noise(len(t)), 2000, 6000) * np.exp(-t * 200) * 0.3
    write("ui_click", level(fade(c, 0.0005, 0.01), -16))
    # Score chime.
    t = tt(0.5)
    ch = sum(np.sin(2 * np.pi * f * t) * np.exp(-t * d) for f, d in [(880, 6), (1320, 8), (1760, 10)])
    write("chime", level(fade(room(ch, 0.3, 0.25)), -18))
    # Busted sting: a low hit + a dissonant brass stab.
    sec = 3.0
    t = tt(sec)
    hit = np.sin(2 * np.pi * (40 + 50 * np.exp(-t * 10)) * t) * np.exp(-t * 2.5)
    stab = np.zeros(len(t))
    for f in [110, 116.5, 165, 233]:
        ph = 2 * np.pi * f * t
        stab += (np.sin(ph) + 0.5 * np.sin(2 * ph) + 0.3 * np.sin(3 * ph)) * np.exp(-t * 1.2)
    x = hit * 1.5 + lp(stab, 2500) * 0.5 + bp(noise(len(t)), 200, 4000) * np.exp(-t * 8) * 0.3
    write("busted", level(fade(room(sat(x, 1.5), 0.5, 0.3), 0.001, 0.5), -10), stereo=True)


# ------------------------------------------------------------------ battle kit (0.4.0)
def battle():
    # Repair pickup: a rising ratchet + bright arpeggio.
    t = tt(0.9)
    rat = np.zeros(len(t))
    for k in range(7):
        st0 = int((0.02 + k * 0.045) * SR)
        ln = int(0.03 * SR)
        if st0 + ln < len(t):
            tk = np.arange(ln) / SR
            rat[st0:st0 + ln] += bp(noise(ln), 1500 + k * 300, 6000) * np.exp(-tk * 120)
    arp = np.zeros(len(t))
    for i, f in enumerate([660, 880, 1100, 1320]):
        st0 = int((0.32 + i * 0.07) * SR)
        tk = np.arange(len(t) - st0) / SR
        arp[st0:] += np.sin(2 * np.pi * f * tk) * np.exp(-tk * 7)
    write("repair", level(fade(room(rat * 0.6 + arp * 0.5, 0.3, 0.25)), -14))
    # Panel off: a sheet-metal clang with a rattle.
    t = tt(0.9)
    clang = peaks(noise(len(t)), [420, 1130, 2210, 3480], q=18, gain=6) * np.exp(-t * 7)
    rattle = bp(noise(len(t)), 1800, 7000) * np.exp(-t * 18) * (0.6 + 0.4 * np.sign(np.sin(2 * np.pi * 23 * t)))
    write("panel_off", level(fade(room(sat(clang + rattle * 0.6, 1.4), 0.2, 0.2)), -12))
    # Mine blast: a deep thump + a crackling tail.
    t = tt(1.8)
    boom = np.sin(2 * np.pi * (35 + 70 * np.exp(-t * 9)) * t) * np.exp(-t * 3.5)
    crack = lp(noise(len(t)), 3000) * np.exp(-t * 5) * (0.5 + 0.5 * (np.random.default_rng(7).random(len(t)) > 0.97))
    write("explosion", level(fade(room(sat(boom * 1.6 + crack * 0.7, 2.0), 0.45, 0.3), 0.001, 0.3), -9), stereo=True)
    # Hydraulics: a pneumatic pop + hiss; dropper: a clunk.
    t = tt(0.6)
    pop = np.sin(2 * np.pi * (90 + 120 * np.exp(-t * 30)) * t) * np.exp(-t * 18)
    hiss = hp(noise(len(t)), 3000) * np.exp(-t * 6) * 0.5
    write("hydraulic", level(fade(pop + hiss), -12))
    t = tt(0.3)
    cl = np.sin(2 * np.pi * 160 * t) * np.exp(-t * 30) + bp(noise(len(t)), 600, 3000) * np.exp(-t * 40) * 0.6
    write("drop", level(fade(cl), -14))


# ------------------------------------------------------------------ music
def music():
    """Two stems at 124 BPM, 16 bars: a pulse bed and an intensity layer
    (drums + driving bass) faded in with heat."""
    bpm = 124
    beat = 60 / bpm
    bars = 16
    sec = bars * 4 * beat
    n = int(sec * SR)
    t = np.arange(n) / SR
    roots = [55.0, 55.0, 49.0, 58.27] * 4  # A A G Bb (per bar)
    bed = np.zeros(n)
    inten = np.zeros(n)
    # Pad: detuned saws per bar, lowpassed.
    for b in range(bars):
        s, e = int(b * 4 * beat * SR), int((b + 1) * 4 * beat * SR)
        tb = np.arange(e - s) / SR
        r = roots[b]
        pad = np.zeros(e - s)
        for mult in [2, 3, 4.0 * 1.189]:  # root, fifth-ish, minor third up the octave
            for det in [-0.4, 0.4]:
                f = r * mult + det
                pad += 2 * ((tb * f) % 1) - 1
        pad *= np.minimum(1, tb / 0.4) * np.minimum(1, (tb[-1] - tb) / 0.4 + 0.01)
        bed[s:e] += pad * 0.08
        # Pulse bass: 8ths.
        for k in range(8):
            ps = s + int(k * beat / 2 * SR)
            ln = int(beat / 2 * 0.8 * SR)
            if ps + ln > n:
                continue
            tk = np.arange(ln) / SR
            saw = 2 * ((tk * r) % 1) - 1
            bed[ps:ps + ln] += saw * np.exp(-tk * 6) * 0.25
            inten[ps:ps + ln] += (2 * ((tk * r * 2) % 1) - 1) * np.exp(-tk * 9) * 0.18
    bed = lp(bed, 1400)
    # Drums for the intensity stem.
    for k in range(bars * 4):
        s = int(k * beat * SR)
        ln = int(0.25 * SR)
        tk = np.arange(ln) / SR
        kick = np.sin(2 * np.pi * (50 + 90 * np.exp(-tk * 35)) * tk) * np.exp(-tk * 12)
        if s + ln <= n:
            inten[s:s + ln] += kick * 0.9
        if k % 2 == 1:
            sn = hp(noise(ln), 1200) * np.exp(-tk * 20) * 0.35 + np.sin(2 * np.pi * 190 * tk) * np.exp(-tk * 30) * 0.3
            if s + ln <= n:
                inten[s:s + ln] += sn
        for h in range(2):
            hs = s + int(h * beat / 2 * SR)
            hl = int(0.05 * SR)
            if hs + hl <= n:
                inten[hs:hs + hl] += hp(noise(hl), 7000) * np.exp(-np.arange(hl) / (0.01 * SR)) * 0.15
    # Stereo: decorrelate slightly.
    def st(x, d=0.012):
        k = int(d * SR)
        return np.stack([x, np.concatenate([x[-k:], x[:-k]])], 1)
    write("music_bed", level(st(bed), -20), stereo=True)
    write("music_intense", level(st(inten), -19), stereo=True)


def music_extra():
    """The menu theme (slow pad + bell arpeggio, 96 BPM) and the PEAK stem
    for the chase: an arpeggiated lead, 16th hats and off-beat stabs at the
    same 124 BPM / 16 bars / chord loop as the bed, so it layers on top from
    heat 5."""
    def st(x, d=0.012):
        k = int(d * SR)
        return np.stack([x, np.concatenate([x[-k:], x[:-k]])], 1)
    # --- peak stem
    bpm = 124
    beat = 60 / bpm
    bars = 16
    n = int(bars * 4 * beat * SR)
    roots = [55.0, 55.0, 49.0, 58.27] * 4
    peak = np.zeros(n)
    arp = [1, 1.5, 2, 2.378, 2, 1.5, 3, 2.378]  # root, fifth, octave, minor 10th...
    for b in range(bars):
        r = roots[b] * 4
        for k in range(16):
            s = int((b * 4 + k / 4) * beat * SR)
            ln = int(beat / 4 * 0.9 * SR)
            if s + ln > n:
                continue
            tk = np.arange(ln) / SR
            f = r * arp[k % len(arp)]
            sq = np.sign(np.sin(2 * np.pi * f * tk)) * 0.5 + (2 * ((tk * f * 1.003) % 1) - 1) * 0.5
            peak[s:s + ln] += sq * np.exp(-tk * 14) * 0.16
            hl = int(0.03 * SR)
            if s + hl <= n:
                peak[s:s + hl] += hp(noise(hl), 8000) * np.exp(-np.arange(hl) / (0.006 * SR)) * (0.12 if k % 2 else 0.07)
        for k in range(4):  # off-beat chord stabs
            s = int((b * 4 + k + 0.5) * beat * SR)
            ln = int(0.18 * SR)
            if s + ln > n:
                continue
            tk = np.arange(ln) / SR
            ch = sum(2 * ((tk * roots[b] * m) % 1) - 1 for m in (4, 6, 4 * 1.189))
            peak[s:s + ln] += lp(ch, 2600) * np.exp(-tk * 16) * 0.12
    peak = lp(peak, 6000)
    write("music_peak", level(st(peak), -21), stereo=True)
    # --- menu theme
    bpm = 96
    beat = 60 / bpm
    bars = 8
    n = int(bars * 4 * beat * SR)
    menu = np.zeros(n)
    chords = [55.0, 43.65, 49.0, 41.2]  # A  F  G  E  (two bars each)
    for b in range(bars):
        r = chords[b // 2]
        s, e = int(b * 4 * beat * SR), int((b + 1) * 4 * beat * SR)
        tb = np.arange(e - s) / SR
        pad = np.zeros(e - s)
        for m in (2, 3, 4.0 * (1.26 if b // 2 in (1, 2) else 1.189)):
            for det in (-0.3, 0.3):
                pad += np.sin(2 * np.pi * (r * m + det) * tb) + 0.3 * (2 * ((tb * (r * m + det)) % 1) - 1)
        pad *= np.minimum(1, tb / 0.8) * np.minimum(1, (tb[-1] - tb) / 0.8 + 0.01)
        menu[s:e] += pad * 0.05
        for k in range(8):  # bell arpeggio in 8ths
            ps = s + int(k * beat / 2 * SR)
            ln = int(beat * 1.5 * SR)
            if ps + ln > n:
                ln = n - ps
            tk = np.arange(ln) / SR
            f = r * 8 * [1, 1.5, 2, 1.5, 1.189 * 2, 2, 1.5, 1][k]
            bell = np.sin(2 * np.pi * f * tk) + 0.4 * np.sin(2 * np.pi * f * 2.76 * tk) * np.exp(-tk * 6)
            menu[ps:ps + ln] += bell * np.exp(-tk * 3.5) * 0.07
        for k in range(4):  # soft sub pulse on the beat
            ps = s + int(k * beat * SR)
            ln = int(0.4 * SR)
            if ps + ln <= n:
                tk = np.arange(ln) / SR
                menu[ps:ps + ln] += np.sin(2 * np.pi * r * tk) * np.exp(-tk * 7) * 0.3
    menu = room(lp(menu, 5000), 0.35, 0.25)
    write("music_menu", level(st(menu, 0.018), -21), stereo=True)


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[2] == "battle":
        battle()
        print("BATTLE DONE")
        sys.exit(0)
    if len(sys.argv) > 2 and sys.argv[2] == "music_extra":
        music_extra()
        print("MUSIC DONE")
        sys.exit(0)
    engines()
    tyres()
    sirens()
    heli()
    impacts()
    misc()
    music()
    music_extra()
    battle()
    print("SOUNDS DONE")
