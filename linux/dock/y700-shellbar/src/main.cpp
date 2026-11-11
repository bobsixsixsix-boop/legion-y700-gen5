// y700-shellbar: the always-there part of the vivo-style shell (10-22, a dock in the style of vivo's OriginOS pad UI,
// mode B+): a status bar along the top, an 8 px pull-down strip over it for fullscreen apps, the dock at the bottom
// (shown on the desktop; in an app it comes up on a short slow swipe from the bottom edge, D-Bus reveal()) and the
// full-screen app grid behind the dock's first button. Pull-downs go to the control centre (left half =
// notifications, right half = controls).
//
// Its own process, not windows of y700-control-center: KWin turns the bottom and side edges off while any window
// whose resourceClass is "y700-control-center" is mapped (linux/gesture kwin-script BLOCKERS), and these windows
// are mapped all the time.
//
// Since phase 2 (10-22) it is also the session's notification server: qml/Banners.qml holds libnotificationmanager's
// Notifications model, whose first instance registers org.freedesktop.Notifications, and shows the banners.
//
// The windows are declared in QML (qml/Main.qml); here they only get their layer-shell roles before they are
// first shown (LayerShellQt reads them when the surface is created), then QML decides what is mapped.
#include "apps.h"
#include "hud.h"
#include "shell.h"
#include "status.h"
#include <LayerShellQt/Shell>
#include <LayerShellQt/Window>
#include <QDBusConnection>
#include <QElapsedTimer>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QTouchEvent>
#include <cstdio>

using LS = LayerShellQt::Window;

// A pull that starts on the status bar or the strip: the finger goes down, moves down 6 px, and from then on every
// move is the sheet's. A Wayland touch stays with the surface it went down on however far it moves, so the whole
// pull arrives here. Left half of the screen = notification centre, right half = control centre.
class Puller : public QObject
{
public:
    Puller(Shell *shell, QWindow *win) : QObject(win), m_shell(shell), m_win(win) { win->installEventFilter(this); }

protected:
    bool eventFilter(QObject *, QEvent *e) override
    {
        switch (e->type()) {
        case QEvent::TouchBegin: case QEvent::TouchUpdate: case QEvent::TouchEnd: case QEvent::TouchCancel:
            touch(static_cast<QTouchEvent *>(e));
            e->accept();
            return true;
        case QEvent::MouseButtonPress: case QEvent::MouseMove: case QEvent::MouseButtonRelease:
            return true;   // the synthesized mouse of the same touch; the bars have nothing to click
        default:
            return false;
        }
    }

private:
    void touch(QTouchEvent *e)
    {
        if (e->points().isEmpty()) return;
        const QEventPoint &pt = e->points().first();
        const double y = pt.position().y();   // both windows sit at the top: window y = screen y
        if (e->type() == QEvent::TouchBegin) {
            m_y0 = y; m_down = true; m_pulling = false; m_vy = 0;
            m_side = pt.position().x() < m_win->width() / 2 ? "left" : "right";
            m_clock.start(); m_lastY = y; m_lastT = 0;
            return;
        }
        if (!m_down) return;
        if (e->type() == QEvent::TouchCancel) {
            if (m_pulling) m_shell->pullEnd(-1000.0);
            m_down = m_pulling = false;
            return;
        }
        // velocity: exponential average over the moves, px/s; a finger that stopped before lifting has none left
        const qint64 t = m_clock.elapsed();
        if (e->type() == QEvent::TouchEnd && t - m_lastT > 80) m_vy = 0;
        else if (t > m_lastT) {
            const double v = (y - m_lastY) * 1000.0 / double(t - m_lastT);
            m_vy = m_lastT == 0 ? v : 0.6 * v + 0.4 * m_vy;
            m_lastY = y; m_lastT = t;
        }
        if (!m_pulling && y - m_y0 > 6) {
            m_pulling = true;
            m_shell->pullBegin(m_side);
        }
        if (m_pulling) m_shell->pullMove(y);
        if (e->type() == QEvent::TouchEnd) {
            if (m_pulling) {
                m_shell->pullEnd(m_vy);
                fprintf(stderr, "pull %s: from %.0f to %.0f, %.0f px/s at the end\n", qPrintable(m_side), m_y0, y, m_vy);
            }
            m_down = m_pulling = false;
        }
    }

    Shell *m_shell;
    QWindow *m_win;
    QString m_side;
    bool m_down = false, m_pulling = false;
    double m_y0 = 0, m_vy = 0, m_lastY = 0;
    qint64 m_lastT = 0;
    QElapsedTimer m_clock;
};

static QQuickWindow *win(QObject *root, const char *name)
{
    auto *w = qvariant_cast<QQuickWindow *>(root->property(name));
    if (!w) fprintf(stderr, "Main.qml: no window %s\n", name);
    return w;
}

static void layer(QWindow *w, LS::Layer l, LS::Anchors a, int exclusive, const char *scope,
                  LS::KeyboardInteractivity kb = LS::KeyboardInteractivityNone)
{
    auto *ls = LS::get(w);
    ls->setLayer(l);
    ls->setAnchors(a);
    ls->setExclusiveZone(exclusive);
    ls->setKeyboardInteractivity(kb);
    ls->setScope(QString::fromLatin1(scope));
}

