cmake_minimum_required(VERSION 3.20)
project(y700-osk LANGUAGES CXX)
# Y700 on-screen keyboard: a Qt6/QML layer-shell keyboard in the control centre's frosted glass,
# laid out after vivo OriginOS's tablet keyboard (see linux/osk-design). It replaces only the
# desktop UI of fcitx5-osk: fcitx5 + rime stay the engine, reached over fcitx5's DBus virtual
# keyboard interface; the lock screen keeps fcitx5-osk's input-panel keyboard.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 6.6 REQUIRED COMPONENTS Core Gui Qml Quick DBus Network Svg)
find_package(LayerShellQt REQUIRED)
find_package(KF6WindowSystem REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(PIPEWIRE REQUIRED IMPORTED_TARGET libpipewire-0.3)

add_executable(y700-osk
    src/main.cpp src/osk.cpp src/fcitx.cpp src/sound.cpp src/haptics.cpp src/voice.cpp src/iconprovider.cpp src/gate.cpp)
target_link_libraries(y700-osk PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick Qt6::DBus Qt6::Network Qt6::Svg
    LayerShellQtInterface KF6::WindowSystem PkgConfig::PIPEWIRE)
target_compile_definitions(y700-osk PRIVATE
    QML_DIR="${CMAKE_INSTALL_PREFIX}/share/y700-osk/qml"
    DATA_DIR="${CMAKE_INSTALL_PREFIX}/share/y700-osk")
# the gate's panel DPMS files on a fake sysfs; not built by default:
#   cmake --build build --target gate-dpms-test && build/gate-dpms-test
add_executable(gate-dpms-test EXCLUDE_FROM_ALL tests/gate-dpms-test.cpp src/gate.cpp)
target_link_libraries(gate-dpms-test PRIVATE Qt6::Core Qt6::DBus)

install(TARGETS y700-osk RUNTIME DESTINATION bin)
install(DIRECTORY qml/ DESTINATION share/y700-osk/qml)
install(FILES data/icons.json DESTINATION share/y700-osk)
