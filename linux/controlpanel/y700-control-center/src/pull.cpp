// y700-cc-pull: the pull-down strip of the control centre (owner 10-21: 「panel 改成从右上往下滑呼出」; since
// 10-22 the whole top edge: 「左边下拉出通知中心，右边下拉出控制中心」). A transparent layer-shell surface, 8 logical
// px high like KWin's own touch edges, across the screen. A finger that goes down on it and moves down drives
// the curtain over D-Bus (fyi.y700.ControlCenter pullBeginSide(left|right, by where it went down) / pullMove(y) /
// pullEnd(vy)): a Wayland
// touch stays with the surface it went down on however far it moves, so the whole pull arrives here.
//
// Why its own process and not a second window of y700-control-center: KWin names a Wayland client's
// windows after its executable (resourceClass), and the bottom edge (linux/gesture kwin-script,
// y700-taskswitcher) and the side edges switch themselves off while a "y700-control-center" window is
// mapped. An always-mapped strip of that name would have switched them off for good.
//
// No QML (a QRasterWindow that paints nothing visible), no wakeups while untouched. Not small though: 39 MB
// private (10-21; Qt Wayland still brings in EGL/Mesa); a plain wayland-client program would be a few MB.
// Unmapped while the sheet is open (it would eat taps along the sheet's top edge), never in mid-pull.
#include <LayerShellQt/Window>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QElapsedTimer>
#include <QGuiApplication>
#include <QPainter>
#include <QRasterWindow>
#include <QScreen>
#include <QTouchEvent>
#include <cstdio>

static const char *SVC = "fyi.y700.ControlCenter", *PATH = "/ControlCenter", *IFACE = "fyi.y700.ControlCenter";

class Strip : public QRasterWindow
{
    Q_OBJECT
public:
    Strip()
    {
        setFlags(Qt::FramelessWindowHint);
        QSurfaceFormat f = format();
        f.setAlphaBufferSize(8);
        setFormat(f);
        auto *ls = LayerShellQt::Window::get(this);
        ls->setLayer(LayerShellQt::Window::LayerOverlay);
        ls->setAnchors({LayerShellQt::Window::AnchorTop | LayerShellQt::Window::AnchorRight});
        ls->setExclusiveZone(-1);
        ls->setKeyboardInteractivity(LayerShellQt::Window::KeyboardInteractivityNone);
        ls->setScope(QStringLiteral("y700-cc-pull"));
        fit();
        // the sheet says when it opens/closes; started before it, assume closed
        QDBusConnection::sessionBus().connect(SVC, PATH, IFACE, "openChanged", this, SLOT(onOpen(bool)));
    }

    void fit()
    {
        const QSize s = screen() ? screen()->size() : QSize(1600, 1002);
        resize(qMax(1, s.width()), 8);   // the whole top edge (10-22), 8 = KWin TouchTarget
    }

public Q_SLOTS:
    void onOpen(bool open)
    {
        m_open = open;
        if (!m_pulling) setVisible(!open);
    }

protected:
    void paintEvent(QPaintEvent *) override
    {
        QPainter p(this);
        p.setCompositionMode(QPainter::CompositionMode_Source);
        p.fillRect(QRect(QPoint(0, 0), size()), Qt::transparent);
    }

    bool event(QEvent *e) override
    {
        switch (e->type()) {
        case QEvent::TouchBegin: case QEvent::TouchUpdate: case QEvent::TouchEnd: case QEvent::TouchCancel:
            touch(static_cast<QTouchEvent *>(e));
            return true;
        case QEvent::MouseButtonPress: case QEvent::MouseMove: case QEvent::MouseButtonRelease:
            return true;   // the synthesized mouse of the same touch
        default:
            return QRasterWindow::event(e);
        }
    }

private:
    void call(const char *method, const QVariantList &args = {})
    {
        QDBusMessage m = QDBusMessage::createMethodCall(SVC, PATH, IFACE, method);
        m.setArguments(args);
        QDBusConnection::sessionBus().send(m);   // no reply wanted: a move must not wait for the sheet
    }

    void touch(QTouchEvent *e)
    {
        if (e->points().isEmpty()) return;
        const QEventPoint &pt = e->points().first();
        const double y = pt.position().y();   // the strip sits at the top: window y = screen y
        if (e->type() == QEvent::TouchBegin) {
            m_y0 = y; m_x0 = pt.position().x(); m_down = true; m_pulling = false; m_vy = 0;
            m_clock.start(); m_lastY = y; m_lastT = 0;
            return;
        }
        if (!m_down) return;
        if (e->type() == QEvent::TouchCancel) {
            if (m_pulling) call("pullEnd", {-1000.0});
            finish();
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
            call("pullBeginSide", {QString::fromLatin1(m_x0 < width() / 2.0 ? "left" : "right")});
        }
        if (m_pulling) call("pullMove", {y});
        if (e->type() == QEvent::TouchEnd) {
            if (m_pulling) {
                call("pullEnd", {m_vy});
                fprintf(stderr, "pull: from %.0f to %.0f, %.0f px/s at the end\n", m_y0, y, m_vy);
            }
            finish();
        }
    }

    void finish()
    {
        m_down = false; m_pulling = false;
        if (m_open) setVisible(false);
    }

    bool m_open = false, m_down = false, m_pulling = false;
    double m_x0 = 0, m_y0 = 0, m_vy = 0, m_lastY = 0;
    qint64 m_lastT = 0;
    QElapsedTimer m_clock;
};

int main(int argc, char **argv)
{
    QGuiApplication app(argc, argv);
    app.setApplicationName("y700-cc-pull");
    app.setQuitOnLastWindowClosed(false);
    Strip s;
    QObject::connect(&app, &QGuiApplication::primaryScreenChanged, &s, [&s] { s.fit(); });
    if (QScreen *sc = s.screen()) QObject::connect(sc, &QScreen::geometryChanged, &s, [&s] { s.fit(); });   // rotation
    s.show();
    return app.exec();
}

#include "pull.moc"
