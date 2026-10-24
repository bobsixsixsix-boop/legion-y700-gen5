// y700-osk: the Y700 on-screen keyboard (Qt6/QML layer shell, fcitx5 DBus virtual keyboard UI).
//   y700-osk            run the keyboard (claims org.fcitx.Fcitx5.VirtualKeyboard on the session bus)
//   y700-osk show|hide  ask the running keyboard to show/hide (fyi.y700.Osk)
//   y700-osk --preview[=state]  show the keyboard without taking over fcitx5 (screenshots, demo
//                               candidates); state = compose|toolbox|feedback|clip|edit|emoji|sym|
//                               cands|layout|voice|split|float|num|light|alts|ptt|en. Quits after 12 s
//                               (Y700_OSK_PREVIEW_MS overrides); answers the debug hook as fyi.y700.OskPreview;
//                               Y700_OSK_HIDDEN=1 keeps the window unmapped (tests).
#include "iconprovider.h"
#include "osk.h"

#include <LayerShellQt/shell.h>

#include <QDBusConnection>
#include <QDBusMessage>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QSettings>
#include <QImage>
#include <QTimer>

int main(int argc, char *argv[])
{
    LayerShellQt::Shell::useLayerShell();
    QGuiApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("y700-osk"));
    app.setOrganizationName(QStringLiteral("y700"));
    app.setQuitOnLastWindowClosed(false);

    const QString arg1 = argc > 1 ? QString::fromLocal8Bit(argv[1]) : QString();
    const bool preview = arg1.startsWith(QLatin1String("--preview"));
    if (preview) {   // keep the real prefs untouched, and start every preview from defaults
        app.setOrganizationName(QStringLiteral("y700-preview"));
        QSettings().clear();
    }

    auto bus = QDBusConnection::sessionBus();
    if (argc > 1 && !preview) {   // control an instance that is already running
        QDBusMessage m = QDBusMessage::createMethodCall(QStringLiteral("fyi.y700.Osk"), QStringLiteral("/Osk"),
                                                        QStringLiteral("fyi.y700.Osk"), QString::fromLatin1(argv[1]).remove(QStringLiteral("--")));
        const QDBusMessage r = bus.call(m, QDBus::Block, 3000);
        return r.type() == QDBusMessage::ErrorMessage ? 1 : 0;
    }

    Osk osk;
    if (preview) { osk.setPreview(arg1.section(QLatin1Char('='), 1)); osk.claimPreviewBus(); }
    else if (!osk.claimBus()) return 2;     // another keyboard UI owns the fcitx5 name

    QQuickWindow::setDefaultAlphaBuffer(true);
    QQmlApplicationEngine engine;
    engine.addImageProvider(QStringLiteral("icon"), new IconProvider(QStringLiteral(DATA_DIR "/icons.json")));
    engine.rootContext()->setContextProperty(QStringLiteral("osk"), &osk);
    engine.load(QUrl::fromLocalFile(QStringLiteral(QML_DIR "/Main.qml")));
    auto *win = qobject_cast<QQuickWindow *>(engine.rootObjects().value(0));
    if (!win) return 3;
    osk.setWindow(win);
    if (preview) {
        // Y700_OSK_HIDDEN=1: never map the window (the state-machine tests drive the keyboard through the
        // debug hook; a mapped preview would cover the bottom of the screen and eat touches)
        if (qEnvironmentVariableIsEmpty("Y700_OSK_HIDDEN")) osk.show(true);
        // Y700_OSK_GRAB=<file.png>: save what Qt rendered (works with the display asleep, unlike a screenshot)
        const QString grab = qEnvironmentVariable("Y700_OSK_GRAB");
        if (!grab.isEmpty())
            QTimer::singleShot(qEnvironmentVariableIntValue("Y700_OSK_GRAB_MS") > 0 ? qEnvironmentVariableIntValue("Y700_OSK_GRAB_MS") : 1600, win, [win, grab] {
                win->grabWindow().save(grab);
                QCoreApplication::quit();
            });
        else QTimer::singleShot(qEnvironmentVariableIntValue("Y700_OSK_PREVIEW_MS") > 0 ? qEnvironmentVariableIntValue("Y700_OSK_PREVIEW_MS") : 12000,
                                &app, &QCoreApplication::quit);    // tests keep it up longer
    }
    return app.exec();
}
