# Hoops Brawl

Fictional small AAA-shaped basketball game. Test bed for the
`aaa-build-engineering` practice repo — same fiction Track 1 used
when exercising broker policy, now extended into a buildable C++
project for the Track 2 TeamCity build chain.

## Build

```sh
cmake -B build -S . -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
ctest --test-dir build --output-on-failure
```

## Targets

| Target         | Kind      | What it is                                |
|----------------|-----------|-------------------------------------------|
| `hoops_core`   | lib       | Gameplay logic (currently `ShotMeter`).   |
| `hoops_brawl`  | exe       | The game. Links `hoops_core`.             |
| `hoops_tests`  | exe       | Unit tests for `hoops_core`.              |
| `hoops_cooker` | exe       | Asset packer. `hoops_cooker DataDir OutPak.pak` |

## CI chain (TeamCity)

| Stage      | What runs                                                    |
|------------|--------------------------------------------------------------|
| Compile    | `cmake -B build -S . && cmake --build build`                |
| Smoke Test | `ctest --test-dir build --output-on-failure`                |
| Cook Data  | `build/Tools/Cooker/hoops_cooker Data build/Cooked.pak`      |
| Package    | `cmake --install build --prefix dist` then tar `dist/`       |

## Status

- Initial scaffold seeded via broker bypass during code freeze (see
  `ci/lessons-learned.md` in the practice repo).
- Linux build agent still needs cmake + a C++ toolchain installed
  before the Compile stage will pass; that's the next image bump.

## In progress (carried over from broker-policy testing)

- Shot meter (was the broker test feature; now the seed gameplay code).
