# samples/fbuild — FASTBuild lever (cache + distribution)

[FASTBuild](https://www.fastbuild.org) is the open-source build orchestrator the
public AAA world documents (Ubisoft et al.). `fbuild.bff` compiles the same
`../bench/` heavy TUs as `bench.ps1`, so FASTBuild slots into the same
comparison. `../../scripts/demo-fbuild.ps1` drives it; `FBuild.exe` is a
gitignored vendor binary (see `../../tools/fastbuild/README.md` to fetch it).

## Result (2026-06-03 · 32 TUs · 16 logical cores · FASTBuild v1.20 · MSVC 19.29)

| state | best(s) | vs cache-miss |
|---|---|---|
| clean (cache miss) | 5.33 | 1.00× |
| clean (cache **HIT**) | 0.37 | 14.4× |
| no-op (incremental) | 0.01 | 533× |

```powershell
pwsh -File .\accel\scripts\demo-fbuild.ps1
```

## What this shows that `/MP` / unity / PCH don't

A from-scratch FASTBuild (5.33 s) is ~the same as `/MP` (5.10 s) — FASTBuild
parallelizes across cores by default, so on a cold build with an empty cache
it's just another parallel compile (and cold unity, 0.72 s, still beats it).

The difference is the **content-addressable cache**. FASTBuild keys each object
on `(preprocessed source + compiler + options)`. Once a TU is built and stored,
*any later build of identical input* retrieves the `.obj` instead of compiling
it — proven by the `<CACHE>` marker FASTBuild prints on every object and the
0.37 s clean-build time (14× faster than recompiling). That covers the work
that dominates real studio cost:

- **CI re-runs** the same commit on every PR push.
- **Branch switches** recompile files already built on another branch.
- **A teammate's clean build** of code you already compiled (a *shared* cache
  on a network/object-store path makes those hits cross-machine).

`/MP`, unity, and PCH each speed up a *single* compile; none makes the *second
identical* compile free. FASTBuild does — that's its reason to exist.

## Beyond caching (not measured here)

- **Distribution.** `FBuildWorker.exe` turns idle machines into a compile farm;
  FASTBuild ships TUs to them (the Incredibuild-style story, open source). The
  same `.bff` scales from one box to a farm with no change.
- **One graph for the whole build.** A `.bff` describes compile + link + custom
  steps (asset cooks, codegen) as one dependency graph, so the incremental
  no-op (0.01 s here) extends to the entire pipeline, not just compilation.

## Honest caveats

- Cache-miss ≈ `/MP` because both are cold parallel compiles; **the levers
  compose, they don't compete** — you'd compile the cold path with unity/PCH
  options *and* lean on the cache for the warm path.
- This is a *local* cache on one machine. The studio win is a **shared** cache
  (`.CachePath` on a network/object store) so the whole team + CI share hits —
  same mechanism, just a shared path.
- FASTBuild builds are **hermetic**: it does not inherit the shell environment,
  so `fbuild.bff`'s `Settings.Environment` is fed `PATH`/`INCLUDE`/`TMP`/
  `SystemRoot` from the activated vcvars (injected via `_generated.bff`). That
  strictness is the feature — it's what makes cache keys reproducible across
  machines.
