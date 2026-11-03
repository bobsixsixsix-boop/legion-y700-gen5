cmake_minimum_required(VERSION 3.20)
project(y700-battery-page LANGUAGES CXX)
# The battery page (tier 2, linux/power/battery/DESIGN.md section 6; the C++/QML interface is section 6b.c): the charge
# curve since the last full charge, over 24 h and 7 days, and what used the battery - the numbers come from
# y700-battery-report --json (../report). Started by the launcher /usr/local/bin/y700-battery (../y700-battery), built
# and installed to /usr/local/libexec/y700-battery-page by ../install.sh --page.
# Unlike the dock and the control centre, which engine.load() a QML directory on disk, the QML is compiled into the
# binary as the module Y700.BatteryPage (engine.loadFromModule): the page is a one-shot program, one file installs it
# whole, and a new binary can never meet old QML. org.kde.kirigami (icons) and QtQuick.Shapes (the curve) are only
# imported by the QML, so they are run-time dependencies, not link ones.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(Qt6 6.6 REQUIRED COMPONENTS Core Gui Qml Quick)
# AUTOMOC, and the 6.5 policies: QTP0001 puts the module under qrc:/qt/qml/, which is on the engine's import path
qt_standard_project_setup(REQUIRES 6.5)

qt_add_executable(y700-battery-page src/main.cpp src/report.cpp src/report.h)

set(PAGE_QML qml/Main.qml qml/Segmented.qml qml/Summary.qml qml/Chart.qml qml/Composition.qml qml/UsageList.qml
    qml/UsageRow.qml qml/Detail.qml qml/Fmt.js)
# The sources sit in qml/, but in the module every file goes at its root, next to the generated qmldir
# (qrc:/qt/qml/Y700/BatteryPage/Main.qml): the files then see each other through the implicit import of their own
# directory, which is the module's, and `import "Fmt.js" as Fmt` resolves beside them. Kept in qml/ they would land in
# a qml/ resource directory with no qmldir of its own.
foreach(f IN LISTS PAGE_QML)
    get_filename_component(name ${f} NAME)
    set_source_files_properties(${f} PROPERTIES QT_RESOURCE_ALIAS ${name})
endforeach()
qt_add_qml_module(y700-battery-page URI Y700.BatteryPage VERSION 1.0 QML_FILES ${PAGE_QML})

target_link_libraries(y700-battery-page PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick)
# not on PATH: only the launcher starts it (it adds the scope and the one-page-per-screen rule)
install(TARGETS y700-battery-page RUNTIME DESTINATION libexec)
