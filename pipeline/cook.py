#!/usr/bin/env python3
"""Track 5 cooker CLI: cook synthetic assets into content-addressed binaries + a .toc.

    python pipeline/cook.py                       # cook pipeline/assets -> pipeline/cooked
    python pipeline/cook.py --force               # ignore the cache (clean re-cook)
    python pipeline/cook.py --stats-json s.json   # also write run stats as JSON

Thin glue over cooker.pipeline.run (which carries the tested logic). Exit 0 on success.
"""
import argparse
import dataclasses
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cooker import pipeline  # noqa: E402

_HERE = os.path.dirname(os.path.abspath(__file__))


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--src", default=os.path.join(_HERE, "assets"), help="source asset root")
    p.add_argument("--out", default=os.path.join(_HERE, "cooked"), help="cooked output / CAS dir")
    p.add_argument("--force", action="store_true", help="ignore the cache; clean re-cook")
    p.add_argument("--stats-json", help="also write run stats to this path")
    p.add_argument("--dry-run", action="store_true",
                   help="report what WOULD recook vs reuse; write nothing")
    p.add_argument("--pack", help="also pack cooked blobs + toc into a single .pak at this path")
    args = p.parse_args(argv)

    if not os.path.isdir(args.src):
        p.error(f"source dir not found: {args.src} (run scripts/make-samples.py first)")

    if args.dry_run:
        rep = pipeline.plan(args.src, args.out)

        def dline(label, recook, reuse):
            return f"  {label:<11} recook {recook:>3}   reuse {reuse:>3}"

        print(f"dry-run: {args.src} -> {args.out}  (nothing written)")
        print(dline("textures", rep.textures_recook, rep.textures_cache))
        print(dline("audio", rep.audio_recook, rep.audio_cache))
        print(dline("characters", rep.characters_recook, rep.characters_cache))
        if rep.would_recook:
            print("  would recook:")
            for r in rep.would_recook:
                print(f"    {r}")
        else:
            print("  all up to date - nothing would recook.")
        return 0

    st = pipeline.run(args.src, args.out, force=args.force)

    def line(label, cooked, cached):
        return f"  {label:<11} cooked {cooked:>3}   cached {cached:>3}"

    print(f"cook: {args.src} -> {args.out}")
    print(line("textures", st.textures_cooked, st.textures_cached))
    print(line("audio", st.audio_cooked, st.audio_cached))
    print(line("characters", st.characters_cooked, st.characters_cached))
    print(f"  store      {st.total_bytes:>7} bytes   {st.elapsed_sec:.4f}s")
    print(f"  toc: {st.toc_path}")

    if args.stats_json:
        stats_dir = os.path.dirname(args.stats_json)
        if stats_dir:
            os.makedirs(stats_dir, exist_ok=True)
        with open(args.stats_json, "w", encoding="utf-8") as f:
            json.dump(dataclasses.asdict(st), f, indent=2, sort_keys=True)
        print(f"  stats: {args.stats_json}")

    if args.pack:
        from cooker import pak  # local import; only needed for --pack
        n = pak.pack(args.out, st.toc_path, args.pack)
        print(f"  pak: {args.pack} ({n} entries)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
