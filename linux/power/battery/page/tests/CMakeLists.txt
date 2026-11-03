cmake_minimum_required(VERSION 3.20)
project(bp-state-test LANGUAGES CXX)
# The battery page's offscreen test bed (state-test.cpp says what it checks and how to run it): the page's backend
# (../src/report.cpp) built in, the page's QML read from ../qml through UsageListBed.qml. Not part of the page:
# ../CMakeLists.txt does not include this directory and install.sh does not build it.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(Qt6 6.6 REQUIRED COMPONENTS Core Gui Qml Quick)
qt_standard_project_setup(REQUIRES 6.5)

qt_add_executable(bp-state-test state-test.cpp ../src/report.cpp ../src/report.h)
target_include_directories(bp-state-test PRIVATE ../src)
target_compile_definitions(bp-state-test PRIVATE BED_DIR="${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(bp-state-test PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick)
