#include "osk.h"
#include "gate.h"
#include "fcitx.h"
#include "haptics.h"
#include "sound.h"
#include "voice.h"

#include <KWindowEffects>
#include <LayerShellQt/window.h>

#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusVariant>
#include <QDebug>
#include <QPainterPath>
#include <QProcess>
#include <QQuickWindow>
#include <QRegion>
#include <QScreen>
#include <QTextBoundaryFinder>
#include <QTimer>

#include <algorithm>

namespace {
const QString CTRL_PATH = QStringLiteral("/fyi/fortime/Fcitx5Osk/Controller");
const QString CTRL_IF = QStringLiteral("fyi.fortime.Fcitx5Osk.Controller1");
const QString OWN_IF = QStringLiteral("fyi.y700.Osk");
// X11 clients (x11Decide): fcitx5 quiet this long after the last Show/Hide and the lift; a tap off a
// field blurred it 35-70 ms after the lift's Show in Steam (2026-10-30), slack for a busy page
constexpr qint64 X11_SETTLE_MS = 200;
constexpr qint64 X11_EVIDENCE_MS = 600;   // the burst began this soon after the tap's lift (Gate: EVIDENCE_MS)
constexpr qint64 X11_GIVE_UP_MS = 3000;   // a finger held this long is no tap: decide with what there is

QPainterPath roundedRect(const QRectF &r, qreal tl, qreal tr, qreal br, qreal bl)
{
    QPainterPath p;
    p.moveTo(r.left() + tl, r.top());
    p.lineTo(r.right() - tr, r.top());
    if (tr > 0) p.arcTo(QRectF(r.right() - 2 * tr, r.top(), 2 * tr, 2 * tr), 90, -90);
    p.lineTo(r.right(), r.bottom() - br);
    if (br > 0) p.arcTo(QRectF(r.right() - 2 * br, r.bottom() - 2 * br, 2 * br, 2 * br), 0, -90);
    p.lineTo(r.left() + bl, r.bottom());
    if (bl > 0) p.arcTo(QRectF(r.left(), r.bottom() - 2 * bl, 2 * bl, 2 * bl), 270, -90);
    p.lineTo(r.left(), r.top() + tl);
    if (tl > 0) p.arcTo(QRectF(r.left(), r.top(), 2 * tl, 2 * tl), 180, -90);
    p.closeSubpath();
    return p;
}
} // namespace

// ---------------- bus object for the launcher and our CLI ----------------
QString OskBusObject::introspect(const QString &path) const
{
    if (path == CTRL_PATH)
        return QStringLiteral(
            "<interface name=\"fyi.fortime.Fcitx5Osk.Controller1\">"
            "<method name=\"Show\"/><method name=\"ForceShow\"/><method name=\"Hide\"/><method name=\"ForceHide\"/>"
            "<method name=\"ChangeManualMode\"><arg type=\"b\" direction=\"in\"/></method>"
            "<method name=\"StartManualModeSession\"><arg type=\"b\" direction=\"in\"/><arg type=\"s\" direction=\"out\"/></method>"
            "<method name=\"StopManualModeSession\"><arg type=\"s\" direction=\"in\"/></method>"
            "<method name=\"ChangeVisible\"><arg type=\"b\" direction=\"in\"/></method>"
            "<method name=\"ChangeMode\"><arg type=\"u\" direction=\"in\"/></method>"
            "<method name=\"OpenSocket\"><arg type=\"(uh)\" direction=\"in\"/></method>"
            "<method name=\"OpenDisplay\"><arg type=\"(us)\" direction=\"in\"/></method>"
            "<method name=\"ReopenIfOpened\"/><method name=\"Shutdown\"/>"
            "<property name=\"ManualMode\" type=\"b\" access=\"read\"/>"
            "<property name=\"Mode\" type=\"u\" access=\"read\"/>"
            "<property name=\"Visible\" type=\"b\" access=\"read\"/>"
            "</interface>");
    return QStringLiteral(
        "<interface name=\"fyi.y700.Osk\"><method name=\"show\"/><method name=\"hide\"/><method name=\"toggle\"/>"
        "<method name=\"debug\"><arg type=\"s\" direction=\"in\"/><arg type=\"s\" direction=\"in\"/><arg type=\"s\" direction=\"out\"/></method></interface>");
}

