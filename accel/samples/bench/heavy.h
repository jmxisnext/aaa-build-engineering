#pragma once
// Deliberately expensive to compile. Each translation unit that includes this
// pays the full cost again (there is no PCH yet -- that's a later Track 3
// lever), so per-TU compile time is large enough that parallelizing the build
// with /MP produces a real, measurable wall-clock win.
//
// The cost comes from:
//   - <regex>, one of the heaviest standard headers in MSVC, plus an actual
//     std::regex instantiation and iteration;
//   - associative-container instantiation over several key/value type pairs;
//   - /O2 optimization work on all of the above (the demo compiles with /O2).
#include <regex>
#include <map>
#include <unordered_map>
#include <string>
#include <vector>
#include <algorithm>
#include <numeric>
#include <tuple>

template <typename K, typename V>
static V map_churn(int seed) {
    std::map<K, V> m;
    std::unordered_map<K, V> u;
    for (int i = 0; i < 48; ++i) {
        m[static_cast<K>(i + seed)] = static_cast<V>(i * 2);
        u[static_cast<K>(i + seed)] = static_cast<V>(i * 3);
    }
    V acc{};
    for (auto& kv : m) acc += kv.second;
    for (auto& kv : u) acc += kv.second;
    return acc;
}

template <int Tag>
inline long long heavy_work() {
    std::regex re(R"((\w+)\s*=\s*(\d+))");
    std::string sample = "alpha = 42, beta = 7, gamma = 1000, delta = 256";
    long long total = 0;
    for (std::sregex_iterator it(sample.begin(), sample.end(), re), end; it != end; ++it) {
        total += std::stoll((*it)[2].str());
    }
    total += map_churn<int, long long>(Tag);
    total += map_churn<long long, long long>(Tag + 1);
    total += static_cast<long long>(map_churn<unsigned, double>(Tag)); // 3rd instantiation
    std::vector<int> v(128);
    std::iota(v.begin(), v.end(), Tag);
    std::sort(v.begin(), v.end(), std::greater<int>());
    total += std::accumulate(v.begin(), v.end(), 0LL);
    return total + Tag;
}
