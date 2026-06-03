# hoops_tests — unit test exe for hoops_core. Dependency-free runner
# (no GoogleTest/Catch2 fetch) so the build agent doesn't need outbound
# network beyond Perforce sync.
add_executable(hoops_tests ShotmeterTests.cpp)
target_link_libraries(hoops_tests PRIVATE hoops_core)
add_test(NAME shotmeter COMMAND hoops_tests)