bool OskBusObject::handleMessage(const QDBusMessage &msg, const QDBusConnection &conn)
{
    const QString iface = msg.interface(), member = msg.member();
    auto reply = [&](const QVariantList &args = {}) { conn.send(msg.createReply(args)); return true; };

    if (iface == QLatin1String("org.freedesktop.DBus.Properties")) {
        const QString prop = msg.arguments().value(1).toString();
        QVariantMap all{ { QStringLiteral("ManualMode"), false }, { QStringLiteral("Mode"), uint(0) }, { QStringLiteral("Visible"), m_osk->shown() } };
        if (member == QLatin1String("Get") && all.contains(prop)) return reply({ QVariant::fromValue(QDBusVariant(all.value(prop))) });
        if (member == QLatin1String("GetAll")) return reply({ all });
        conn.send(msg.createErrorReply(QStringLiteral("org.freedesktop.DBus.Error.UnknownProperty"), prop));
        return true;
    }
    if (iface == CTRL_IF || iface.isEmpty() || iface == OWN_IF) {
        // Show / ChangeVisible(true): the KWin launcher, on input-method activation (gated);
        // show: our CLI (y700-osk show), always
        if (member == QLatin1String("Show")) { m_osk->showRequest(false); return reply(); }
        if (member == QLatin1String("show")) { m_osk->show(false); return reply(); }
        if (member == QLatin1String("ForceShow")) { m_osk->show(true); return reply(); }
        if (member == QLatin1String("Hide") || member == QLatin1String("ForceHide") || member == QLatin1String("hide")) { m_osk->hide(true); return reply(); }
        if (member == QLatin1String("debug") && iface == OWN_IF)
            return reply({ m_osk->debug(msg.arguments().value(0).toString(), msg.arguments().value(1).toString()) });
        if (member == QLatin1String("toggle")) { m_osk->shown() ? m_osk->hideKeyboard() : m_osk->show(true); return reply(); }
        if (member == QLatin1String("ChangeVisible")) { msg.arguments().value(0).toBool() ? m_osk->showRequest(false) : m_osk->hide(true); return reply(); }
        if (member == QLatin1String("Shutdown")) { reply(); m_osk->shutdown(); return true; }
        if (member == QLatin1String("ChangeMode")) {
            reply();
            // 1 = KWin lock screen: that is the original fcitx5-osk's job (input-panel surface)
            if (msg.arguments().value(0).toUInt() != 0) m_osk->shutdown();
            return true;
        }
        if (member == QLatin1String("OpenSocket")) { reply(); m_osk->shutdown(); return true; }
        if (member == QLatin1String("StartManualModeSession")) return reply({ QStringLiteral("y700") });
        // OpenDisplay: we are already a normal client of WAYLAND_DISPLAY; manual mode is not used
        if (member == QLatin1String("OpenDisplay") || member == QLatin1String("ReopenIfOpened") || member == QLatin1String("ChangeManualMode")
            || member == QLatin1String("StopManualModeSession")) return reply();
    }
    return false;
}

// ---------------- Osk ----------------
Osk::Osk(QObject *parent) : QObject(parent)
{
    m_fcitx = new Fcitx(this);
    m_sound = new Sound(this);
    m_haptics = new Haptics(this);
    m_voice = new Voice(this);

    m_hideTimer = new QTimer(this);
    m_hideTimer->setSingleShot(true);
    m_hideTimer->setInterval(300);      // focus hops (tap another field) send Hide then Show
    connect(m_hideTimer, &QTimer::timeout, this, [this] {
        // while the gate is still judging a touch (finger down, or its evidence window open) the Hide
        // may be about to be overruled by a tap-confirmed show: wait for the verdict instead of letting
        // the keyboard slide out under a long press and back in
        if (m_gate && m_gate->alive() && m_gate->busy()) { m_hideTimer->start(120); return; }
        // the same for an X11 client, which the gate leaves out (Steam's touches carry no desktop file):
        // pressing a field of a Steam window that is not active sends the Hide at the press, its Show
        // only after the lift
        if (m_gate && m_gate->alive() && x11Pending()) { m_hideTimer->start(120); return; }
        hide(true);
    });

    m_soundIdle = new QTimer(this);
    m_soundIdle->setSingleShot(true);
    m_soundIdle->setInterval(10000);    // let the speaker path sleep when nobody types
    connect(m_soundIdle, &QTimer::timeout, this, [this] { m_sound->setActive(false); });

    m_x11Settle = new QTimer(this);
    m_x11Settle->setSingleShot(true);
    connect(m_x11Settle, &QTimer::timeout, this, &Osk::x11Decide);
    m_x11Verify = new QTimer(this);
    m_x11Verify->setSingleShot(true);
    connect(m_x11Verify, &QTimer::timeout, this, &Osk::x11Verify);

    connect(m_fcitx, &Fcitx::showRequested, this, [this] { showRequest(true); });
    connect(m_fcitx, &Fcitx::hideRequested, this, [this] {
        if (m_gate) m_fcitxHideAt = m_gate->now();
        m_fcitxLastHide = true;
        m_voice->discard();             // speech still being recognised was for the field that lost the focus
        if (!m_force) m_hideTimer->start(300);
    });
    connect(m_fcitx, &Fcitx::echoHideSwallowed, this, [this] {
        if (m_gate) m_echoHideAt = m_gate->now();
        x11Check();
    });
    connect(m_fcitx, &Fcitx::candidatesChanged, this, [this](const QStringList &c, bool p, bool n, int cursor) {
        if (c == m_candidates && p == m_hasPrev && n == m_hasNext && cursor == m_cursor) return;
        m_candidates = c; m_hasPrev = p; m_hasNext = n; m_cursor = cursor;
        emit compositionChanged();
    });
    connect(m_fcitx, &Fcitx::preeditChanged, this, [this](const QString &t) {
        if (t == m_preedit) return;
        m_preedit = t;
        emit compositionChanged();
    });
    connect(m_fcitx, &Fcitx::imChanged, this, &Osk::imChanged);
    connect(m_fcitx, &Fcitx::nameLost, this, &Osk::shutdown);

    auto bus = QDBusConnection::sessionBus();
    bus.connect(QStringLiteral("org.kde.klipper"), QStringLiteral("/klipper"), QStringLiteral("org.kde.klipper.klipper"),
                QStringLiteral("clipboardHistoryUpdated"), this, SLOT(refreshClipboard()));
    bus.connect(QStringLiteral("org.kde.KWin"), QStringLiteral("/VirtualKeyboard"), QStringLiteral("org.kde.kwin.VirtualKeyboard"),
                QStringLiteral("activeClientSupportsTextInputChanged"), this, SLOT(readTextInputSupport()));
}

