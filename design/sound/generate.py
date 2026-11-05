# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "scipy", "soundfile", "pyloudnorm", "matplotlib"]
# ///
"""Renders Oops's three cues (start, success, failure) into Resources/Sounds/, and their spectrograms.

    uv run design/sound/generate.py            # writes Resources/Sounds/*.caf, spectrograms.png, and prints the audit

Every sample is computed. The voice is a bubble, after earshot's drip recipe (github.com/Leonxlnx/earshot,
earshot/forge/recipes/drip.py): its pitch rises as the cavity closes (`rise` semitones, most of it within ~3 `rtau`),
its ring swells in (`onset`) and decays (`tau`), a weak 2nd harmonic dies faster (`h2`), and a faint hiss follows the
pitch (`breath`) so the tail stays liquid rather than metallic. A soft damper stops each note instead of a fade.

The motif, in E major: start E5 (the drop forming); success B5 -> E6, short then long like the check's two strokes,
landing on the start's octave; failure D5 -> B4, the second note muffled and sinking as the eyes look away. Success
and failure come as three takes that differ only in the bubble's shape, never the pitch; start is one voice.
"""

import json
from pathlib import Path

import numpy as np
import pyloudnorm as pyln
import soundfile as sf
from scipy import signal

SR = 48000
HERE = Path(__file__).parent

# Loudest 400 ms (BS.1770 momentary max). macOS alerts: Glass -25.9, Tink -27.7, Pop -32.0. The outcomes sit under
# the alerts because they play many times a day; the start is quietest, as the user's own key press already says "go".
LEVEL = {"start": -37.0, "success": -30.0, "failure": -31.0}

# Pure: a quick, clear rise into each note, a ring that swells in over 4 ms, a faint hiss in the tail.
VOICE = dict(rise=3.0, rtau=0.007, onset=0.004, tau=0.14, h2=0.12, hdec=2.0, breath=-30.0, bq=4.0, lp=7000.0)


def hz(note):
    steps = {
        "C": -9,
        "C#": -8,
        "D": -7,
        "D#": -6,
        "E": -5,
        "F": -4,
        "F#": -3,
        "G": -2,
        "G#": -1,
        "A": 0,
        "A#": 1,
        "B": 2,
    }
    return 440.0 * 2 ** ((steps[note[:-1]] + 12 * (int(note[-1]) - 4)) / 12)


def butter(x, kind, f, order=2):
    return signal.sosfilt(signal.butter(order, f, btype=kind, fs=SR, output="sos"), x)


def bubble(
    f,
    r,
    *,
    rise,
    rtau,
    onset,
    tau,
    h2,
    hdec,
    breath,
    bq,
    lp,
    sink=0.0,
    sink_tau=0.1,
    gate=0.3,
    gate_tau=0.04,
    hp=250.0,
    length=0.8,
):
    """One note landing on `f`; `sink` semitones it sags after landing (the failure's glance away)."""
    n = int(length * SR)
    t = np.arange(n) / SR
    ft = f * 2 ** ((-rise * np.exp(-t / rtau) - sink * (1 - np.exp(-t / sink_tau))) / 12)
    ph = 2 * np.pi * np.cumsum(ft) / SR + r.uniform(0, 2 * np.pi)
    w = 0.006  # the damper eases in over 6 ms: no edge
    e = (1 - np.exp(-t / onset)) * np.exp(-t / tau) * np.exp(-w * np.logaddexp(0, (t - gate) / w) / gate_tau)
    y = e * (np.sin(ph) + h2 * np.exp(-t * (hdec - 1) / tau) * np.sin(2 * ph))
    hiss = butter(r.standard_normal(n), "band", (f / (1 + 1 / bq), f * (1 + 1 / bq)))
    y += 10 ** (breath / 20) * e * hiss / (np.abs(hiss).max() + 1e-12)
    return butter(butter(y, "high", hp), "low", lp)


def body(x, r, rt60=0.09, wet_db=-28.0):
    """A tiny reflection field for presence, with no reverb tail."""
    t = np.arange(int(rt60 * 1.2 * SR)) / SR
    ir = butter(r.standard_normal(len(t)) * np.exp(-6.9 * t / rt60), "low", 4000)
    ir[: int(0.004 * SR)] = 0  # first reflection after 4 ms
    ir /= np.sqrt((ir**2).sum())
    return x + 10 ** (wet_db / 20) * signal.fftconvolve(x, ir)[: len(x)]


def place(dst, x, at):
    i = int(at * SR)
    dst[i : i + len(x)] += x[: len(dst) - i]


