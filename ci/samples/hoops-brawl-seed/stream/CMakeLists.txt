# Hoops Brawl — root CMake.
#
# Four targets, one per CI stage:
#   hoops_core    static library, gameplay logic (currently just ShotMeter)
#   hoops_brawl   game executable, links hoops_core
#   hoops_tests   unit-test executable, depends on hoops_core
#   hoops_cooker  asset packer — reads Data/*.txt, writes Cooked.pak
#
# Kept dependency-free on purpose: no GoogleTest fetch, no third-party
# pulls during configure. The Linux build agent runs in a sandboxed
# network and we want the build to succeed without outbound traffic
# beyond Perforce sync.

cmake_minimum_required(VERSION 3.20)
project(hoops_brawl CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Warnings on by default — interview-shaped expectation: any AAA shop
# treats warnings as the first line of defense against the bug classes
# that hide best in C++ (uninitialized reads, narrowing conversions,
# fallthroughs). Promote to -Werror once the codebase grows past a
# trivial seed.
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    add_compile_options(-Wall -Wextra -Wpedantic)
elseif(MSVC)
    add_compile_options(/W4)
endif()

enable_testing()

add_subdirectory(Code)
add_subdirectory(Tests)
add_subdirectory(Tools/Cooker)

# Install rule for the Package CI stage: stage everything into a single
# directory that the stage can then zip/tar.
install(TARGETS hoops_brawl hoops_cooker
        RUNTIME DESTINATION bin)
install(DIRECTORY Data DESTINATION .)