Osk::~Osk() = default;

bool Osk::claimBus()
{
    auto bus = QDBusConnection::sessionBus();
    // Objects first, names last. The bus hands the launcher's queued activation messages (the zbus
    // proxy's GetAll, ChangeMode, OpenDisplay) over the moment a name is granted, and Qt looks the
    // path up on arrival: a miss is answered UnknownObject, which zbus caches for good, and the
    // launcher would then never call Show.
    m_busObject = new OskBusObject(this);
    bus.registerVirtualObject(CTRL_PATH, m_busObject, QDBusConnection::SingleNode);
    bus.registerVirtualObject(QStringLiteral("/Osk"), new OskBusObject(this), QDBusConnection::SingleNode);
    if (!m_fcitx->registerUi()) return false;          // impanel object, then org.fcitx.Fcitx5.VirtualKeyboard
    bus.registerService(QStringLiteral("fyi.y700.Osk"));
    // the launcher's name last: once it sees this owner, everything it calls exists
    if (!bus.registerService(QStringLiteral("fyi.fortime.Fcitx5Osk"))) {
        qWarning() << "osk: fyi.fortime.Fcitx5Osk is taken (another keyboard is running)";
        m_fcitx->releaseUi();
        return false;
    }
    // The keyboard comes up for taps on text fields only (Gate, fed by the y700_oskgate KWin effect)
    m_gate = new Gate(this);
    connect(m_gate, &Gate::showWanted, this, [this] { show(false); });
    connect(m_gate, &Gate::touchEnded, this, &Osk::x11TouchEnded);
    // fcitx5 into on-screen mode once the gate guards its Shows (they no longer bring the keyboard up by
    // themselves): only then does an X11 client's field reach x11Decide() before a Wayland field did
    connect(m_gate, &Gate::aliveChanged, this, [this](bool alive) { if (alive) m_fcitx->enterOnScreenMode(); });
    connect(m_fcitx, &Fcitx::restarted, this, [this] { if (m_gate->alive()) m_fcitx->enterOnScreenMode(); });
    readTextInputSupport();
    // Like fcitx5-osk we do not enter fcitx5's on-screen mode at start (that would pop the keyboard
    // up with no text field): the launcher calls Show when KWin activates a text field, then
    // show() switches fcitx5 to on-screen mode, and from then on fcitx5 sends Show/Hide on focus.
    return true;
}

// A preview never touches fcitx5's names, but it does answer the debug hook under its own name, so
// the touch state machine can be driven (down/up/tap) and read back (state) without a text field:
// osk.key()/commit() are no-ops in preview, what would have been typed lands in the typed log.
// fcitx5's panel object is served too (under the preview's name only): a test sends it the Hide fcitx5
// sends when a field loses the focus (tests/voice-drop.sh).
void Osk::claimPreviewBus()
{
    auto bus = QDBusConnection::sessionBus();
    bus.registerVirtualObject(QStringLiteral("/Osk"), new OskBusObject(this), QDBusConnection::SingleNode);
    bus.registerObject(QStringLiteral("/org/fcitx/virtualkeyboard/impanel"), m_fcitx, QDBusConnection::ExportAdaptors);
    if (!bus.registerService(QStringLiteral("fyi.y700.OskPreview"))) qWarning() << "osk: fyi.y700.OskPreview is taken (another preview is running)";
}

