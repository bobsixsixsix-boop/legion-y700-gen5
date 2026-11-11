# y700-stagecorners: KWin effect giving the stage manager's windows round corners. See stagecorners.h.
# Build on the tablet against the installed kwin-dev (must match the running KWin exactly; rebuild after every KWin
# package upgrade - ../install.sh sets up an apt hook that does it, y700-stagecorners-rebuild):
#   cmake -B build -S . -DCMAKE_BUILD_TYPE=RelWithDebInfo && cmake --build build -j8
#   LD_BIND_NOW=1 ldd -r build/bin/kwin/effects/plugins/y700_stagecorners.so   # no "undefined symbol" lines!
#   install -m 644 build/bin/kwin/effects/plugins/y700_stagecorners.so /usr/lib/aarch64-linux-gnu/qt6/plugins/kwin/effects/plugins/
# The ldd check matters: plugins load lazily, an unresolved function would abort kwin_wayland (and the whole
# session) the first time it is called, not at load. Same skeleton as linux/osk/kwin-gate.
cmake_minimum_required(VERSION 3.24)
project(y700-stagecorners LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
list(APPEND CMAKE_AUTOMOC_MACRO_NAMES KWIN_EFFECT_FACTORY KWIN_EFFECT_FACTORY_ENABLED
     KWIN_EFFECT_FACTORY_SUPPORTED KWIN_EFFECT_FACTORY_SUPPORTED_ENABLED)

find_package(ECM 6.0 REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH})
# without these kcoreaddons_add_plugin silently builds a STATIC plugin (BUILD_SHARED_LIBS unset): no .so at all
include(KDEInstallDirs)
include(KDECMakeSettings)
# KWin::kwin links Qt6::Widgets and OpenGL in its interface, so they must be found too
find_package(Qt6 6.8 REQUIRED COMPONENTS Core Gui DBus Widgets OpenGL)
find_package(KF6 REQUIRED COMPONENTS CoreAddons)
find_package(KWin REQUIRED COMPONENTS kwineffects)

kcoreaddons_add_plugin(y700_stagecorners SOURCES main.cpp stagecorners.cpp INSTALL_NAMESPACE "kwin/effects/plugins")
target_compile_definitions(y700_stagecorners PRIVATE QT_NO_KEYWORDS)
target_link_libraries(y700_stagecorners PRIVATE KWin::kwin Qt6::Core Qt6::Gui Qt6::DBus KF6::CoreAddons)