def momentary_max(y):
    meter = pyln.Meter(SR, block_size=0.4)
    pad = np.concatenate([y, np.zeros(SR)])
    return max(meter.integrated_loudness(pad[i : i + int(0.4 * SR)]) for i in range(0, len(y), SR // 100))


def finish(y, lufs):
    """Trims the tail at -70 dB, levels to `lufs`, dithers (TPDF) for 16-bit, then fades the last 8 ms, dither
    included, so the file ends on digital silence."""
    last = np.nonzero(np.abs(y) > np.abs(y).max() * 10 ** (-70 / 20))[0][-1] + int(0.01 * SR)
    y = y[:last]
    y = y * 10 ** ((lufs - momentary_max(y)) / 20)
    y = y + np.random.default_rng(0).uniform(-0.5, 0.5, (2, len(y))).sum(0) / 32768
    y[-int(0.008 * SR) :] *= np.linspace(1, 0, int(0.008 * SR))
    return y


def jitter(v, r):
    """A take's bubble shape: rise +-10 %, rtau +-12 %, tau +-6 % (one standard deviation)."""
    j = r.standard_normal(3)
    return {
        **v,
        "rise": v["rise"] * np.exp(0.1 * j[0]),
        "rtau": v["rtau"] * np.exp(0.12 * j[1]),
        "tau": v["tau"] * np.exp(0.06 * j[2]),
    }


def start():
    r = np.random.default_rng(7)
    x = bubble(
        hz("E5"),
        r,
        **{**VOICE, "rise": VOICE["rise"] + 1.5, "tau": VOICE["tau"] * 0.45},
        gate=0.07,
        gate_tau=0.022,
        length=0.35,
    )
    return finish(body(x, r), LEVEL["start"])


def success(take):
    r = np.random.default_rng(100 + take)
    v = jitter(VOICE, r) if take else VOICE
    a = bubble(hz("B5"), r, **{**v, "tau": v["tau"] * 0.4}, gate=0.055, gate_tau=0.02, length=0.3)
    c = bubble(hz("E6"), r, **v, gate=0.26, gate_tau=0.05, length=0.9)
    y = np.zeros(SR)
    place(y, a * 10 ** (-5 / 20), 0.0)
    place(y, c, 0.085)
    return finish(body(y, r), LEVEL["success"])


def failure(take):
    r = np.random.default_rng(100 + take)
    v = jitter(VOICE, r) if take else VOICE
    a = bubble(hz("D5"), r, **{**v, "tau": v["tau"] * 0.5}, gate=0.08, gate_tau=0.022, length=0.3)
    c = bubble(
        hz("B4"),
        r,
        **{**v, "rise": v["rise"] * 0.5, "h2": v["h2"] * 0.4, "lp": v["lp"] * 0.5},
        sink=1.2,
        sink_tau=0.12,
        gate=0.2,
        gate_tau=0.045,
        length=0.7,
    )
    y = np.zeros(int(0.9 * SR))
    place(y, a, 0.0)
    place(y, c * 10 ** (-1.5 / 20), 0.11)
    return finish(body(y, r), LEVEL["failure"])


def audit(y):
    """Measurements only, after earshot's sfx audit: clicks after the attack, where the tail ends, tone balance."""
    pk = np.abs(y).argmax()
    fr = int(0.001 * SR)
    d2 = np.abs(np.diff(y, 2))
    e = np.array([d2[i : i + fr].max() for i in range(0, len(d2) - fr, fr)])
    clicks = int(((20 * np.log10(e / (signal.medfilt(e, 31) + 1e-9)) > 18) & (np.arange(len(e)) > pk // fr + 5)).sum())
    spec = np.abs(np.fft.rfft(y * np.hanning(len(y)))) ** 2
    f = np.fft.rfftfreq(len(y), 1 / SR)
    return {
        "ms": round(len(y) / SR * 1000),
        "lufs_mmax": round(momentary_max(y), 1),
        "peak_dbfs": round(float(20 * np.log10(np.abs(y).max())), 1),
        "centroid_hz": round(float((f * spec).sum() / spec.sum())),
        "share_2_6k": round(float(spec[(f > 2000) & (f < 6000)].sum() / spec.sum()), 3),
        "clicks": clicks,
        "tail_end_db": round(float(20 * np.log10(np.abs(y[-int(0.005 * SR) :]).max() / np.abs(y).max())), 1),
    }


def spectrograms(cues, path):
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    names = ["start", "success-1", "failure-1"]
    fig, ax = plt.subplots(1, 3, figsize=(12, 3), constrained_layout=True)
    for a, name in zip(ax, names):
        y = np.concatenate([cues[name], np.zeros(max(0, int(0.8 * SR) - len(cues[name])))])
        a.specgram(y, NFFT=1024, Fs=SR, noverlap=960, cmap="magma", vmin=-130, vmax=-50, scale="dB")
        a.set_yscale("symlog", linthresh=500)
        a.set_ylim(150, 10000)
        a.set_title(name, fontsize=9)
        a.set_xlabel("s", fontsize=8)
    fig.savefig(path, dpi=80)


if __name__ == "__main__":
    out = HERE.parent.parent / "Resources" / "Sounds"
    out.mkdir(exist_ok=True)
    cues = {
        "start": start(),
        **{f"success-{k + 1}": success(k) for k in range(3)},
        **{f"failure-{k + 1}": failure(k) for k in range(3)},
    }
    report = {}
    for name, y in cues.items():
        sf.write(out / f"oops-{name}.caf", y, SR, format="CAF", subtype="PCM_16")
        report[name] = audit(y)
        print(f"{name:10s}", report[name])
    (HERE / "audit.json").write_text(json.dumps(report, indent=1) + "\n")
    spectrograms(cues, HERE / "spectrograms.png")