void Osk::setPreview(const QString &state)
{
    m_preview = true;
    m_previewState = state.isEmpty() ? QStringLiteral("keys") : state;
    if (m_previewState == QLatin1String("compose") || m_previewState == QLatin1String("cands")) {
        m_preedit = QStringLiteral("ni'hao");
        m_candidates = { QStringLiteral("你好"), QStringLiteral("你好吗"), QStringLiteral("你"), QStringLiteral("呢"), QStringLiteral("泥"),
                         QStringLiteral("尼"), QStringLiteral("逆"), QStringLiteral("拟"), QStringLiteral("腻"), QStringLiteral("妮"),
                         QStringLiteral("霓"), QStringLiteral("倪"), QStringLiteral("匿"), QStringLiteral("溺"), QStringLiteral("昵") };
    }
}

void Osk::setWindow(QQuickWindow *win)
{
    m_win = win;
    auto *ls = LayerShellQt::Window::get(win);
    ls->setLayer(LayerShellQt::Window::LayerOverlay);
    ls->setAnchors(LayerShellQt::Window::Anchors(LayerShellQt::Window::AnchorBottom | LayerShellQt::Window::AnchorLeft | LayerShellQt::Window::AnchorRight));
    ls->setKeyboardInteractivity(LayerShellQt::Window::KeyboardInteractivityNone);
    ls->setScope(QStringLiteral("y700-osk"));
    ls->setExclusiveZone(0);
    auto watch = [this](QScreen *s) {
        QObject::disconnect(m_scrConn[0]);
        QObject::disconnect(m_scrConn[1]);
        if (!s) return;
        m_scrConn[0] = connect(s, &QScreen::geometryChanged, this, [this] { applyMotorSide(); emit screenChanged(); });
        // a 180-degree flip between the two landscapes keeps the geometry, only the orientation changes
        m_scrConn[1] = connect(s, &QScreen::orientationChanged, this, [this] { applyMotorSide(); });
    };
    connect(win, &QWindow::screenChanged, this, [this, watch](QScreen *s) {
        watch(s);
        applyMotorSide();
        emit screenChanged();
    });
    watch(win->screen());
    applyMotorSide();
    emit screenChanged();
}

bool Osk::zh() const { return lang() != QLatin1String("en"); }     // a composing (CJK) layout: rime or mozc
QString Osk::lang() const
{
    if (m_preview) return m_previewState == QLatin1String("en") ? QStringLiteral("en") : m_previewState == QLatin1String("ja") ? QStringLiteral("ja") : QStringLiteral("zh");
    const QString im = m_fcitx->currentIM();
    return im == QLatin1String("keyboard-us") ? QStringLiteral("en") : im == QLatin1String("mozc") ? QStringLiteral("ja") : QStringLiteral("zh");
}
QObject *Osk::voiceObject() const { return m_voice; }
bool Osk::commitAvailable() const { return m_fcitx->commitAvailable(); }
int Osk::screenWidth() const { return m_win && m_win->screen() ? m_win->screen()->geometry().width() : 1600; }
int Osk::screenHeight() const { return m_win && m_win->screen() ? m_win->screen()->geometry().height() : 1003; }

void Osk::key(const QString &name) { if (m_preview) return; m_fcitx->key(name); }
void Osk::keyCombo(const QString &name, const QStringList &mods) { if (m_preview) return; m_fcitx->keyCombo(name, mods); }
void Osk::commit(const QString &text) { if (m_preview) return; m_fcitx->commit(text); }
void Osk::selectCandidate(int index) { if (m_preview) return; m_fcitx->selectCandidate(index); }
void Osk::setZh(bool zh) { m_fcitx->setCurrentIM(zh ? QStringLiteral("rime") : QStringLiteral("keyboard-us")); }
void Osk::setLang(const QString &l)
{
    m_fcitx->setCurrentIM(l == QLatin1String("en") ? QStringLiteral("keyboard-us") : l == QLatin1String("ja") ? QStringLiteral("mozc") : QStringLiteral("rime"));
}
void Osk::nextPage() { if (!m_preview && m_hasNext) m_fcitx->page(true); }
void Osk::prevPage() { if (!m_preview && m_hasPrev) m_fcitx->page(false); }

void Osk::click(int kind)
{
    if (!m_sound->available()) return;
    m_sound->setActive(true);
    m_sound->play(kind);
    m_soundIdle->start();
}
void Osk::haptic(const QString &side, int ms, int magnitude)
{
    const char s = side.startsWith(QLatin1Char('L')) ? 'L' : side.startsWith(QLatin1Char('R')) ? 'R' : 'B';
    m_haptics->pulse(s, ms, magnitude);
}
void Osk::setVolume(int level) { m_sound->setVolume(level); }
void Osk::setSoundStyle(int style) { m_sound->setStyle(style); }
void Osk::setMotorSwap(bool swap) { m_motorSwap = swap; applyMotorSide(); }

