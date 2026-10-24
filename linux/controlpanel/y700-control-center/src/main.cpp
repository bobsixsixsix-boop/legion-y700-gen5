// y700-control-center: a transparent full-screen layer-shell overlay (so taps outside the sheet close
// it) holding the frosted control sheet on the right. Hidden (unmapped) when closed, so it costs nothing
// and lets input through. D-Bus: fyi.y700.ControlCenter /ControlCenter toggle|show|hide|back, and
// pullBegin|pullMove|pullEnd from the pull-down strip y700-cc-pull (src/pull.cpp, its own process: see
// there why); signal openChanged(bool) for the strip. The apps' tray items (「后台应用」) come from src/tray.h.
#include "backend.h"
#include "tray.h"
#include <LayerShellQt/Shell>
#include <LayerShellQt/Window>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <cstdio>

int main(int argc, char **argv)
{
    LayerShellQt::Shell::useLayerShell();
    QGuiApplication app(argc, argv);
    app.setApplicationName("y700-control-center");
    app.setQuitOnLastWindowClosed(false);

    Backend backend;
    QDBusConnection bus = QDBusConnection::sessionBus();
    if (!bus.registerService("fyi.y700.ControlCenter")) {
        // already running: ask it instead
        bus.call(QDBusMessage::createMethodCall("fyi.y700.ControlCenter", "/ControlCenter", "fyi.y700.ControlCenter",
                                                argc > 1 ? QString::fromLatin1(argv[1]).remove("--") : "toggle"));
        return 0;
    }
    bus.registerObject("/ControlCenter", &backend, QDBusConnection::ExportScriptableSlots | QDBusConnection::ExportScriptableSignals);
    // the StatusNotifierItem host: after the single-instance check (a second process must not register as one more
    // host), before the engine (which goes first at exit, with the QML that reads it)
    Tray tray;
    QObject::connect(&backend, &Backend::visibleChanged, &tray, [&] { tray.setOpen(backend.visible()); });

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("backend", &backend);
    engine.rootContext()->setContextProperty("tray", &tray);
    engine.addImageProvider(QStringLiteral("sni"), tray.imageProvider());
    engine.load(QUrl::fromLocalFile(QStringLiteral(QML_DIR "/Main.qml")));
    if (engine.rootObjects().isEmpty()) { fprintf(stderr, "QML failed to load\n"); return 1; }
    auto *win = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
    if (!win) { fprintf(stderr, "root is not a Window\n"); return 1; }

    auto *ls = LayerShellQt::Window::get(win);
    ls->setLayer(LayerShellQt::Window::LayerOverlay);
    ls->setAnchors({LayerShellQt::Window::AnchorTop | LayerShellQt::Window::AnchorBottom |
                    LayerShellQt::Window::AnchorLeft | LayerShellQt::Window::AnchorRight});
    ls->setExclusiveZone(-1);                      // cover panels too, never push anything around
    ls->setKeyboardInteractivity(LayerShellQt::Window::KeyboardInteractivityNone);
    // The scope is KWin's window type for a layer-shell surface (LayerShellV1Integration: desktop, dock,
    // notification, tooltip, on-screen-display, dialog, splash, utility; anything else = Normal). As a Normal
    // window the curtain got the scale effect's map animation (200 ms, 0.8 -> 1 plus a fade): its first frames
    // came up scaled around the centre and the blur with them, and the blur effect skips a transformed window
    // unless the effect forces it (10-22). "dock" is what the status bar is too: no open/close animation,
    // never a card in the task switcher. The stacking is still the overlay layer, not the dock layer (KWin
    // puts layer-shell windows by their layer, not by type); the KWin scripts that key on this window do it
    // by resourceClass, unchanged.
    ls->setScope(QStringLiteral("dock"));
    backend.setWindow(win);
    tray.setWindow(win);

    if (argc > 1 && QString::fromLatin1(argv[1]) == "--show") backend.show();
    return app.exec();
}
