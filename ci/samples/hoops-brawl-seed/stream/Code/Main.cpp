// Main.cpp — hoops_brawl entrypoint. Smoke-shaped: prints one frame of
// the shot-meter state so the Compile stage produces a binary that
// "runs and exits 0," which is the minimum a Package stage needs to
// stage something meaningful.
#include <cstdio>
#include "Shotmeter.h"

int main() {
    HoopsBrawl::ShotMeter m;
    const float t_ms = 36.0f;  // halfway through the release window
    const float needle = HoopsBrawl::NeedlePosition(m, t_ms);
    std::printf("hoops_brawl: needle=%.3f at t=%.1fms (release_window=%.1fms)\n",
                needle, t_ms, m.release_window_ms);
    return 0;
}
