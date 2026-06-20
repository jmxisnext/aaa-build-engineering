"""Track 5 content cooker: a hand-rolled mini DDC / content-addressable store.

Scans synthetic source assets (JSON characters -> PNG textures + WAV audio),
cooks each (Pillow mip chain / wave downmix / binary character records), stores
cooked artifacts content-addressed by output hash, and writes a deterministic
`.toc` manifest. A content-hash cache skips re-cooking unchanged inputs.
"""
