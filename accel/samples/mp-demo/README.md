# samples/mp-demo — `/MP` parallel-compilation benchmark

`heavy.h` is a deliberately expensive header (`<regex>` + associative-container
instantiation over several type pairs, compiled `/O2`). The benchmark script
`../../scripts/demo-mp.ps1` stamps N thin translation units that each
`#include` it, then compiles the whole set two ways — identical except for one
flag — and reports the best wall-time of 3 cold-compile reps:

```
serial   : cl /c   tu00.cpp .. tuNN.cpp     (one process, TUs sequential)
parallel : cl /MP /c  tu00.cpp .. tuNN.cpp  (one process, TUs across cores)
```

## Result (2026-06-03 · 16 TUs · 16 logical cores · MSVC 19.29)

| Build | Best wall-time |
|---|---|
| serial (`cl /c`) | **10.02 s** |
| parallel (`cl /MP /c`) | **2.54 s** |
| **speedup** | **3.94×** |

Reps were tight (serial 10.34/10.02/10.05; parallel 2.54/2.54/2.58), so this
is a stable number, not a lucky run.

```powershell
pwsh -File .\accel\scripts\demo-mp.ps1            # 16 TUs, 3 reps (default)
pwsh -File .\accel\scripts\demo-mp.ps1 -TU 32     # scale the TU count up
```

## Why ~4×, not 16×

- **16 *logical* cores ≈ 8 physical + hyperthreading.** Compilation is
  compute- and memory-bandwidth-bound, so HT siblings don't add a full core's
  worth of throughput.
- **`/MP` parallelizes the TUs within a single `cl` invocation**, but the
  front-end that hands out work and the per-obj writes aren't free.
- **Every TU independently re-parses the same `heavy.h`** — there's no PCH
  yet. Parallelism *hides* that redundant work; it doesn't remove it. Removing
  it is exactly what **PCH** and **unity/jumbo builds** do next, which is why
  they're the following roadmap items.

`/MP` (parallel within a project) is orthogonal to MSBuild `/m` (parallel
*across* projects); a real build turns on both.
