#include "shell.h"
#include "wlblur.h"
#include <LayerShellQt/Window>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusServiceWatcher>
#include <QPainterPath>
#include <QVariantMap>
#include <QWindow>

static const char *CC = "fyi.y700.ControlCenter", *CC_PATH = "/ControlCenter";

Shell::Shell(QObject *parent) : QObject(parent)
{
    QDBusConnection::sessionBus().connect(CC, CC_PATH, CC, "openChanged", this, SLOT(onCcOpen(bool)));
    // openChanged(false) only comes from the control centre's hide(): one that dies with the curtain open (a crash
    // and its Restart=on-failure, its install.sh's restart) never sends it, and the new one starts closed without a
    // word - ccOpen stayed true: no banners, no clock, no pull strip over a fullscreen app (10-31 审计 D2). Its name
    // changing hands = the curtain gone. A match rule on the bus, no wakeups but that
    auto *w = new QDBusServiceWatcher(CC, QDBusConnection::sessionBus(), QDBusServiceWatcher::WatchForOwnerChange, this);
    connect(w, &QDBusServiceWatcher::serviceOwnerChanged, this, [this] { onCcOpen(false); });
}

void Shell::onCcOpen(bool open)
{
    if (open == m_ccOpen) return;
    m_ccOpen = open;
    Q_EMIT ccOpenChanged();
}

void Shell::ccCall(const char *method, const QVariantList &args)
{
    QDBusMessage m = QDBusMessage::createMethodCall(CC, CC_PATH, CC, method);
    m.setArguments(args);
    QDBusConnection::sessionBus().send(m);   // no reply wanted: a move must not wait for the sheet
}

void Shell::pullBegin(const QString &side)
{
    // "left" = the notification centre, "right" = the controls (the control centre's curtain, 2026-10-22)
    ccCall("pullBeginSide", {side});
}

void Shell::pullMove(double y) { ccCall("pullMove", {y}); }
void Shell::pullEnd(double vy) { ccCall("pullEnd", {vy}); }

static QRegion rounded(const QRect &r, int radius)
{
    if (radius <= 0) return QRegion(r);
    QPainterPath p;
    p.addRoundedRect(QRectF(r), radius, radius);
    return QRegion(p.toFillPolygon().toPolygon());
}

// [{x, y, w, h}, ...] from QML; an empty or degenerate rectangle is skipped
static QRegion rectsRegion(const QVariantList &rects, int radius)
{
    QRegion region;
    for (const QVariant &v : rects) {
        const QVariantMap m = v.toMap();
        const QRect r(m.value("x").toInt(), m.value("y").toInt(), m.value("w").toInt(), m.value("h").toInt());
        if (r.width() > 0 && r.height() > 0) region += rounded(r, radius);
    }
    return region;
}

WlBlurWindow *Shell::blurOf(QWindow *win)
{
    auto it = m_blur.find(win);
    if (it != m_blur.end()) return *it;
    auto *b = new WlBlurWindow(win);
    m_blur.insert(win, b);
    connect(win, &QObject::destroyed, this, [this, win] { m_blur.remove(win); });
    return b;
}

void Shell::setBlur(QWindow *win, int x, int y, int w, int h, int radius)
{
    if (!win) return;
    blurOf(win)->setRegion(w > 0 && h > 0 ? rounded(QRect(x, y, w, h), radius) : QRegion());
}

void Shell::setBlurRects(QWindow *win, const QVariantList &rects, int radius)
{
    if (!win) return;
    blurOf(win)->setRegion(rectsRegion(rects, radius));
}

void Shell::setOverlay(QWindow *win, bool overlay)
{
    if (!win) return;
    // LayerShellQt applies a layer change to a mapped surface (zwlr_layer_surface_v1.set_layer, protocol v2)
    LayerShellQt::Window::get(win)->setLayer(overlay ? LayerShellQt::Window::LayerOverlay : LayerShellQt::Window::LayerTop);
}

void Shell::setInput(QWindow *win, int x, int y, int w, int h)
{
    if (!win) return;
    win->setMask(w > 0 && h > 0 ? QRegion(x, y, w, h) : QRegion());
}

void Shell::setInputRects(QWindow *win, const QVariantList &rects)
{
    if (!win) return;
    const QRegion region = rectsRegion(rects, 0);
    // an empty mask means no mask to Qt (wl_surface.set_input_region null: the whole surface); a pixel outside the
    // surface is clipped away by the compositor, so nothing takes touches
    win->setMask(region.isEmpty() ? QRegion(-1, -1, 1, 1) : region);
}
