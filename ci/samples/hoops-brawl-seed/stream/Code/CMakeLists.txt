# hoops_core — gameplay library. The unit-of-build the test exe links
# against. Keep purely header-and-cpp; no transitive third-party deps.
add_library(hoops_core STATIC
    Shotmeter.cpp
)
target_include_directories(hoops_core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

# hoops_brawl — the game exe. Tiny shim that prints a single frame of
# shot-meter state; enough to verify "the lib links and runs" at the
# Compile stage.
add_executable(hoops_brawl Main.cpp)
target_link_libraries(hoops_brawl PRIVATE hoops_core)
