# Synthèse de cris de dauphin doux et originaux pour xocean (mono, Ogg Vorbis).
# Fréquences de conception : le jeu les joue à pitch 0,7 (entendu ≈ 0,7 × ces valeurs).
import sys, numpy as np, soundfile as sf

SR = 48000
rng = np.random.default_rng(7)

def curve(points, dur):
    """Courbe lisse (interpolation cosinus) passant par des points (t relatif 0..1, valeur)."""
    t = np.linspace(0, 1, int(SR * dur), endpoint=False)
    out = np.empty_like(t)
    for (t0, v0), (t1, v1) in zip(points, points[1:]):
        m = (t >= t0) & (t <= t1)
        x = (t[m] - t0) / (t1 - t0)
        out[m] = v0 + (v1 - v0) * (1 - np.cos(np.pi * x)) / 2
    return out

def envelope(n, attack=0.06, release=0.15):
    e = np.ones(n)
    a, r = int(SR * attack), int(SR * release)
    e[:a] = (1 - np.cos(np.linspace(0, np.pi, a))) / 2
    e[-r:] = (1 + np.cos(np.linspace(0, np.pi, r))) / 2
    return e

def whistle(freq_points, dur, vib_rate=5.5, vib_depth=0.012, amp_points=None):
    f = curve(freq_points, dur)
    n = len(f)
    t = np.arange(n) / SR
    f = f * (1 + vib_depth * np.sin(2 * np.pi * vib_rate * t + rng.uniform(0, 6.28)))
    phase = 2 * np.pi * np.cumsum(f) / SR
    # timbre chaud : fondamentale + un peu d'harmonique 2 et 3, aucune partielle aiguë
    s = np.sin(phase) + 0.18 * np.sin(2 * phase + 0.3) + 0.05 * np.sin(3 * phase + 1.1)
    amp = curve(amp_points, dur) if amp_points else 1
    return s * amp * envelope(n)

def lowpass(x, cutoff):
    """Passe-bas doux dans le domaine fréquentiel (pente en cosinus sur une octave)."""
    X = np.fft.rfft(x)
    fr = np.fft.rfftfreq(len(x), 1 / SR)
    g = np.clip((2 * cutoff - fr) / cutoff, 0, 1)
    g = (1 - np.cos(np.pi * g)) / 2
    return np.fft.irfft(X * g, len(x))

def breath(n, level):
    """Souffle discret : bruit filtré bas, enveloppe douce."""
    return lowpass(rng.standard_normal(n), 1800) * level * envelope(n, 0.1, 0.25)

def silence(dur):
    return np.zeros(int(SR * dur))

def finish(x, target_rms_db=-18.0, peak_db=-4.0):
    x = lowpass(x, 3200)
    x = np.concatenate([silence(0.02), x, silence(0.05)])
    x *= 10 ** (target_rms_db / 20) / np.sqrt((x ** 2).mean())
    peak = np.abs(x).max()
    if peak > 10 ** (peak_db / 20):
        x *= 10 ** (peak_db / 20) / peak
    return x

def call1():  # « ouii-ou » : montée puis descente, une seule phrase
    d = 0.95
    w = whistle([(0, 950), (0.45, 1420), (1, 1020)], d, amp_points=[(0, 0.8), (0.4, 1), (1, 0.7)])
    return w + breath(len(w), 0.04)

def call2():  # deux petits gazouillis
    a = whistle([(0, 1000), (1, 1300)], 0.26, vib_depth=0.006)
    b = whistle([(0, 1120), (0.5, 1500), (1, 1180)], 0.40, amp_points=[(0, 0.9), (0.5, 1), (1, 0.75)])
    x = np.concatenate([a, silence(0.09), b])
    return x + breath(len(x), 0.035)

def call3():  # roucoulement : trille lente qui descend puis remonte un peu
    d = 1.05
    w = whistle([(0, 1220), (0.7, 960), (1, 1080)], d, vib_rate=8.0, vib_depth=0.07,
                amp_points=[(0, 0.85), (0.3, 1), (0.8, 0.85), (1, 0.6)])
    return w + breath(len(w), 0.04)

out = sys.argv[1]
for i, fn in enumerate([call1, call2, call3], 1):
    x = finish(fn()).astype(np.float32)
    sf.write(f"{out}/dolphin_call.{i}.ogg", x, SR, format="OGG", subtype="VORBIS")
    sf.write(f"{out}/dolphin_call.{i}.wav", x, SR)
