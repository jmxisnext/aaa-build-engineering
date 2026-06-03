// Shotmeter.cpp — implementation of the ShotMeter gameplay system.
//
// Earlier revisions defined the struct + function inline in this file
// (back when it was a broker-policy test target, not a library).
// Refactored at the Track 2 seed to declare the API in Shotmeter.h.
#include "Shotmeter.h"

namespace HoopsBrawl {

float NeedlePosition(const ShotMeter& m, float t_ms) {
    return t_ms / m.release_window_ms;
}

}  // namespace HoopsBrawl
