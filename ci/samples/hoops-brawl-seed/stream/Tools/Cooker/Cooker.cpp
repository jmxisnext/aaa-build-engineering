// Cooker.cpp — minimal asset packer.
//
// Reads <input_dir>/*.txt, concatenates them into <output_pak> with a
// 16-byte header:
//
//   bytes  0..7  : magic "AAAPAK01"
//   bytes  8..15 : little-endian uint64 file count
//
// No table of contents — this is intentionally the simplest packer
// that still produces a structured, parseable artifact. The point at
// this stage is to make Cook Data a *real* CI step, not to design a
// real asset format.
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

int main(int argc, char** argv) {
    if (argc != 3) {
        std::fprintf(stderr, "usage: hoops_cooker <input_dir> <output_pak>\n");
        return 2;
    }
    const fs::path in_dir = argv[1];
    const fs::path out_pak = argv[2];

    if (!fs::is_directory(in_dir)) {
        std::fprintf(stderr, "hoops_cooker: input dir not found: %s\n",
                     in_dir.string().c_str());
        return 1;
    }

    std::vector<fs::path> inputs;
    for (const auto& e : fs::directory_iterator(in_dir)) {
        if (e.is_regular_file() && e.path().extension() == ".txt") {
            inputs.push_back(e.path());
        }
    }
    std::sort(inputs.begin(), inputs.end());  // deterministic ordering

    std::ofstream out(out_pak, std::ios::binary);
    if (!out) {
        std::fprintf(stderr, "hoops_cooker: cannot open output: %s\n",
                     out_pak.string().c_str());
        return 1;
    }

    out.write("AAAPAK01", 8);
    const uint64_t count = inputs.size();
    out.write(reinterpret_cast<const char*>(&count), sizeof(count));

    for (const auto& p : inputs) {
        std::ifstream in(p, std::ios::binary);
        out << in.rdbuf();
    }

    std::printf("hoops_cooker: packed %llu file(s) -> %s\n",
                static_cast<unsigned long long>(count),
                out_pak.string().c_str());
    return 0;
}