void Osk::applyMotorSide()
{
    // the motors are fixed in the chassis: turning the tablet to the other landscape swaps sides
    bool inverted = false;
    if (m_win && m_win->screen()) inverted = m_win->screen()->orientation() == Qt::InvertedLandscapeOrientation;
    m_haptics->setSwap(m_motorSwap != inverted);
}

void Osk::readTextInputSupport()
{
    auto m = QDBusMessage::createMethodCall(QStringLiteral("org.kde.KWin"), QStringLiteral("/VirtualKeyboard"),
                                            QStringLiteral("org.freedesktop.DBus.Properties"), QStringLiteral("Get"));
    m << QStringLiteral("org.kde.kwin.VirtualKeyboard") << QStringLiteral("activeClientSupportsTextInput");
    auto *w = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(m), this);
    connect(w, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QDBusVariant> r = *w;
        if (!r.isValid()) return;
        m_clientTextInput = r.value().variant().toBool();
        m_fcitx->setClientWithoutTextInput(!m_clientTextInput);
        if (m_clientTextInput) {
            m_x11FirstShow = -1;              // the Shows were for a text-input client: the gate's taps decide
            return;
        }
        // gated Shows that turn out to be for an X11 client (no text-input, so no tap evidence from KWin):
        // judged together once the touch and the client's focus have settled. However late the reply
        // comes; x11Decide() ends the burst before it calls show(), whose reply then finds none
        if (m_x11FirstShow >= 0 && !m_x11Settle->isActive()) x11Decide();
    });
}

void Osk::show(bool force, bool fromFcitx)
{
    m_hideTimer->stop();
    if (force) m_force = true;
    readTextInputSupport();
    if (!m_win) return;
    if (!m_win->isVisible()) m_win->show();
    // The click stream is NOT started here (owner, 2026-10-16: pops when the keyboard comes up). An
    // active stream makes the whole speaker path run: when it was suspended that is a PCM open, both
    // DSP graphs and a power-up of both aw882xx amplifiers, and 15 s later the power-down - for every
    // pop-up, also the ones nobody types into and the re-shows on focus hops. The first key press
    // starts it (click()); the idle timer and hideDone() stop it as before. Cost: the first click
    // after a silent speaker path waits for that path to come up.
    // shown by the launcher / CLI: make sure fcitx5 is in on-screen mode, so keys reach the app
    // and fcitx5 keeps telling us about focus changes
    if (!fromFcitx && !m_preview) m_fcitx->requestShow();
    // after fcitx5 (re)starts it is in physical-keyboard mode and tells us nothing about the first
    // focused field, so the remembered 中/英 is also checked when the keyboard comes up
    if (!m_preview) QTimer::singleShot(150, m_fcitx, &Fcitx::restoreIMIfNeeded);
    if (!m_shown) {
        m_shown = true;
        emit shownChanged();
    }
}

// fcitx5's ShowVirtualKeyboard (focus-in) and the launcher's Show (input method activated) both fire
// the moment a touch ACTIVATES a window - the app puts its focus back into its text field - and
// neither knows where the finger was (owner, 2026-10-14: dragging Telegram popped the keyboard up).
// With the KWin gate running they no longer bring the keyboard up; Gate decides from the tap. They
// still count for: X11 clients (no text-input, so no tap evidence from KWin: once the fresh
// activeClientSupportsTextInput reply - never a cached value - says X11, x11Decide()), activations KWin makes itself (tray
// "show virtual keyboard", KWin's own text fields), and - when the keyboard is already up - focus moving
// within the same window or without a touch (Tab, Return, script). Without the effect, or when it went
// silent, they work as before.
void Osk::showRequest(bool fromFcitx)
{
    if (fromFcitx) m_fcitxLastHide = false;
    if (m_preview || !m_gate || !m_gate->alive()) {
        show(false, fromFcitx);
        return;
    }
    // an X11 client may just have been activated: the reply decides. Not for the Shows that come with
    // an activation for KWin's own non-text focus (the task switcher cards, 2026-10-21): they are for
    // that item, whatever the text-input focus behind it is
    if (!m_gate->internalOther()) {
        // one tap gives an X11 client's field up to three Shows within ~100 ms: x11Decide() judges them
        // together, from the first (the one the tap caused) and the last. A burst never judged (no reply
        // from KWin) is not carried along
        const qint64 now = m_gate->now();
        if (m_x11FirstShow < 0 || now - m_x11LastShow > 1000 || now - m_x11FirstShow > X11_GIVE_UP_MS) m_x11FirstShow = now;
        m_x11LastShow = now;
    }
    readTextInputSupport();
    if (!fromFcitx && m_gate->kwinInitiated()) {
        m_gate->note(QStringLiteral("launcher Show for a KWin-initiated activation"));
        show(false);
        return;
    }
    if (m_shown) {
        // a focus hop: Hide then Show. Keep the keyboard when it stays in the window the keyboard came
        // up for (field -> omnibox, chat history in Telegram) or when no finger caused it; otherwise a
        // touch moved it to another window and the gate decides (the hide timer waits for it)
        if (m_gate->textWid() == m_gate->confirmedWid() || m_gate->msSinceAppTouch() > 800) m_hideTimer->stop();
        return;
    }
    m_gate->note(fromFcitx ? QStringLiteral("gated: fcitx5 Show") : QStringLiteral("gated: launcher Show"));
    // the effect reports every focus change before fcitx5 or the launcher react: silence means KWin
    // dropped it (compositor restart) - do not leave the keyboard unable to come up until we notice
    if (m_gate->silentMs() > 1000) {
        QTimer::singleShot(150, this, [this, fromFcitx] {
            if (m_shown || !m_gate->alive() || m_gate->silentMs() < 1100) return;
            // an X11 client's focus never goes through text-input: silence is normal there (Steam focusing
            // a field by itself), and taking it for a lost effect popped the keyboard. Ask KWin instead
            if (!m_clientTextInput) { m_gate->ensureLoaded(); return; }
            m_gate->lost();
            show(false, fromFcitx);
        });
    }
}

