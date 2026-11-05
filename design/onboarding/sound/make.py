# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "scipy", "soundfile", "pyloudnorm", "matplotlib"]
# ///
"""Renders Hello's onboarding sounds into Resources/Sounds/Onboarding/.

    uv run design/onboarding/sound/make.py [--earshot PATH]

Two sources. The keys, the space bar and the pull-back's air swell come from earshot's bank
(github.com/Leonxlnx/earshot, `earshot kit render kit.json`); its CLI must be installed, and the bank
needs no models. The wave's notes come from the drop's own voice (design/sound/generate.py),
transposed up E major from E4 (E, F#, G#, B, C#, E5) so the last note is the app's own start and
success.

Levels were set by earshot listening to an offline mix of the whole sequence: the keys and the swell
sit under the start cue, the start under the success. The app keeps its three cues; these play in
onboarding only.
"""

import argparse
import importlib.util
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf

HERE = Path(__file__).parent
ROOT = HERE.parent.parent.parent
OUT = ROOT / "Resources" / "Sounds" / "Onboarding"

# Gains on earshot's renders, which peak at -1 dBFS: the keys about -41 LUFS momentary, the swell about -38.
GAIN = {"key": -23.0, "key-space": -22.0, "whoosh-long": -22.0}
# Semitones from the app's cues, one per window of the wave.
STEPS = [-12, -10, -8, -5, -3, 0]


def cue_generator():
    spec = importlib.util.spec_from_file_location("generate", ROOT / "design" / "sound" / "generate.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def start(g, shift):
    """The app's start cue, transposed."""
    r = np.random.default_rng(7)
    voice = {**g.VOICE, "rise": g.VOICE["rise"] + 1.5, "tau": g.VOICE["tau"] * 0.45}
    x = g.bubble(g.hz("E5") * 2 ** (shift / 12), r, **voice, gate=0.07, gate_tau=0.022, length=0.35)
    return g.finish(g.body(x, r), g.LEVEL["start"])


def success(g, shift, take):
    """The app's success cue (B5 -> E6), transposed, on one of its three takes."""
    r = np.random.default_rng(100 + take)
    v = g.jitter(g.VOICE, r) if take else g.VOICE
    k = 2 ** (shift / 12)
    a = g.bubble(g.hz("B5") * k, r, **{**v, "tau": v["tau"] * 0.4}, gate=0.055, gate_tau=0.02, length=0.3)
    c = g.bubble(g.hz("E6") * k, r, **v, gate=0.26, gate_tau=0.05, length=0.9)
    y = np.zeros(g.SR)
    g.place(y, a * 10 ** (-5 / 20), 0.0)
    g.place(y, c, 0.085)
    return g.finish(g.body(y, r), g.LEVEL["success"])


def write(name, y, sr):
    sf.write(OUT / f"{name}.caf", y, sr, format="CAF", subtype="PCM_16")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--earshot", default="earshot")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run([args.earshot, "kit", "render", str(HERE / "kit.json"), "--out", tmp], check=True)
        for path in sorted(Path(tmp).glob("*.wav")):
            role, take = path.stem.rsplit("_", 1)
            y, sr = sf.read(path)
            y = y.mean(axis=1) if y.ndim > 1 else y  # mono, like the app's cues: one player format for every sound
            write(f"{role}-{take}", y * 10 ** (GAIN[role] / 20), sr)
    g = cue_generator()
    for i, shift in enumerate(STEPS):
        write(f"wave-start-{i}", start(g, shift), g.SR)
        write(f"wave-success-{i}", success(g, shift, i % 3), g.SR)
        print(f"wave {i}: {shift:+d} st", g.audit(success(g, shift, i % 3)))


if __name__ == "__main__":
    main()
