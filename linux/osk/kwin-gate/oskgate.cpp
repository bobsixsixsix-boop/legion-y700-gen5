/*
    y700-oskgate: see oskgate.h. Watches only; y700-osk owns the policy.
    Reviewed 2026-10-14 (3 lenses, against KWin v6.6.6 sources): no crash path found; fixed from the
    review: touch cancels, finger count from KWin's own count, no events while locked, pen taps,
    v3 semantics (commit vs enable, focus-change re-enables), unique window ids.
*/
#include "oskgate.h"

#include "input.h"
#include "input_event.h"
#include "inputmethod.h"
#include "main.h"
#include "touch_input.h"
#include "wayland/seat.h"
#include "wayland/surface.h"
#include "wayland/textinput_v1.h"
#include "wayland/textinput_v2.h"
#include "wayland/textinput_v3.h"
#include "wayland_server.h"
#include "window.h"

#include <QDBusConnection>
#include <QDBusMessage>
#include <QGuiApplication>
#include <QInputMethod>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLineF>
#include <QRectF>
#include <QUuid>

#include <cmath>

namespace KWin
{

static const QString s_path = QStringLiteral("/org/y700/OskGate");
static const QString s_iface = QStringLiteral("org.y700.OskGate");

// CLOCK_MONOTONIC in microseconds (libinput stamps touch events with the same clock; note a touch's t
// is the kernel event time, a text event's t is when KWin handled it)
static qint64 nowUs()
{
    return std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

OskGateSpy::OskGateSpy(OskGateEffect *gate)
    : m_gate(gate)
{
}

OskGateSpy::Touch OskGateSpy::begin(const QPointF &pos, std::chrono::microseconds time, int fingers)
{
    Touch t;
    t.down = pos;
    t.t0 = time;
    t.fingers = fingers;
    if (Window *w = input()->findToplevel(pos)) {
        t.window = OskGateEffect::windowId(w);
        t.wid = OskGateEffect::windowUid(w);
        // the server-side title bar / borders; client-side title bars (Chrome, Telegram) are client area
        t.frame = w->isDecorated() && !w->clientGeometry().contains(pos);
    }
    return t;
}

void OskGateSpy::report(const QString &type, qint32 id, const Touch &t, const QPointF *upPos, std::chrono::microseconds time, const QString &tool)
{
    QJsonObject ev{
        {QStringLiteral("type"), type},
        {QStringLiteral("id"), id},
        {QStringLiteral("tool"), tool},
        {QStringLiteral("x0"), t.down.x()},
        {QStringLiteral("y0"), t.down.y()},
        {QStringLiteral("t0"), qint64(t.t0.count())},
        {QStringLiteral("win"), t.window},
        {QStringLiteral("wid"), t.wid},
        {QStringLiteral("frame"), t.frame},
        {QStringLiteral("fingers"), t.fingers},
    };
    if (type == QLatin1String("up")) {
        ev.insert(QStringLiteral("t"), qint64(time.count()));
        ev.insert(QStringLiteral("durMs"), double((time - t.t0).count()) / 1000.0);
        double travel = t.maxDist;
        if (upPos) {
            travel = std::max(travel, QLineF(t.down, *upPos).length());
        }
        ev.insert(QStringLiteral("max"), std::round(travel * 10) / 10);
    }
    m_gate->emitEvent(ev);
}

void OskGateSpy::touchDown(TouchDownEvent *event)
{
    if (OskGateEffect::locked()) {
        m_touches.clear();
        return;
    }
    // KWin's own count already includes this finger (processDown inserts it before the spies run).
    // When it is the only one, anything left in m_touches is from a cancelled sequence: drop it.
    const int fingers = input()->touch() ? input()->touch()->touchPointCount() : int(m_touches.size()) + 1;
    if (fingers <= 1) {
        m_touches.clear();
    }
    const Touch t = begin(event->pos, event->time, std::max(fingers, 1));
    m_touches.insert(event->id, t);
    report(QStringLiteral("down"), event->id, t, nullptr, event->time, QStringLiteral("touch"));
}

void OskGateSpy::touchMotion(TouchMotionEvent *event)
{
    auto it = m_touches.find(event->id);
    if (it == m_touches.end()) {
        return;
    }
    it->maxDist = std::max(it->maxDist, QLineF(it->down, event->pos).length());
}

void OskGateSpy::touchUp(TouchUpEvent *event)
{
    auto it = m_touches.find(event->id);
    if (it == m_touches.end()) {
        return; // went down before the effect was loaded, or while locked
    }
    const Touch t = *it;
    m_touches.erase(it);
    if (OskGateEffect::locked()) {
        return;
    }
    report(QStringLiteral("up"), event->id, t, nullptr, event->time, QStringLiteral("touch"));
}

void OskGateSpy::tabletToolTipEvent(TabletToolTipEvent *event)
{
    if (OskGateEffect::locked()) {
        m_penDown = false;
        return;
    }
    if (event->type == TabletToolTipEvent::Press) {
        m_pen = begin(event->position, event->timestamp, 1);
        m_penDown = true;
        report(QStringLiteral("down"), -1, m_pen, nullptr, event->timestamp, QStringLiteral("pen"));
    } else if (m_penDown) {
        m_penDown = false;
        report(QStringLiteral("up"), -1, m_pen, &event->position, event->timestamp, QStringLiteral("pen"));
    }
}

void OskGateSpy::cancel()
{
    const bool had = !m_touches.isEmpty();
    m_touches.clear();
    if (had && !OskGateEffect::locked()) {
        m_gate->emitEvent(QJsonObject{{QStringLiteral("type"), QStringLiteral("cancel")}, {QStringLiteral("t"), nowUs()}});
    }
}

OskGateEffect::OskGateEffect()
    : m_spy(std::make_unique<OskGateSpy>(this))
{
    input()->installInputEventSpy(m_spy.get());

    SeatInterface *seat = waylandServer()->seat();
    m_lastFocus = seat->focusedTextInputSurface();
    if (auto *ti = seat->textInputV1()) {
        connect(ti, &TextInputV1Interface::requestShowInputPanel, this, [this] { textEvent(QStringLiteral("v1-show")); });
        connect(ti, &TextInputV1Interface::requestHideInputPanel, this, [this] { textEvent(QStringLiteral("v1-hide")); });
        connect(ti, &TextInputV1Interface::enabledChanged, this, [this, ti] {
            textEvent(ti->isEnabled() ? QStringLiteral("v1-enabled") : QStringLiteral("v1-disabled"));
        });
    }
    if (auto *ti = seat->textInputV2()) {
        connect(ti, &TextInputV2Interface::requestShowInputPanel, this, [this] { textEvent(QStringLiteral("v2-show")); });
        connect(ti, &TextInputV2Interface::requestHideInputPanel, this, [this] { textEvent(QStringLiteral("v2-hide")); });
        connect(ti, &TextInputV2Interface::enabledChanged, this, [this, ti] {
            textEvent(ti->isEnabled() ? QStringLiteral("v2-enabled") : QStringLiteral("v2-disabled"));
        });
    }
    if (auto *ti = seat->textInputV3()) {
        // KWin emits enableRequested on EVERY commit of an enabled text input (cursor rectangle,
        // surrounding text, content type...), not only a re-enable: one per keystroke while typing
        connect(ti, &TextInputV3Interface::enableRequested, this, [this] { textEvent(QStringLiteral("v3-commit")); });
        connect(ti, &TextInputV3Interface::enabledChanged, this, [this, ti, seat] {
            // on a focus change KWin's sendEnter re-announces a client's still-enabled state before it
            // emits focusedTextInputSurfaceChanged: that "enable" is KWin's, not a request of the client
            const bool byFocus = seat->focusedTextInputSurface() != m_lastFocus.data();
            textEvent(ti->isEnabled() ? QStringLiteral("v3-enabled") : QStringLiteral("v3-disabled"), byFocus);
        });
    }
    connect(seat, &SeatInterface::focusedTextInputSurfaceChanged, this, [this, seat] {
        m_lastFocus = seat->focusedTextInputSurface();
        textEvent(QStringLiteral("focus"));
    });
    if (InputMethod *im = kwinApp()->inputMethod()) {
        connect(im, &InputMethod::activeChanged, this, [this](bool active) {
            textEvent(active ? QStringLiteral("im-active") : QStringLiteral("im-inactive"));
        });
    }
}

OskGateEffect::~OskGateEffect()
{
    if (input()) {
        input()->uninstallInputEventSpy(m_spy.get());
    }
}

void OskGateEffect::touchCancel()
{
    m_spy->cancel();
}

bool OskGateEffect::locked()
{
    return waylandServer() && waylandServer()->isScreenLocked();
}

QString OskGateEffect::windowId(const Window *window)
{
    if (!window) {
        return QString();
    }
    return window->resourceClass() + QLatin1Char('|') + window->desktopFileName();
}

QString OskGateEffect::windowUid(const Window *window)
{
    return window ? window->internalId().toString(QUuid::WithoutBraces) : QString();
}

void OskGateEffect::textEvent(const QString &kind, bool byFocus)
{
    if (locked()) {
        return;
    }
    QJsonObject ev{
        {QStringLiteral("type"), QStringLiteral("text")},
        {QStringLiteral("kind"), kind},
        {QStringLiteral("t"), nowUs()},
    };
    if (byFocus) {
        ev.insert(QStringLiteral("byFocus"), true);
    }
    SeatInterface *seat = waylandServer()->seat();
    if (SurfaceInterface *surface = seat->focusedTextInputSurface()) {
        const Window *w = waylandServer()->findWindow(surface);
        ev.insert(QStringLiteral("win"), windowId(w));
        ev.insert(QStringLiteral("wid"), windowUid(w));
    }
    if (InputMethod *im = kwinApp()->inputMethod()) {
        ev.insert(QStringLiteral("active"), im->isActive());
        ev.insert(QStringLiteral("imWin"), windowId(im->activeWindow()));
        // global logical coordinates; [0,0,0,0] without an IM context, and h == 0 (at the window's
        // corner) when the client sent no cursor rectangle: treat h == 0 as unknown
        const QRectF c = im->cursorRectangle();
        ev.insert(QStringLiteral("cursor"), QJsonArray{c.x(), c.y(), c.width(), c.height()});
    }
    // KWin's own Qt items (effects' QML scenes, internal windows) also make the input method active:
    // in KWin 6.6 InternalInputMethodContext::isEnabled() is "focusObject() != nullptr", so ANY focused
    // internal item counts, text field or not. The y700-taskswitcher cards take the focus when they open,
    // the input method goes active with no client text-input traffic, and that looked exactly like a
    // KWin text field (2026-10-21: the keyboard came up under the cards opened from the desktop).
    // Upstream 430eacb550 (KWin 6.7.0) adds "&& inputMethodAccepted()". Report, with the activation,
    // whether KWin's internal focus is a text item; queried only here, not on every keystroke's commit.
    // Same answer as inputMethodAccepted(): Qt sent this very ImEnabled query to the same object a moment
    // earlier on this call stack (_q_updateFocusObject -> objectAcceptsInputMethod, then setFocusObject ->
    // enabledChanged -> refreshActive -> activeChanged -> here); items answer it from their flags only.
    if (kind == QLatin1String("im-active") && QGuiApplication::focusObject()) {
        const bool text = QInputMethod::queryFocusObject(Qt::ImEnabled, QVariant()).toBool();
        ev.insert(QStringLiteral("internal"), text ? QStringLiteral("text") : QStringLiteral("other"));
    }
    emitEvent(ev);
}

void OskGateEffect::emitEvent(const QJsonObject &event)
{
    QDBusMessage msg = QDBusMessage::createSignal(s_path, s_iface, QStringLiteral("Event"));
    msg << QString::fromUtf8(QJsonDocument(event).toJson(QJsonDocument::Compact));
    QDBusConnection::sessionBus().send(msg);
}

} // namespace KWin
