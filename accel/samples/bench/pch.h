#pragma once
// Precompiled-header prefix for the benchmark. A real PCH collects the stable,
// expensive headers every TU includes; here that's heavy.h (which pulls in
// <regex> et al.). The /Yc pass compiles this once into a .pch; /Yu TUs consume
// it and skip the parse entirely -- the same "parse once" win unity gets, but
// WITHOUT merging the TUs, so per-TU incremental-rebuild granularity survives.
//
// Every TU's first line is `#include "pch.h"` so /Yu can substitute the .pch.
// Compiled without /Yu (serial/MP/unity configs) it's a transparent passthrough
// to heavy.h, so all configs compile identical source.
#include "heavy.h"
