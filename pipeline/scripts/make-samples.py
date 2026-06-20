#!/usr/bin/env python3
"""Generate the synthetic source assets the cooker consumes -- deterministic, no randomness,
so the repo carries no binary blobs (assets/ is gitignored; regenerate on demand).

    python pipeline/scripts/make-samples.py            # -> pipeline/assets
    python pipeline/scripts/make-samples.py --out DIR

Produces: characters/*.json referencing textures/*.png + audio/*.wav, where a couple of
characters deliberately SHARE a texture (so the dependency graph has a fan-out to show off).
"""
import argparse
import array
import json
import math
import os

from PIL import Image

_HERE = os.path.dirname(os.path.abspath(__file__))
_DEFAULT_OUT = os.path.join(os.path.dirname(_HERE), "assets")

# (filename, size, base RGB) -- a diagonal gradient, fully deterministic
TEXTURES = [
    ("hero_albedo.png", 96, (180, 40, 40)),
    ("hero_normal.png", 64, (120, 120, 220)),
    ("npc_albedo.png", 80, (40, 160, 40)),
    ("shared_fx.png", 48, (220, 200, 60)),  # referenced by two characters
]
# (filename, frequency Hz)
AUDIO = [
    ("hero_voice.wav", 220.0),
    ("ambient.wav", 110.0),
]
CHARACTERS = [
    ("hero", ["textures/hero_albedo.png", "textures/hero_normal.png", "textures/shared_fx.png"],
     ["audio/hero_voice.wav"]),
    ("npc", ["textures/npc_albedo.png", "textures/shared_fx.png"], ["audio/ambient.wav"]),
]


def _gradient_png(path, size, base):
    img = Image.new("RGBA", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            px[x, y] = ((base[0] + x) % 256, (base[1] + y) % 256, (base[2] + (x + y) // 2) % 256, 255)
    img.save(path, format="PNG")


def _sine_wav(path, freq, seconds=0.3, rate=22050):
    n = int(seconds * rate)
    samples = array.array("h")
    for i in range(n):
        v = int(3000 * math.sin(2 * math.pi * freq * i / rate))
        samples.append(v)  # left
        samples.append(v)  # right (stereo -> the cook downmixes to mono)
    import wave
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(samples.tobytes())


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--out", default=_DEFAULT_OUT, help="asset root to generate")
    args = p.parse_args(argv)

    for sub in ("textures", "audio", "characters"):
        os.makedirs(os.path.join(args.out, sub), exist_ok=True)

    for name, size, base in TEXTURES:
        _gradient_png(os.path.join(args.out, "textures", name), size, base)
    for name, freq in AUDIO:
        _sine_wav(os.path.join(args.out, "audio", name), freq)
    for name, textures, audio in CHARACTERS:
        with open(os.path.join(args.out, "characters", f"{name}.json"), "w", encoding="utf-8") as f:
            json.dump({"name": name, "textures": textures, "audio": audio}, f, indent=2)

    print(f"generated {len(TEXTURES)} textures, {len(AUDIO)} audio, {len(CHARACTERS)} characters -> {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
