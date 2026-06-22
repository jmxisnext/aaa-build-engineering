"""Cook orchestration: scan -> graph -> cook (with cache) -> deterministic .toc -> stats.

Cooks textures and audio first (they have no dependencies), recording each asset's cooked
output hash. Characters cook last, referencing those hashes -- so a changed asset propagates
to exactly the characters that depend on it. The .toc carries no timestamps (stats are kept
separate), so a no-change re-run produces a byte-identical manifest.
"""
import json
import os
import time
from dataclasses import dataclass, field

from . import assets, audio, cache, characters, hashing, textures

TOC_NAME = "manifest.toc.json"
TOC_VERSION = 1
MAX_DIM = 256


@dataclass
class Stats:
    textures_cooked: int = 0
    textures_cached: int = 0
    audio_cooked: int = 0
    audio_cached: int = 0
    characters_cooked: int = 0
    characters_cached: int = 0
    total_bytes: int = 0
    elapsed_sec: float = 0.0
    toc_path: str = ""


@dataclass
class DryReport:
    textures_recook: int = 0
    textures_cache: int = 0
    audio_recook: int = 0
    audio_cache: int = 0
    characters_recook: int = 0
    characters_cache: int = 0
    would_recook: list = field(default_factory=list)  # sorted rel paths that would re-cook


def _read(path):
    with open(path, "rb") as f:
        return f.read()


def run(src_dir, out_dir, force=False, max_dim=MAX_DIM):
    t0 = time.perf_counter()
    os.makedirs(out_dir, exist_ok=True)
    store = cache.Cache(out_dir, load_index=not force)
    chars = assets.load_characters(src_dir)
    graph = assets.build_graph(chars)

    stats = Stats()
    entries = {}
    asset_hash = {}  # source rel path -> cooked output hash (for character refs)

    def _record(rel, kind, key, result, deps=None):
        entry = {
            "type": kind, "cookKey": key, "outputHash": result.output_hash,
            "size": result.size, "ext": result.ext,
        }
        if deps is not None:
            entry["deps"] = deps   # character -> source asset rel paths (sorted); leaves carry none
        entries[rel] = entry
        stats.total_bytes += result.size

    tex_params = textures.params_bytes(max_dim)
    for rel in graph.textures:
        data = _read(os.path.join(src_dir, rel))
        key = hashing.cook_key(data, params=tex_params)
        r = store.cook_or_reuse(key, "tex", lambda data=data: textures.cook_texture(data, max_dim))
        asset_hash[rel] = r.output_hash
        _record(rel, "texture", key, r)
        setattr(stats, "textures_cached" if r.hit else "textures_cooked",
                getattr(stats, "textures_cached" if r.hit else "textures_cooked") + 1)

    aud_params = audio.params_bytes()
    for rel in graph.audio:
        data = _read(os.path.join(src_dir, rel))
        key = hashing.cook_key(data, params=aud_params)
        r = store.cook_or_reuse(key, "aud", lambda data=data: audio.cook_audio(data))
        asset_hash[rel] = r.output_hash
        _record(rel, "audio", key, r)
        setattr(stats, "audio_cached" if r.hit else "audio_cooked",
                getattr(stats, "audio_cached" if r.hit else "audio_cooked") + 1)

    for ch in chars:
        refs = ([("texture", asset_hash[t]) for t in ch.textures]
                + [("audio", asset_hash[a]) for a in ch.audio])
        # cache key = the character's identity: name + ordered dep output hashes
        canon = (ch.name + "\n" + "\n".join(f"{k}:{h}" for k, h in refs)).encode("utf-8")
        key = hashing.cook_key(canon, params=b"chr")
        r = store.cook_or_reuse(
            key, "chr", lambda ch=ch, refs=refs: characters.cook_character(ch.name, refs))
        deps = sorted(list(ch.textures) + list(ch.audio))
        _record(f"characters/{ch.name}", "character", key, r, deps=deps)
        setattr(stats, "characters_cached" if r.hit else "characters_cooked",
                getattr(stats, "characters_cached" if r.hit else "characters_cooked") + 1)

    store.save()

    toc = {
        "version": TOC_VERSION,
        "cookerVersion": hashing.COOKER_VERSION,
        "entries": dict(sorted(entries.items())),
    }
    toc_path = os.path.join(out_dir, TOC_NAME)
    with open(toc_path, "w", encoding="utf-8") as f:
        json.dump(toc, f, indent=2, sort_keys=True)
        f.write("\n")

    stats.toc_path = toc_path
    stats.elapsed_sec = round(time.perf_counter() - t0, 4)
    return stats


def plan(src_dir, out_dir, max_dim=MAX_DIM):
    """Dry-run: compute what a cook WOULD do (recook vs reuse) WITHOUT cooking or writing.
    Reads the persisted cook index if the out dir exists; creates and writes nothing."""
    chars = assets.load_characters(src_dir)
    graph = assets.build_graph(chars)
    rep = DryReport()

    store = cache.Cache(out_dir, load_index=True) if os.path.isdir(out_dir) else None

    def hit(key):
        return store.would_hit(key) if store else None

    asset_known_hash = {}   # rel -> output hash, for deps that WOULD be cache hits
    asset_recook = set()    # rels that WOULD re-cook

    tex_params = textures.params_bytes(max_dim)
    for rel in graph.textures:
        h = hit(hashing.cook_key(_read(os.path.join(src_dir, rel)), params=tex_params))
        if h:
            asset_known_hash[rel] = h; rep.textures_cache += 1
        else:
            asset_recook.add(rel); rep.textures_recook += 1

    aud_params = audio.params_bytes()
    for rel in graph.audio:
        h = hit(hashing.cook_key(_read(os.path.join(src_dir, rel)), params=aud_params))
        if h:
            asset_known_hash[rel] = h; rep.audio_cache += 1
        else:
            asset_recook.add(rel); rep.audio_recook += 1

    recook = set(asset_recook)
    for ch in chars:
        crel = f"characters/{ch.name}"
        deps = list(ch.textures) + list(ch.audio)
        if any(d in asset_recook for d in deps):
            # a dependency would change -> the character must re-serialize
            rep.characters_recook += 1; recook.add(crel); continue
        refs = ([("texture", asset_known_hash[t]) for t in ch.textures]
                + [("audio", asset_known_hash[a]) for a in ch.audio])
        canon = (ch.name + "\n" + "\n".join(f"{k}:{h}" for k, h in refs)).encode("utf-8")
        if hit(hashing.cook_key(canon, params=b"chr")):
            rep.characters_cache += 1
        else:
            rep.characters_recook += 1; recook.add(crel)

    rep.would_recook = sorted(recook)
    return rep