// X11 clients have no text-input, so KWin cannot tell a tap on a field from one anywhere else: fcitx5's
// focus-driven Show (the IM module's FocusIn) is all there is. Measured in Steam (CEF with the GTK fcitx5
// module, 2026-10-30, tests/gate-steam.sh):
//   - while a field has the focus, EVERY tap in the window gives FocusOut+FocusIn right after the lift
//     (fcitx5: Hide, Show), and a tap off the field then blurs it 35-70 ms later (Hide);
//   - a tap on a field: FocusIn 5-45 ms after the lift, and it keeps the focus;
//   - a drag (scrolling): nothing.
// Showing on the first Show popped the keyboard for every tap anywhere while a field had the focus,
// and the later Hide lost to it (the reply to that Show stopped the hide timer). So: wait until the touch
// behind the burst is over and fcitx5 has been quiet for X11_SETTLE_MS, then show only when its last
// word was a Show, a field really has the focus (the last Show may be the answer to our own requestShow:
// key-helper's echo), and the burst came from a tap on an app window that is still there - not a drag
// or a hold, not a panel or the dock that activated the app, not a window closed or minimized by that tap
// (closing Chrome over Steam gives Steam its search box back): those are the focus restored, not a tap
// on the field.
void Osk::x11Decide()
{
    if (m_x11FirstShow < 0 || !m_gate) return;
    const qint64 now = m_gate->now();
    const Gate::Touch t = m_gate->touchBefore(m_x11FirstShow);
    const int managed = m_gate->managed(t.wid);
    const bool waiting = now - m_x11FirstShow < X11_GIVE_UP_MS;
    if (waiting && (t.down() || (t.downAt >= 0 && managed < 0))) { m_x11Settle->start(60); return; }
    const qint64 settle = std::max({ m_x11LastShow, m_fcitxHideAt, t.upAt }) + X11_SETTLE_MS - now;
    if (waiting && settle > 0) { m_x11Settle->start(int(settle)); return; }
    const qint64 first = m_x11FirstShow;
    m_x11FirstShow = -1;
    if (m_fcitxLastHide) {
        m_gate->note(QStringLiteral("X11 client: the field lost the focus again (a tap off it): no show"));
        return;
    }
    if (t.downAt < 0 || !t.tap || first > t.upAt + X11_EVIDENCE_MS) {
        m_gate->note(QStringLiteral("X11 client: no tap behind the Show (%1): no show")
                         .arg(t.downAt < 0 ? QStringLiteral("no touch") : t.down() ? QStringLiteral("still held")
                              : !t.tap ? QStringLiteral("a drag, hold or gesture") : QStringLiteral("tap %1 ms earlier").arg(first - t.upAt)));
        return;
    }
    if (managed == 0) {
        m_gate->note(QStringLiteral("X11 client: the tap was on %1, not an app window (an activation): no show").arg(t.win));
        return;
    }
    if (m_fcitx->commitAvailable() && !m_fcitx->inputFocused()) {
        m_gate->note(QStringLiteral("X11 client: tap on %1, but no field has the focus: no show").arg(t.win));
        return;
    }
    m_gate->stillThere(t.wid, this, [this, t](bool there) {
        if (m_x11FirstShow >= 0 || m_fcitxLastHide) return;     // fcitx5 spoke again: that burst decides
        if (!there) {
            m_gate->note(QStringLiteral("X11 client: the tap was on %1, closed or minimized since (an activation): no show").arg(t.win));
            return;
        }
        m_gate->note(QStringLiteral("X11 client: tap on %1, the field kept the focus: show").arg(t.win));
        show(false, true);
    });
}

