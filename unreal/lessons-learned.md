# Unreal lessons learned (Track 4)

Real-world gotchas hit standing up the Unreal build pipeline (Lyra on UE 5.6).
Each is the kind of thing an interviewer might phrase as *"tell me about a build
you had to debug / tune for the hardware you were on."*

## 1. Lyra clean-compile failed on *commit-limit* exhaustion, not RAM

**What happened:** First cold `LyraEditor` (Win64/Development) build via `Build.bat`
failed at `[414/423]` with:

```
c1xx: error C3859: Failed to create virtual memory for PCH
c1xx: fatal error C1076: compiler limit: internal heap limit reached
Result: Failed (OtherCompilationError)   (exit 6)
```

UBA logged `memory pressure` waits the whole way (`Available: 5.7gb / Total: 33.5gb`),
so it *looked* like a classic out-of-memory.

**Wrong first fix (instructive):** Assumed too much parallelism for 31 GB RAM and capped
`-MaxParallelActions` 16→8. **It still failed — this time with 10–12 GB physical RAM
free.** That free-RAM-at-failure was the tell: the bottleneck was never physical RAM.

**Root cause:** `C3859`/`C1076` are *virtual-memory / commit* failures, not physical-RAM
exhaustion. This box had the **Windows pagefile disabled**, so the system **commit limit
= physical RAM (31.2 GB)** with zero headroom (`Win32_OperatingSystem.TotalVirtualMemorySize`
== `Win32_ComputerSystem.TotalPhysicalMemory`; `AutomaticManagedPagefile = False`). On top
of that, **Docker Desktop's WSL2 VM** was holding ~13 GB of commit. UBA reserves a large
virtual-address block too. Between them, the parallel `cl.exe` PCH allocations (each PCH
commits a big contiguous region) tipped over the commit limit — even though "Available RAM"
looked fine. **Free physical RAM ≠ available commit when there is no pagefile.**

**Fix (what made it green):**
1. **Close Docker Desktop** — frees the commit its WSL2 VM was holding.
2. **`-NoUBA`** — drop Unreal Build Accelerator's large VA reservation (we don't need UBA
   for a plain compile; it's a deliberate Phase 2 *Step 2* demo).
   Build then succeeded with `-MaxParallelActions=8 -NoUBA`.

**Durable fix (the proper answer):** **Enable a pagefile** — system-managed, or a fixed
~32 GB on `D:` (NVMe scratch). That unpins the commit limit from physical RAM and lets
UBA + Docker + a clean build coexist without juggling. (Needs a reboot to take effect.)

**Why a build engineer cares:**
- On Windows, **commit charge — not "Available RAM" — is what kills PCH-heavy parallel C++
  builds.** Task Manager's available-memory number is a red herring for these failures.
- Three different things silently eat commit: **pagefile policy** (disabled → no headroom),
  **VM/container memory** (Docker/WSL2, Hyper-V), and **build-accelerator VA reservations**
  (UBA). A build farm has to budget commit, not just cores/RAM.
- Capping parallelism is the *naive* lever (and here it didn't work). The senior move is
  knowing commit-vs-physical-RAM and fixing the actual constraint (pagefile / VM footprint).

**Interview TL;DR:**
- `C3859 "failed to create virtual memory for PCH"` + `C1076 "internal heap limit reached"`
  with free physical RAM = **commit-limit exhaustion**, usually a too-small/disabled pagefile.
- Diagnose with commit limit vs in-use (`Win32_OperatingSystem` Total/FreeVirtualMemory),
  not Task Manager's RAM gauge.
- Fixes, cheapest → most durable: free commit (close VMs/Docker, drop UBA's reservation),
  cap `-MaxParallelActions`, then **add a pagefile** so the commit ceiling isn't physical RAM.
