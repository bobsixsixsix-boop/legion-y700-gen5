cmake_minimum_required(VERSION 3.20)
project(y700-shellbar LANGUAGES C CXX)
# Y700 shell bars (2026-10-22, goal: the bottom panel becomes a dock in the style of vivo's OriginOS pad UI, plus a
# status bar; dock mode B+):
# one process, always running, holding the always-mapped surfaces that replace the Plasma panel:
#   status bar   layer-shell top, 28 px, exclusive zone: time / Wi-Fi / Bluetooth / battery; dragging it down pulls
#                the control centre (right half) or the notification centre (left half) over D-Bus
#   pull strip   overlay, 8 px, only while a fullscreen window is active (the status bar is under it then)
#   dock         layer-shell top, bottom centre: pinned apps | divider | recent apps (vivo OriginOS geometry);
#                mapped only on the desktop, or revealed in an app by a short swipe up from the bottom edge
#                (the y700-taskswitcher effect calls fyi.y700.Shellbar.reveal)
#   app grid     the dock's "all apps" button: a full-screen frosted grid of every application
#   banners      the session's notification server (org.freedesktop.Notifications, libnotificationmanager - the
#                same server plasmashell's applet ran) and its pop-ups: frosted cards at the top (qml/Banners.qml)
# Not the control centre process on purpose: KWin scripts switch the screen edges off while a window of
# y700-control-center is mapped (README 控制中心 / 多任务卡片), these surfaces are mapped all the time.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 6.6 REQUIRED COMPONENTS Core Gui GuiPrivate Qml Quick DBus)
find_package(LayerShellQt REQUIRED)
# KF6WindowSystem: KWaylandExtras only (src/apps.cpp, the xdg-activation token a started app gets); the blur is
# not its enableBlurBehind any more (wlblur.h says why)
find_package(KF6WindowSystem REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(WAYLAND REQUIRED IMPORTED_TARGET wayland-client)
find_program(WAYLAND_SCANNER wayland-scanner REQUIRED)

# KWin blur behind the dock, the banners and the app grid: the control centre's src/wlblur.cpp (one copy of the code;
# its header says why not KWindowEffects::enableBlurBehind) and its copy of plasma-wayland-protocols' blur.xml.
# WLBLUR_DIR = that project's directory: beside this one in the repository, /usr/local/src/y700-control-center on
# the tablet (where install.sh of linux/controlpanel keeps the sources it last built)
if(NOT WLBLUR_DIR)
    if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/../../controlpanel/y700-control-center/src/wlblur.cpp)
        set(WLBLUR_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../controlpanel/y700-control-center)
    else()
        set(WLBLUR_DIR /usr/local/src/y700-control-center)
    endif()
endif()
if(NOT EXISTS ${WLBLUR_DIR}/src/wlblur.cpp OR NOT EXISTS ${WLBLUR_DIR}/protocol/blur.xml)
    message(FATAL_ERROR "no src/wlblur.cpp + protocol/blur.xml under ${WLBLUR_DIR}: pass -DWLBLUR_DIR=<the y700-control-center sources>")
endif()
set(BLUR_XML ${WLBLUR_DIR}/protocol/blur.xml)
add_custom_command(OUTPUT blur-client-protocol.h blur-protocol.c
    COMMAND ${WAYLAND_SCANNER} client-header ${BLUR_XML} blur-client-protocol.h
    COMMAND ${WAYLAND_SCANNER} private-code ${BLUR_XML} blur-protocol.c
    DEPENDS ${BLUR_XML})

add_executable(y700-shellbar src/main.cpp src/shell.cpp src/status.cpp src/apps.cpp src/hud.cpp ${WLBLUR_DIR}/src/wlblur.cpp
    ${CMAKE_CURRENT_BINARY_DIR}/blur-protocol.c ${CMAKE_CURRENT_BINARY_DIR}/blur-client-protocol.h)
target_include_directories(y700-shellbar PRIVATE ${CMAKE_CURRENT_BINARY_DIR} ${WLBLUR_DIR}/src)
# Qt6::GuiPrivate (qt6-base-private-dev): the qpa header that names a window's wl_surface, the one the blur objects
# are made for (wlblur.cpp WlBlurWindow::attach)
target_link_libraries(y700-shellbar PRIVATE Qt6::Core Qt6::Gui Qt6::GuiPrivate Qt6::Qml Qt6::Quick Qt6::DBus
    LayerShellQtInterface KF6::WindowSystem PkgConfig::WAYLAND)
target_compile_definitions(y700-shellbar PRIVATE QML_DIR="${CMAKE_INSTALL_PREFIX}/share/y700-shellbar/qml")
install(TARGETS y700-shellbar RUNTIME DESTINATION bin)
install(DIRECTORY qml/ DESTINATION share/y700-shellbar/qml PATTERN "*.bak*" EXCLUDE)