// Up over an X11 client, the field can lose the focus without a Hide reaching us: Return in Steam's
// search box loads the results page within key-helper's echo window (Fcitx::inHelperEcho), so its Hide
// is taken for the echo; so is the Hide of a tap off the field right after BackSpace. Checked after each
// such swallowed Hide and after each tap in an app window that fcitx5 says nothing about (a tap in
// Steam's results page): x11Verify().
void Osk::x11TouchEnded()
{
    const Gate::Touch t = m_gate->lastTouch();
    if (t.tap && m_gate->managed(t.wid) != 0) x11Check();      // not this keyboard, a panel, the dock
}

void Osk::x11Check()
{
    if (m_shown && !m_force && !m_clientTextInput && m_gate && m_fcitx->commitAvailable()) m_x11Verify->start(int(X11_SETTLE_MS));
}

// Once no finger is down and fcitx5 has been quiet for X11_SETTLE_MS (a Steam tap's FocusOut+FocusIn is
// never caught half-way), ask fcitx5 whether a field has the focus; none: put the keyboard away like a
// Hide would. Never while typing into a field: it keeps the focus. A forced keyboard (tray, CLI) stays.
void Osk::x11Verify()
{
    if (!m_shown || m_force || m_clientTextInput || !m_gate) return;
    const qint64 now = m_gate->now();
    const Gate::Touch t = m_gate->lastTouch();
    if (t.down() && now - t.downAt < X11_GIVE_UP_MS) { m_x11Verify->start(60); return; }
    const qint64 settle = std::max({ m_x11LastShow, m_fcitxHideAt, m_echoHideAt, t.upAt }) + X11_SETTLE_MS - now;
    if (settle > 0) { m_x11Verify->start(int(settle)); return; }
    if (m_fcitxLastHide || m_fcitx->inputFocused()) return;    // a real Hide last: the hide timer has it
    m_gate->note(QStringLiteral("X11 client: no field has the focus (after %1): hide")
                     .arg(m_echoHideAt > t.upAt ? QStringLiteral("a Hide taken for key-helper's echo") : QStringLiteral("a tap on ") + t.win));
    hide(true);
}

bool Osk::x11Pending() const
{
    const qint64 now = m_gate->now();
    if (m_x11Settle->isActive() || (m_x11FirstShow >= 0 && now - m_x11FirstShow < X11_GIVE_UP_MS)) return true;
    const Gate::Touch t = m_gate->lastTouch();
    return t.down() && t.win.endsWith(QLatin1Char('|')) && m_gate->managed(t.wid) == 1 && now - t.downAt < X11_GIVE_UP_MS;
}

void Osk::hide(bool immediate)
{
    Q_UNUSED(immediate)
    m_hideTimer->stop();
    m_force = false;
    if (!m_shown) return;
    m_shown = false;
    m_voice->discard();         // before cancel(), which would toast "recognising" for what is still in flight
    m_voice->cancel();
    emit shownChanged();        // QML slides out, then calls hideDone()
}

void Osk::hideKeyboard()
{
    if (!m_preview) {
        // the mockup's hideKb() drops the composition: invisible pinyin must not come back on the next show
        if (!m_preedit.isEmpty() || !m_candidates.isEmpty()) m_fcitx->clearComposition();
        m_fcitx->requestHide();
    }
    hide(true);
}

void Osk::clearAll() { if (!m_preview) m_fcitx->clearAll(); }
void Osk::rawHelper(const QString &seq) { if (!m_preview) m_fcitx->rawHelper(seq); }
void Osk::rawVk(int sym, int code, int state, bool release) { if (!m_preview) m_fcitx->rawKey(quint32(sym), quint32(code), quint32(state), release); }

void Osk::hideDone()
{
    if (m_shown || !m_win) return;
    m_win->hide();
    m_sound->setActive(false);
    m_soundIdle->stop();
}

void Osk::shutdown()
{
    static bool done = false;
    if (done) return;
    done = true;
    m_voice->cancel();
    m_fcitx->releaseUi();
    auto bus = QDBusConnection::sessionBus();
    bus.unregisterService(QStringLiteral("fyi.fortime.Fcitx5Osk"));
    bus.unregisterService(QStringLiteral("fyi.y700.Osk"));
    QTimer::singleShot(0, qApp, &QCoreApplication::quit);
}

