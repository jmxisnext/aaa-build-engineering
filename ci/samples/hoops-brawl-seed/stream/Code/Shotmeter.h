// Shotmeter.h — public interface for the ShotMeter gameplay system.
//
// Split out from Shotmeter.cpp during the Track 2 seed: once the file
// became part of a library that other translation units (the game exe,
// the test exe) link against, the inline struct/function in the .cpp
// stopped being sufficient.
#pragma once

namespace HoopsBrawl {

struct ShotMeter {
    float release_window_ms = 75.0f;
    float perfect_window_ms = 18.0f;
    bool  show_release_indicator = true;
};

// Returns the needle's normalized position [0, 1+] at time `t_ms` into
// the release window. Values >1 indicate the player held past the
// window's end.
float NeedlePosition(const ShotMeter& m, float t_ms);

}  // namespace HoopsBrawl
