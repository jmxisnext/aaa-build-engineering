# samples/bench — build-acceleration benchmark

`heavy.h` is a deliberately expensive compile fixture (`<regex>` +
associative-container instantiation over several type pairs, compiled `/O2`).
`../../scripts/bench.ps1` stamps N thin translation units that each
`#include "heavy.h"`, then times **four ways of compiling the same N TUs** —
best of 3 cold reps (object dir wiped before each rep), compile-only (`/c`,
no link) so it's apples-to-apples:

| config | command | header parses | parallel? |
|---|---|---|---|
| serial (per-TU) | `cl /c tu00..tuNN` | N | no |
| `/MP` (per-TU) | `cl /MP /c tu00..tuNN` | N | yes |
| unity (1 file) | `cl /c unity_all.cpp` | 1 | no |
| unity ×K + `/MP` | `cl /MP /c unity_c00..cKK` | K | yes |

## Result (2026-06-03 · 32 TUs · 16 logical cores · MSVC 19.29)

| config | best(s) | vs serial |
|---|---|---|
| serial (per-TU) | 20.22 | 1.00× |
| `/MP` (per-TU) | 4.98 | 4.06× |
| **unity (1 file)** | **0.73** | **27.70×** |
| unity ×8 + `/MP` | 1.49 | 13.57× |

```powershell
pwsh -File .\accel\scripts\bench.ps1            # 32 TUs, auto chunks, 3 reps
pwsh -File .\accel\scripts\bench.ps1 -TU 64     # scale the TU count up
```

## Reading the result (the actual lesson)

**Two different strategies that don't combine the way you'd guess:**

- `/MP` **parallelizes** the work — it still parses `heavy.h` once per TU (32
  times), just spreads those parses across cores. ~4× on 16 *logical* cores
  (hyperthreads, not 16 real cores; plus a serial front-end + obj-write tail).
- **unity eliminates** the work — `#include`-ing all 32 TUs into one file means
  `#pragma once` makes `heavy.h` parse **once**. On this fixture the header
  parse dominates, so removing 31 of 32 parses is ~28× **on a single core** —
  it beats `/MP` outright.
- The "obvious" sweet spot (chunked unity + `/MP`: parse K times, across cores)
  is here *slower* than plain unity, because 8 parses (even in parallel) plus
  `/MP` coordination cost more than 1 parse. **When the bottleneck is redundant
  work, doing it fewer times beats doing it in parallel.**

**The honest caveat — this fixture is header-parse-dominated by design.** Each
TU has a trivial body, so almost all the time is the shared `<regex>` header.
Real code has substantial *per-TU* work (templates, codegen) that `/MP` and
chunked-unity genuinely parallelize, so on a real codebase the ranking shifts
back toward chunked-unity+`/MP`. The transferable skill isn't "unity wins" —
it's **profile where the build time actually goes, then pick the lever that
attacks that cost.**

**Unity's real-world costs** (not exercised here — the fixture is
collision-free by construction):

- **Incremental granularity collapses** — change one `.cpp` and the whole unity
  blob recompiles. Studios tune unity *chunk size* to trade clean-build speed
  against incremental-build pain (that's why the chunked config exists at all).
- **ODR / symbol bleed** — `static` helpers, anonymous namespaces, `using`
  directives, and `#define`s leak across the concatenated TUs. Unity builds
  surface latent ODR violations that per-TU compilation hid.
