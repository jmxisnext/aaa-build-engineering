"""Asset model: parse character descriptors and build the dependency graph.

A character is a small JSON descriptor referencing texture (PNG) and audio (WAV) source
files by path (relative to the source root). The graph answers "which characters depend on
this asset" so an incremental cook can re-serialize only the affected characters when an
asset re-cooks.
"""
import glob
import json
import os
from dataclasses import dataclass, field


@dataclass
class Character:
    name: str
    source_path: str  # absolute path to the .json; None for in-memory/parsed-only
    textures: list = field(default_factory=list)  # source paths, as written in the JSON
    audio: list = field(default_factory=list)


@dataclass
class Graph:
    textures: list  # sorted unique texture source paths
    audio: list     # sorted unique audio source paths
    _dependents: dict  # asset path -> set of character names

    def dependents(self, asset_path):
        return self._dependents.get(asset_path, set())


def parse_character(json_bytes):
    data = json.loads(json_bytes)
    if "name" not in data:
        raise ValueError("character JSON missing required 'name'")
    return Character(
        name=data["name"],
        source_path=None,
        textures=list(data.get("textures", [])),
        audio=list(data.get("audio", [])),
    )


def load_characters(src_dir):
    """Scan <src_dir>/characters/*.json (sorted for determinism) -> [Character]."""
    cdir = os.path.join(src_dir, "characters")
    chars = []
    for path in sorted(glob.glob(os.path.join(cdir, "*.json"))):
        with open(path, "rb") as f:
            c = parse_character(f.read())
        c.source_path = path
        chars.append(c)
    return chars


def build_graph(characters):
    dependents = {}
    textures, audio = set(), set()
    for c in characters:
        for t in c.textures:
            textures.add(t)
            dependents.setdefault(t, set()).add(c.name)
        for a in c.audio:
            audio.add(a)
            dependents.setdefault(a, set()).add(c.name)
    return Graph(textures=sorted(textures), audio=sorted(audio), _dependents=dependents)
