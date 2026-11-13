#!/usr/bin/env python3
"""花火デモの効果音を合成する(自作。外部素材なし)。48kHz・16bit・ステレオ(Audio の素材の形式)。

  priv/audio/fireworks/whistle.wav  … 打ち上げの「ヒュー」(音程が上がる笛の音、0.7 秒)
  priv/audio/fireworks/boom1..3.wav … 開いたときの「ドン」+ 火花のパチパチ(1.4 秒、低音と雑音の配合を変えた 3 種)
"""
import os, wave
import numpy as np

SR = 48000
dst = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "priv", "audio", "fireworks")
os.makedirs(dst, exist_ok=True)
rng = np.random.default_rng(20261112)

def save(name, mono, peak_db, pan=0.0):
    mono = mono / (np.abs(mono).max() or 1.0) * (10 ** (peak_db / 20)) * 32767
    left, right = mono * (1 - max(pan, 0)), mono * (1 + min(pan, 0))
    data = np.stack([left, right], axis=1).astype(np.int16)
    with wave.open(os.path.join(dst, name + ".wav"), "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(data.tobytes())

def lowpass(x, a):
    y = np.empty_like(x); acc = 0.0
    for i, v in enumerate(x):
        acc += a * (v - acc); y[i] = acc
    return y

# ヒュー: 900 → 1700 Hz に上がる、わずかに揺れる笛の音
t = np.arange(int(SR * 0.7)) / SR
f = 900 + 800 * (t / t[-1]) ** 1.3 + 25 * np.sin(2 * np.pi * 9 * t)
whistle = np.sin(2 * np.pi * np.cumsum(f) / SR) + 0.15 * rng.standard_normal(len(t))
env = np.minimum(1, t / 0.08) * np.minimum(1, (t[-1] - t) / 0.15)
save("whistle", whistle * env, -14)

# ドン + パチパチ
for k, (low, noise_a, crackles) in enumerate([(55, 0.05, 60), (70, 0.08, 90), (45, 0.03, 40)], start=1):
    t = np.arange(int(SR * 1.4)) / SR
    thump = np.sin(2 * np.pi * low * t * (1 - 0.3 * t)) * np.exp(-t / 0.25)
    blast = lowpass(rng.standard_normal(len(t)), noise_a) * np.exp(-t / 0.35) * 6
    crack = np.zeros(len(t))
    for _ in range(crackles):
        s = int(SR * rng.uniform(0.15, 1.25)); n = int(SR * 0.004)
        if s + n < len(t):
            crack[s:s + n] += rng.standard_normal(n) * np.exp(-np.arange(n) / (n / 4)) * rng.uniform(0.2, 0.6)
    crack *= np.exp(-t / 0.7)
    mix = thump * 1.0 + blast * 0.8 + crack * 0.9
    mix[: int(SR * 0.004)] *= np.linspace(0, 1, int(SR * 0.004))
    save(f"boom{k}", mix, -2, pan=[0.0, 0.25, -0.25][k - 1])
print("wrote", sorted(os.listdir(dst)))
