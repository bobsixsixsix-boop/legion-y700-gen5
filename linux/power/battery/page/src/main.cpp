// y700-battery-page: the battery page (tier 2, linux/power/battery/DESIGN.md section 6; the C++/QML interface is
// section 6b.c), started by /usr/local/bin/y700-battery in a scope of its own. A plain maximized window: the QML module
// Y700.BatteryPage compiled into this binary, and the context object "backend" (report.h) for everything it shows.
// The desktop file name is the window's Wayland app_id: y700-battery.desktop gives it its name and icon in the dock
// and the task switcher, and the test beds (battcap.sh, batpage.sh) find the window by it.
// Test bed arguments: --range since_full|24h|7d (the range shown first), --detail <item id> (that item's details open
// at start, if the range has it); Y700_BATTERY_REPORT=<json file> stands in for the report (report.h).
#include "report.h"
#include <QCommandLineOption>
#include <QCommandLineParser>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QString>
#include <QStringList>
#include <cstdio>

int main(int argc, char **argv)
{
    QGuiApplication app(argc, argv);
    QGuiApplication::setApplicationName(QStringLiteral("y700-battery"));
    // before the window exists: the app_id is sent with the xdg_toplevel when the window is created
    QGuiApplication::setDesktopFileName(QStringLiteral("y700-battery"));

    QCommandLineParser cl;
    const QCommandLineOption range(QStringLiteral("range"), QStringLiteral("range shown first: since_full, 24h or 7d"),
                                   QStringLiteral("key"));
    const QCommandLineOption detail(QStringLiteral("detail"), QStringLiteral("item whose details open at start"),
                                    QStringLiteral("id"));
    cl.addOption(range);
    cl.addOption(detail);
    // parse(), not process(): a stray argument is reported and the page still opens (process() would exit)
    if (!cl.parse(QGuiApplication::arguments()))
        fprintf(stderr, "y700-battery-page: %s (ignored)\n", qPrintable(cl.errorText()));
    QString startRange = cl.value(range);
    if (!startRange.isEmpty()
        && !QStringList{QStringLiteral("since_full"), QStringLiteral("24h"), QStringLiteral("7d")}.contains(startRange)) {
        fprintf(stderr, "y700-battery-page: --range %s is not since_full, 24h or 7d (ignored)\n", qPrintable(startRange));
        startRange.clear();
    }

    // before the engine, so that the engine (and the QML reading "backend") goes first at exit
    Backend backend(startRange, cl.value(detail));
    // the cache and the live state are in place for the QML's first frame; the report is started meanwhile
    backend.start();

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("backend"), &backend);
    engine.loadFromModule("Y700.BatteryPage", "Main");
    if (engine.rootObjects().isEmpty()) {
        fprintf(stderr, "y700-battery-page: the QML module Y700.BatteryPage did not load\n");
        return 1;
    }
    auto *win = qobject_cast<QQuickWindow *>(engine.rootObjects().constFirst());
    if (!win) {
        fprintf(stderr, "y700-battery-page: Main.qml's root is not a Window\n");
        return 1;
    }
    backend.setWindow(win);
    // the root is visible: false, so it is shown once, already maximized: no first frame at the default size
    win->showMaximized();
    return app.exec();
}
