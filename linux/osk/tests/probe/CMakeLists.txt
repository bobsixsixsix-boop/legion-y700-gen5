cmake_minimum_required(VERSION 3.20)
project(y700-osk-probe LANGUAGES CXX)
# Test client for y700-osk: one focused text field that logs every text change to stdout,
# so the whole path (keyboard -> fcitx5 -> text-input-v3 -> app) can be checked end to end.
set(CMAKE_CXX_STANDARD 20)
find_package(Qt6 REQUIRED COMPONENTS Widgets)
add_executable(y700-osk-probe probe.cpp)
target_link_libraries(y700-osk-probe PRIVATE Qt6::Widgets)
