"""cooker.audio: 16-bit WAV -> mono 16-bit PCM .aud (stdlib wave, manual downmix)."""
import array
import io
import os
import struct
import sys
import unittest
import wave

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from cooker import audio  # noqa: E402


def _wav(samples, nchannels, framerate=22050):
    """samples: flat interleaved list of int16."""
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(nchannels)
        w.setsampwidth(2)
        w.setframerate(framerate)
        w.writeframes(array.array("h", samples).tobytes())
    return buf.getvalue()


def _parse(blob):
    magic = blob[:4]
    rate, frames = struct.unpack_from("<II", blob, 4)
    pcm = array.array("h")
    pcm.frombytes(blob[12:])
    return magic, rate, frames, list(pcm)


class TestCookAudio(unittest.TestCase):
    def test_stereo_downmixed_to_averaged_mono(self):
        # 3 frames, L/R per frame: (1000,2000),(0,0),(-100,-300)
        blob = audio.cook_audio(_wav([1000, 2000, 0, 0, -100, -300], nchannels=2))
        magic, rate, frames, pcm = _parse(blob)
        self.assertEqual(magic, b"AUD1")
        self.assertEqual(rate, 22050)
        self.assertEqual(frames, 3)
        self.assertEqual(pcm, [(1000 + 2000) // 2, 0, (-100 + -300) // 2])

    def test_mono_passthrough(self):
        blob = audio.cook_audio(_wav([5, 6, 7, 8], nchannels=1))
        _, _, frames, pcm = _parse(blob)
        self.assertEqual(frames, 4)
        self.assertEqual(pcm, [5, 6, 7, 8])

    def test_deterministic(self):
        src = _wav([1, 2, 3, 4], nchannels=2)
        self.assertEqual(audio.cook_audio(src), audio.cook_audio(src))

    def test_rejects_non_16bit(self):
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(1)  # 8-bit -> unsupported
            w.setframerate(8000)
            w.writeframes(b"\x01\x02")
        with self.assertRaises(ValueError):
            audio.cook_audio(buf.getvalue())


if __name__ == "__main__":
    unittest.main()