void Osk::setPlacement(bool floating, int x, int y, int w, int h, int exclusive)
{
    if (!m_win) return;
    auto *ls = LayerShellQt::Window::get(m_win);
    if (floating) {
        ls->setAnchors(LayerShellQt::Window::Anchors(LayerShellQt::Window::AnchorBottom | LayerShellQt::Window::AnchorLeft));
        ls->setMargins(QMargins(x, 0, 0, std::max(0, screenHeight() - y - h)));
        ls->setExclusiveZone(0);
    } else {
        ls->setAnchors(LayerShellQt::Window::Anchors(LayerShellQt::Window::AnchorBottom | LayerShellQt::Window::AnchorLeft | LayerShellQt::Window::AnchorRight));
        ls->setMargins(QMargins());
        ls->setExclusiveZone(exclusive);
    }
    // after an anchor change the compositor only learns the new size from set_size: say it explicitly
    ls->setDesiredSize(QSize(w, h));
    if (m_win->width() != w || m_win->height() != h) m_win->resize(w, h);
    m_win->requestUpdate();
}

void Osk::setRegions(const QVariantList &rects, bool blur)
{
    if (!m_win) return;
    QRegion region;      // a union: overlapping pieces (split glass) must not cancel out like even-odd fill
    QString key = blur ? QStringLiteral("b") : QStringLiteral("n");
    for (const QVariant &v : rects) {
        const QVariantMap r = v.toMap();
        const QRectF rc(r.value(QStringLiteral("x")).toReal(), r.value(QStringLiteral("y")).toReal(),
                        r.value(QStringLiteral("w")).toReal(), r.value(QStringLiteral("h")).toReal());
        region += QRegion(roundedRect(rc, r.value(QStringLiteral("tl")).toReal(), r.value(QStringLiteral("tr")).toReal(),
                                      r.value(QStringLiteral("br")).toReal(), r.value(QStringLiteral("bl")).toReal())
                              .toFillPolygon().toPolygon());
        key += QStringLiteral("|%1,%2,%3,%4").arg(rc.x()).arg(rc.y()).arg(rc.width()).arg(rc.height());
    }
    if (key == m_lastRegionKey) return;
    m_lastRegionKey = key;
    KWindowEffects::enableBlurBehind(m_win, blur, region);
    // touches outside the keyboard (the gap of the split keyboard, the floating keyboard's
    // shadow margin) go to the app underneath
    m_win->setMask(region);
}

void Osk::refreshClipboard()
{
    auto m = QDBusMessage::createMethodCall(QStringLiteral("org.kde.klipper"), QStringLiteral("/klipper"),
                                            QStringLiteral("org.kde.klipper.klipper"), QStringLiteral("getClipboardHistoryMenu"));
    auto *w = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(m), this);
    connect(w, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusPendingReply<QStringList> r = *w;
        if (!r.isValid()) return;
        QStringList list = r.value();
        list.removeAll(QString());
        if (list.size() > 200) list = list.mid(0, 200);
        if (list != m_clipboard) { m_clipboard = list; emit clipboardChanged(); }
    });
}

void Osk::clearClipboard()
{
    auto m = QDBusMessage::createMethodCall(QStringLiteral("org.kde.klipper"), QStringLiteral("/klipper"),
                                            QStringLiteral("org.kde.klipper.klipper"), QStringLiteral("clearClipboardHistory"));
    QDBusConnection::sessionBus().asyncCall(m);
    m_clipboard.clear();
    emit clipboardChanged();
}

QStringList Osk::graphemes(const QString &s) const
{
    QStringList out;
    QTextBoundaryFinder f(QTextBoundaryFinder::Grapheme, s);
    int prev = 0;
    for (int pos = f.toNextBoundary(); pos != -1; pos = f.toNextBoundary()) {
        out << s.mid(prev, pos - prev);
        prev = pos;
    }
    return out;
}

QString Osk::debug(const QString &cmd, const QString &arg)
{
    if (cmd == QLatin1String("gate"))       // the gate's decision log (tests/gate-matrix.sh)
        return QStringLiteral("alive=%1 clientTextInput=%2 shown=%3").arg(m_gate && m_gate->alive()).arg(m_clientTextInput).arg(m_shown)
            + QLatin1Char('\n') + (m_gate ? m_gate->log() : QStringLiteral("(no gate: preview)"));
    m_debugState = QStringLiteral("ok");
    emit debugCommand(cmd, arg);        // DebugHook.qml handles it synchronously
    return m_debugState;
}

void Osk::openSettings()
{
    // child processes must not inherit our layer-shell integration (the control centre's lesson)
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.remove(QStringLiteral("QT_WAYLAND_SHELL_INTEGRATION"));
    env.remove(QStringLiteral("QT_QPA_PLATFORM"));
    QProcess p;
    p.setProcessEnvironment(env);
    p.setProgram(QStringLiteral("systemsettings"));
    p.setArguments({ QStringLiteral("kcm_fcitx5") });
    p.startDetached();
    hideKeyboard();
}
