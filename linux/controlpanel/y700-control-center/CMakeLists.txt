cmake_minimum_required(VERSION 3.20)
project(y700-control-center LANGUAGES C CXX)
# Y700 control centre: a frosted sheet on the right that comes down from the top (layer-shell overlay),
# KWin blur behind it, tiles for Wi-Fi/Bluetooth/rotation lock/game overlay/bypass charging/torch/
# screen recording/auto brightness, brightness + volume pills, performance profile, and a two-step
# "reboot to Android". Pulled down from the right half of the top edge (its own thin layer-shell strip), toggled
# over D-Bus (fyi.y700.ControlCenter); it also sends the back key for the left/right edge swipe (KWin script).
# The apps' tray items (「后台应用」, src/tray.cpp): a StatusNotifierItem host with their com.canonical.dbusmenu menus.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 6.6 REQUIRED COMPONENTS Core Gui GuiPrivate Qml Quick DBus)
find_package(LayerShellQt REQUIRED)
# KF6WindowSystem: KWaylandExtras only (src/tray.cpp, the xdg-activation token a tray item's Activate passes on, as
# linux/dock/y700-shellbar's apps.cpp does for a launch); the blur is our own (wlblur.h says why)
find_package(KF6WindowSystem REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(WAYLAND REQUIRED IMPORTED_TARGET wayland-client)
find_program(WAYLAND_SCANNER wayland-scanner REQUIRED)
# org_kde_kwin_fake_input (the back key): the trimmed protocol file also used by linux/gesture/tests/ftouch
set(FI_XML ${CMAKE_CURRENT_SOURCE_DIR}/protocol/fake-input.xml)
add_custom_command(OUTPUT fake-input-client-protocol.h fake-input-protocol.c
    COMMAND ${WAYLAND_SCANNER} client-header ${FI_XML} fake-input-client-protocol.h
    COMMAND ${WAYLAND_SCANNER} private-code ${FI_XML} fake-input-protocol.c
    DEPENDS ${FI_XML})
# org_kde_kwin_blur (the curtain's frosted glass, src/wlblur.cpp - not KWindowSystem's enableBlurBehind, it says
# why): plasma-wayland-protocols' blur.xml, copied verbatim (the package is not a build dependency this way)
set(BLUR_XML ${CMAKE_CURRENT_SOURCE_DIR}/protocol/blur.xml)
add_custom_command(OUTPUT blur-client-protocol.h blur-protocol.c
    COMMAND ${WAYLAND_SCANNER} client-header ${BLUR_XML} blur-client-protocol.h
    COMMAND ${WAYLAND_SCANNER} private-code ${BLUR_XML} blur-protocol.c
    DEPENDS ${BLUR_XML})

add_executable(y700-control-center src/main.cpp src/backend.cpp src/fakekeys.cpp src/wlblur.cpp src/tray.cpp
    ${CMAKE_CURRENT_BINARY_DIR}/fake-input-protocol.c ${CMAKE_CURRENT_BINARY_DIR}/fake-input-client-protocol.h
    ${CMAKE_CURRENT_BINARY_DIR}/blur-protocol.c ${CMAKE_CURRENT_BINARY_DIR}/blur-client-protocol.h)
target_include_directories(y700-control-center PRIVATE ${CMAKE_CURRENT_BINARY_DIR})
# Qt6::GuiPrivate (qt6-base-private-dev): the qpa header that names the window's wl_surface, the one the blur
# objects are made for (src/backend.cpp attachBlurSurface); the same interface KWindowSystem uses
target_link_libraries(y700-control-center PRIVATE Qt6::Core Qt6::Gui Qt6::GuiPrivate Qt6::Qml Qt6::Quick Qt6::DBus
    LayerShellQtInterface KF6::WindowSystem PkgConfig::WAYLAND)
# the pull-down strip, its own process (src/pull.cpp says why)
add_executable(y700-cc-pull src/pull.cpp)
target_link_libraries(y700-cc-pull PRIVATE Qt6::Core Qt6::Gui Qt6::DBus LayerShellQtInterface)
install(TARGETS y700-cc-pull RUNTIME DESTINATION bin)
target_compile_definitions(y700-control-center PRIVATE QML_DIR="${CMAKE_INSTALL_PREFIX}/share/y700-control-center/qml")
install(TARGETS y700-control-center RUNTIME DESTINATION bin)
# backups made next to the sources on the tablet (Main.qml.bak-DATE) must not be installed with the QML
install(DIRECTORY qml/ DESTINATION share/y700-control-center/qml PATTERN "*.bak*" EXCLUDE)