int main(int argc, char **argv)
{
    LayerShellQt::Shell::useLayerShell();
    QGuiApplication app(argc, argv);
    app.setApplicationName("y700-shellbar");
    app.setDesktopFileName("y700-shellbar");   // KWin matches the .desktop for org_kde_plasma_window_management
    app.setQuitOnLastWindowClosed(false);
    // libnotificationmanager reads this when it registers org.freedesktop.Notifications (Banners.qml's model): as
    // plasmashell does (plasma-workspace shell/main.cpp), take the name over from whoever holds it and let nobody
    // take it back - the one notification server of the session
    app.setProperty("_plasma_dbus_master", true);

    Shell shell;
    QDBusConnection bus = QDBusConnection::sessionBus();
    if (!bus.registerService("fyi.y700.Shellbar")) {
        fprintf(stderr, "y700-shellbar is already running\n");
        return 0;
    }
    bus.registerObject("/Shellbar", &shell, QDBusConnection::ExportScriptableSlots);

    Status status;
    Apps apps;
    shell.setApps(&apps);   // before any D-Bus call is served: the event loop starts below
    Hud hud;
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("shell", &shell);
    engine.rootContext()->setContextProperty("sysStatus", &status);
    engine.rootContext()->setContextProperty("hud", &hud);
    engine.rootContext()->setContextProperty("apps", &apps);
    engine.load(QUrl::fromLocalFile(QStringLiteral(QML_DIR "/Main.qml")));
    if (engine.rootObjects().isEmpty()) { fprintf(stderr, "QML failed to load\n"); return 1; }
    QObject *root = engine.rootObjects().first();

    QQuickWindow *bar = win(root, "statusWin"), *strip = win(root, "stripWin"), *dock = win(root, "dockWin"),
                 *grid = win(root, "gridWin"), *banners = win(root, "bannerWin"), *hudw = win(root, "hudWin"),
                 *back = win(root, "backWin");
    if (!bar || !strip || !dock || !grid || !banners || !hudw || !back) return 1;
    // Scope "dock" (KWin: window type Dock, as Plasma's own panel) for what maps and unmaps often: KWin's scale
    // effect animates every window of the plain type as it maps (0.8 -> 1 with a fade; the blur effect skips a
    // transformed window, so the frosted body came in sharp and blurred only at the end, 10-22) and leaves docks
    // alone. Layer-shell stacking goes by the layer, not the type, so nothing else changes.
    // status bar: above windows, takes 28 px off the top of the work area (maximized windows start under it)
    layer(bar, LS::LayerTop, {LS::AnchorTop | LS::AnchorLeft | LS::AnchorRight}, bar->height(), "dock");
    // pull strip: overlay, so it is there over fullscreen apps too (KWin raises an active fullscreen window over Top)
    layer(strip, LS::LayerOverlay, {LS::AnchorTop | LS::AnchorLeft | LS::AnchorRight}, -1, "dock");
    // dock: a band along the bottom; the input mask (Dock.qml) keeps taps outside the dock itself for the desktop
    layer(dock, LS::LayerTop, {LS::AnchorBottom | LS::AnchorLeft | LS::AnchorRight}, -1, "dock");
    // banners: a 680 px band hung from the top edge (KWin centres it), overlay so they show over fullscreen apps;
    // only the cards take touches and blur (Banners.qml)
    layer(banners, LS::LayerOverlay, {LS::AnchorTop}, -1, "dock");
    // app grid: whole screen over the status bar; takes the keyboard while open (Esc / the back key close it).
    // Also "dock": a Dock-type layer surface still gets the keyboard when it asks (KWin 6.6.6 LayerShellV1Window
    // activates on acceptsFocus, whatever the type), and its open is no longer the scale effect's to animate
    layer(grid, LS::LayerTop, {LS::AnchorTop | LS::AnchorBottom | LS::AnchorLeft | LS::AnchorRight}, -1, "dock",
          LS::KeyboardInteractivityOnDemand);
    // performance widget: Bottom layer = above the wallpaper and the desktop icons, under every window; its edge
    // under the clock's (x 22), 18 px under the bar (as the dock sits 18 px over the bottom edge). -1: placed from
    // the screen's edge, not below the bar's exclusive zone, so the bar moving layers never shifts it
    layer(hudw, LS::LayerBottom, {LS::AnchorTop | LS::AnchorLeft}, -1, "dock");
    LS::get(hudw)->setMargins(QMargins(22, 28 + 18, 0, 0));
    // the stage manager's backdrop: the whole screen, Bottom layer too; it maps after the widget, so it is above it
    // (the widget only shows on the desktop, where the backdrop is away anyway)
    layer(back, LS::LayerBottom, {LS::AnchorTop | LS::AnchorBottom | LS::AnchorLeft | LS::AnchorRight}, -1, "dock");
    new Puller(&shell, bar);
    new Puller(&shell, strip);

    root->setProperty("ready", true);   // from here QML maps the windows
    return app.exec();
}
