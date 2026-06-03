// Smallest program that proves the activated MSVC toolchain compiles AND
// runs. _MSC_VER is baked in at compile time, so the runtime output also
// confirms *which* compiler built it (1916 = VS2017 15.9, 192x = VS2019).
#include <cstdio>

int main() {
    std::printf("hello from MSVC (_MSC_VER=%d)\n", _MSC_VER);
    return 0;
}
