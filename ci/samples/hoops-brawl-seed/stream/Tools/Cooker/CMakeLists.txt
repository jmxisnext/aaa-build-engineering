# hoops_cooker — tiny asset packer. Reads <input_dir>/*.txt, writes a
# single .pak with a fixed 16-byte header. Exists so the Cook Data CI
# stage produces a real artifact (not just a placeholder), and so the
# Package stage has something material to bundle alongside the game exe.
add_executable(hoops_cooker Cooker.cpp)
