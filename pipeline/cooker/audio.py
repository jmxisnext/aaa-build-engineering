"""Audio cook: 16-bit PCM WAV -> mono 16-bit PCM binary (.aud).

Binary layout (little-endian):
    magic       "AUD1"      (4 bytes)
    sampleRate  uint32
    frameCount  uint32      (mono samples)
    then: int16 mono PCM, little-endian.

Stereo is downmixed to mono by averaging L/R. NOTE: Python 3.13 removed the `audioop`
module, so the downmix is done by hand via `array` -- stdlib only, no deprecated deps.
"""
import array
import io
import struct
import sys
import wave

MAGIC = b"AUD1"


def params_bytes():
    """Cook params for the cache key -- changing them must force a re-cook."""
    return b"aud:mono16"


def cook_audio(wav_bytes):
    with wave.open(io.BytesIO(wav_bytes), "rb") as w:
        nch, sampwidth, rate, nframes = (
            w.getnchannels(),
            w.getsampwidth(),
            w.getframerate(),
            w.getnframes(),
        )
        raw = w.readframes(nframes)

    if sampwidth != 2:
        raise ValueError(f"only 16-bit PCM WAV supported (got sampwidth={sampwidth})")

    samples = array.array("h")
    samples.frombytes(raw)
    if sys.byteorder == "big":
        samples.byteswap()  # WAV is little-endian; normalize to native for arithmetic

    if nch == 1:
        mono = samples
    elif nch == 2:
        mono = array.array(
            "h", [(samples[2 * i] + samples[2 * i + 1]) // 2 for i in range(nframes)]
        )
    else:
        raise ValueError(f"unsupported channel count {nch}")

    out = bytearray(MAGIC)
    out += struct.pack("<II", rate, len(mono))
    le = array.array("h", mono)
    if sys.byteorder == "big":
        le.byteswap()  # serialize little-endian regardless of host
    out += le.tobytes()
    return bytes(out)
