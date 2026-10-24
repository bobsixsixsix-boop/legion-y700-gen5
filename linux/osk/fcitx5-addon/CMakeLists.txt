cmake_minimum_required(VERSION 3.16)
project(fcitx5-y700osk VERSION 0.1 LANGUAGES CXX)
# Build with -DCMAKE_INSTALL_PREFIX=/usr so the files land where fcitx5 looks
# (/usr/lib/aarch64-linux-gnu/fcitx5/ and /usr/share/fcitx5/addon/). Needs fcitx5-modules-dev.
find_package(Fcitx5Core 5.1.19 REQUIRED)
find_package(Fcitx5ModuleDBus REQUIRED)
include("${FCITX_INSTALL_CMAKECONFIG_DIR}/Fcitx5Utils/Fcitx5CompilerSettings.cmake")
add_fcitx5_addon(y700osk y700osk.cpp)
target_link_libraries(y700osk Fcitx5::Core Fcitx5::Module::DBus)
install(TARGETS y700osk DESTINATION "${FCITX_INSTALL_ADDONDIR}")
install(FILES y700osk.conf DESTINATION "${FCITX_INSTALL_PKGDATADIR}/addon")
