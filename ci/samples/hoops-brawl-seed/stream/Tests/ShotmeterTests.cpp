// ShotmeterTests.cpp — dependency-free test runner. Each EXPECT_* macro
// increments a failure counter and prints location; main() exits with
// the failure count. ctest picks up nonzero as failure.
//
// Deliberately not pulling GoogleTest/Catch2 — the build agent runs in
// a constrained network and a fetch step would be one more thing to
// debug at first build. The day this seed becomes the actual project
// is the day we revisit (and probably switch to GoogleTest).
#include <cmath>
#include <cstdio>
#include "Shotmeter.h"

static int g_failures = 0;

#define EXPECT_NEAR(actual, expected, eps)                                 \
    do {                                                                   \
        const double _a = (actual);                                        \
        const double _e = (expected);                                      \
        if (std::fabs(_a - _e) > (eps)) {                                  \
            std::fprintf(stderr,                                           \
                "%s:%d  EXPECT_NEAR failed: %s (=%g) vs %s (=%g) eps=%g\n",\
                __FILE__, __LINE__, #actual, _a, #expected, _e, (eps));    \
            ++g_failures;                                                  \
        }                                                                  \
    } while (0)

int main() {
    using HoopsBrawl::ShotMeter;
    using HoopsBrawl::NeedlePosition;

    ShotMeter m;  // defaults: release_window_ms=75, perfect_window_ms=18

    EXPECT_NEAR(NeedlePosition(m, 0.0f),  0.0f,  1e-5);
    EXPECT_NEAR(NeedlePosition(m, 37.5f), 0.5f,  1e-5);
    EXPECT_NEAR(NeedlePosition(m, 75.0f), 1.0f,  1e-5);
    // Holding past the window should report >1 — that's how the UI
    // distinguishes "still pressed" from "released on time."
    EXPECT_NEAR(NeedlePosition(m, 90.0f), 1.2f,  1e-5);

    if (g_failures == 0) {
        std::printf("hoops_tests: OK (4 cases)\n");
        return 0;
    }
    std::fprintf(stderr, "hoops_tests: FAIL (%d failure(s))\n", g_failures);
    return 1;
}
