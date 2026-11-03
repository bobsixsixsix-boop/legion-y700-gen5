// Gate: see gate.h for the why and the measured behaviour it is built on.
#include "gate.h"

#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusServiceWatcher>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QTimer>

#include <cmath>
#include <functional>

namespace {
const QString EFFECT = QStringLiteral("y700_oskgate");
constexpr double TAP_TRAVEL = 16;      // logical px: a finger that moved further was dragging/scrolling
constexpr double TAP_MS = 800;         // a longer press is a hold (context menu, selection)
constexpr qint64 EVIDENCE_MS = 600;    // Telegram's show request came 1-20 ms after the lift; slack for a busy app
constexpr double NEAR_Y = 48;          // v3 cursor rectangle vs. tap, vertical
constexpr double NEAR_X = 700;         //   horizontal: the caret can be anywhere along a wide field

QRectF rectOf(const QJsonObject &o)
{
    const QJsonArray a = o.value(QStringLiteral("cursor")).toArray();
    if (a.size() != 4) return {};
    return QRectF(a.at(0).toDouble(), a.at(1).toDouble(), a.at(2).toDouble(), a.at(3).toDouble());
}
}

Gate::Gate(QObject *parent) : QObject(parent)
{
    m_clock.start();
    auto bus = QDBusConnection::sessionBus();
    bus.connect(QStringLiteral("org.kde.KWin"), QStringLiteral("/org/y700/OskGate"), QStringLiteral("org.y700.OskGate"),
                QStringLiteral("Event"), this, SLOT(onEvent(QString)));
    // KWin unloads every effect when the compositor restarts (a GPU reset, Compositing reinit); kwinrc
    // has the effect enabled so KWin reloads it itself, and we check again right after
    bus.connect(QStringLiteral("org.kde.KWin"), QStringLiteral("/Compositor"), QStringLiteral("org.kde.kwin.Compositing"),
                QStringLiteral("compositingToggled"), this, SLOT(onCompositingToggled(bool)));
    auto *kwin = new QDBusServiceWatcher(QStringLiteral("org.kde.KWin"), bus, QDBusServiceWatcher::WatchForOwnerChange, this);
    connect(kwin, &QDBusServiceWatcher::serviceOwnerChanged, this, [this] {
        setAlive(false);                      // a new KWin: focus-driven until it reports again
        m_loadRefused = false;
        QTimer::singleShot(2000, this, &Gate::ensureLoaded);
    });
    m_check = new QTimer(this);
    m_check->setInterval(15000);
    connect(m_check, &QTimer::timeout, this, &Gate::ensureLoaded);
    m_check->start();
    // the panel's DPMS state: a tap that wakes a dark screen is swallowed by KWin, not a tap on a field
    m_dpmsFiles = panelDpms(QStringLiteral("/sys/class/drm"));
    ensureLoaded();
}

QStringList Gate::panelDpms(const QString &drmDir)
{
    // The internal DSI panel only, enabled or not: the touches land on it. This list is made once, at
    // start. An external output that was enabled then reads Off for good once it is unplugged, and every
    // touch would count as the wake tap until the keyboard restarts (10-31 audit osk A1); a panel KWin
    // had switched off right then (no encoder) was left out, and the wake tap counted as a tap.
    QStringList files;
    const QDir drm(drmDir);
    for (const QString &c : drm.entryList(QDir::Dirs | QDir::NoDotAndDotDot))
        if (c.contains(QLatin1String("-DSI-")) && QFile::exists(drm.filePath(c + QStringLiteral("/dpms"))))
            files << drm.filePath(c + QStringLiteral("/dpms"));
    return files;
}

void Gate::ensureLoaded()
{
    if (m_checking) return;
    m_checking = true;
    auto call = [this](const QString &method, std::function<void(bool)> onReply) {
        auto m = QDBusMessage::createMethodCall(QStringLiteral("org.kde.KWin"), QStringLiteral("/Effects"),
                                                QStringLiteral("org.kde.kwin.Effects"), method);
        m << EFFECT;
        auto *w = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(m), this);
        connect(w, &QDBusPendingCallWatcher::finished, this, [w, onReply] {
            w->deleteLater();
            QDBusPendingReply<bool> r = *w;
            onReply(r.isValid() && r.value());
        });
    };
    call(QStringLiteral("isEffectLoaded"), [this, call](bool loaded) {
        if (loaded || m_loadRefused) {
            m_checking = false;
            setAlive(loaded);
            return;
        }
        call(QStringLiteral("loadEffect"), [this](bool ok) {
            m_checking = false;
            // refused = no plugin or one built for another KWin: stop asking until KWin changes
            if (!ok) m_loadRefused = true;
            setAlive(ok);
        });
    });
}

void Gate::onCompositingToggled(bool on)
{
    if (!on) { setAlive(false); return; }
    m_loadRefused = false;
    QTimer::singleShot(500, this, &Gate::ensureLoaded);
}

void Gate::lost()
{
    note(QStringLiteral("effect silent where it always speaks: re-checking"));
    setAlive(false);
    ensureLoaded();
}

void Gate::setAlive(bool a)
{
    if (a == m_alive) return;
    m_alive = a;
    m_down.clear();
    m_tap = {};
    m_recent.clear();
    note(a ? QStringLiteral("effect alive: tap-gated") : QStringLiteral("effect gone: focus-driven fallback"));
    emit aliveChanged(a);
}

void Gate::note(const QString &line)
{
    m_log << QStringLiteral("%1 %2").arg(m_clock.elapsed() / 1000.0, 0, 'f', 3).arg(line);
    while (m_log.size() > 120) m_log.removeFirst();
}

bool Gate::busy() const
{
    for (const Down &d : m_down)
        if (!d.ignore) return true;
    return m_tap.valid && m_clock.elapsed() - m_tap.at <= EVIDENCE_MS;
}

bool Gate::kwinInitiated() const
{
    const qint64 now = m_clock.elapsed();
    return now - m_imActiveAt < 400 && std::abs(m_imActiveAt - m_clientAt) > 40 && msSinceAppTouch() > 800
        && !m_imInternalOther;
}

bool Gate::internalOther() const
{
    return m_imInternalOther && m_clock.elapsed() - m_imActiveAt < 400;
}

Gate::Touch Gate::touchBefore(qint64 t) const
{
    for (auto it = m_recent.crbegin(); it != m_recent.crend(); ++it)
        if (it->downAt <= t) return *it;
    return {};
}

void Gate::lookUp(const QString &win, const QString &wid)
{
    if (wid.isEmpty() || m_managed.contains(wid)) return;
    if (m_managed.size() > 256) m_managed.clear();      // window ids are never reused: just start over
    // an app's window carries its desktop file ("class|app"); without one it is a layer-shell surface or
    // an X11 app without one (Steam). KWin's getWindowInfo knows only the windows it manages: an empty
    // map for this keyboard, Steam's caption/class/type for Steam (2026-10-30).
    if (!win.endsWith(QLatin1Char('|'))) { m_managed.insert(wid, 1); return; }
    m_managed.insert(wid, -1);
    auto m = QDBusMessage::createMethodCall(QStringLiteral("org.kde.KWin"), QStringLiteral("/KWin"), QStringLiteral("org.kde.KWin"),
                                            QStringLiteral("getWindowInfo"));
    m << wid;
    auto *w = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(m), this);
    connect(w, &QDBusPendingCallWatcher::finished, this, [this, w, wid] {
        w->deleteLater();
        QDBusPendingReply<QVariantMap> r = *w;
        // no answer (a KWin without the call): an app window, as it was before this check existed
        m_managed.insert(wid, !r.isValid() || !r.value().isEmpty() ? 1 : 0);
    });
}

void Gate::stillThere(const QString &wid, QObject *ctx, const std::function<void(bool)> &done)
{
    auto m = QDBusMessage::createMethodCall(QStringLiteral("org.kde.KWin"), QStringLiteral("/KWin"), QStringLiteral("org.kde.KWin"),
                                            QStringLiteral("getWindowInfo"));
    m << wid;
    auto *w = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(m), ctx);
    connect(w, &QDBusPendingCallWatcher::finished, ctx, [w, done] {
        w->deleteLater();
        QDBusPendingReply<QVariantMap> r = *w;
        // an empty map once the window is gone; no answer: there, as before this check existed
        done(!r.isValid() || (!r.value().isEmpty() && !r.value().value(QStringLiteral("minimized")).toBool()));
    });
}

bool Gate::tapAnywhere(const QString &win)
{
    // text-centric apps whose show request on focus-in cannot be told from one for the tapped text:
    // tapping them to bring them to the front is taken as "I want to type"
    static const QStringList apps{ QStringLiteral("org.kde.konsole"), QStringLiteral("org.kde.kate"),
                                   QStringLiteral("org.kde.kwrite"), QStringLiteral("org.kde.yakuake") };
    for (const QString &a : apps)
        if (win.startsWith(a + QLatin1Char('|'))) return true;
    return false;
}

bool Gate::near(const QPointF &p, const QRectF &c) const
{
    // h == 0: no rectangle from the client (KWin then reports the window corner); [0,0,0,0]: no context
    if (c.height() <= 0) return false;
    return std::abs(p.y() - c.center().y()) <= std::max(NEAR_Y, c.height() * 1.5)
        && p.x() >= c.left() - NEAR_X && p.x() <= c.right() + NEAR_X;
}

bool Gate::screenOff() const
{
    for (const QString &f : m_dpmsFiles) {
        QFile d(f);
        if (d.open(QIODevice::ReadOnly) && !d.readAll().startsWith("On")) return true;
    }
    return false;
}

void Gate::want(const QString &wid, const QString &reason)
{
    if (!m_tap.valid) return;
    m_tap.valid = false;                   // one show per tap
    m_confirmedWid = wid;
    note(QStringLiteral("SHOW: %1 (%2)").arg(reason, m_tap.win));
    emit showWanted(reason);
}

void Gate::onEvent(const QString &json)
{
    const qint64 now = m_clock.elapsed();
    m_lastEvent = now;
    if (!m_alive) setAlive(true);
    const QJsonObject e = QJsonDocument::fromJson(json.toUtf8()).object();
    const QString type = e.value(QStringLiteral("type")).toString();

    if (type == QLatin1String("down")) {
        const int fingers = e.value(QStringLiteral("fingers")).toInt();
        // KWin's own count includes this finger: when it is the only one, any other finger still held here
        // lost its lift (the effect does the same with its own list). Not a held pen (id -1): KWin does not
        // count it, and its lift still comes
        if (fingers <= 1 && e.value(QStringLiteral("tool")).toString() == QLatin1String("touch")) {
            const qint64 penAt = m_down.contains(-1) ? m_down.value(-1).at : -100001;
            for (auto it = m_down.begin(); it != m_down.end();) it = it.key() >= 0 ? m_down.erase(it) : std::next(it);
            for (Touch &t : m_recent) if (t.down() && t.downAt != penAt) t.upAt = now;   // ended, and not as a tap
        }
        Down d;
        d.win = e.value(QStringLiteral("win")).toString();
        d.wid = e.value(QStringLiteral("wid")).toString();
        d.pos = QPointF(e.value(QStringLiteral("x0")).toDouble(), e.value(QStringLiteral("y0")).toDouble());
        d.at = now;
        // server-side frames (title bar drags); a dark screen (the wake tap)
        d.hard = d.win.isEmpty() || e.value(QStringLiteral("frame")).toBool() || screenOff();
        // "exe|" (no desktop file) = layer-shell surfaces: this keyboard, panels, the control centre,
        // notifications, the desktop; also X11 apps without one (Steam), see lastTouch()
        d.ignore = d.hard || d.win.endsWith(QLatin1Char('|'));
        if (fingers > 1) {
            for (Down &o : m_down) o.ignore = o.hard = true;   // a multi-finger gesture: none of them is a tap
            d.ignore = d.hard = true;
        }
        m_down.insert(e.value(QStringLiteral("id")).toInt(), d);
        m_recent.append({ d.win, d.wid, now, -100000, false });
        while (m_recent.size() > 8) m_recent.removeFirst();
        lookUp(d.win, d.wid);
        if (!d.ignore) {
            m_lastAppTouch = now;
            note(QStringLiteral("down %1 %2,%3").arg(d.win).arg(d.pos.x(), 0, 'f', 0).arg(d.pos.y(), 0, 'f', 0));
        }
        return;
    }
    if (type == QLatin1String("cancel")) {
        m_down.clear();
        m_tap = {};
        for (Touch &t : m_recent) if (t.down()) t.upAt = now;   // ended, and not as a tap
        return;
    }
    if (type == QLatin1String("up")) {
        auto it = m_down.find(e.value(QStringLiteral("id")).toInt());
        if (it == m_down.end()) return;
        const Down d = *it;
        m_down.erase(it);
        const double travel = e.value(QStringLiteral("max")).toDouble(), ms = e.value(QStringLiteral("durMs")).toDouble();
        for (Touch &t : m_recent) {
            if (t.downAt != d.at || t.wid != d.wid || !t.down()) continue;
            t.upAt = now;
            t.tap = !d.hard && travel <= TAP_TRAVEL && ms <= TAP_MS;
            break;
        }
        emit touchEnded();
        if (d.ignore) return;
        m_lastAppTouch = now;
        if (travel > TAP_TRAVEL || ms > TAP_MS) {
            note(QStringLiteral("not a tap: moved %1 px in %2 ms").arg(travel, 0, 'f', 0).arg(ms, 0, 'f', 0));
            m_tap = {};
            return;
        }
        m_tap = { true, d.win, d.wid, d.pos, d.activated, now };
        note(QStringLiteral("tap %1%2").arg(d.win, d.activated ? QStringLiteral(" (activated it)") : QString()));
        // Kate/Konsole ask for the panel on the press over their text area (and on focus-in: so an
        // activating touch only counts for the tap-anywhere apps); a v3 enable/cursor during the touch
        // only counts in a window that was already active
        if (d.showHere && (!d.activated || tapAnywhere(d.win))) want(d.wid, QStringLiteral("show request during the touch"));
        else if (!d.activated && d.v3EnabledHere) want(d.wid, QStringLiteral("v3 enabled by this tap"));
        else if (!d.activated && near(d.pos, d.cursor)) want(d.wid, QStringLiteral("v3 cursor near tap (during touch)"));
        return;
    }
    if (type != QLatin1String("text")) return;

    const QString kind = e.value(QStringLiteral("kind")).toString(), wid = e.value(QStringLiteral("wid")).toString();
    const bool byFocus = e.value(QStringLiteral("byFocus")).toBool();
    const QRectF cursor = rectOf(e);
    const bool show = kind == QLatin1String("v1-show") || kind == QLatin1String("v2-show");
    const bool enabled = kind.endsWith(QLatin1String("-enabled"));
    if (kind == QLatin1String("focus")) {
        m_textWid = wid;
        for (Down &d : m_down) d.activated = true;     // this touch moved the focus: an activation
    } else if (!wid.isEmpty()) {
        m_textWid = wid;
    }
    if (kind == QLatin1String("im-active")) {
        m_imActiveAt = now;
        // "other": KWin activated it for one of its own focused items that is not a text field (an
        // effect's QML scene, e.g. the task switcher cards); absent from an older effect or without one
        m_imInternalOther = e.value(QStringLiteral("internal")).toString() == QLatin1String("other");
    }
    if (kind == QLatin1String("focus") || show || enabled || kind == QLatin1String("v3-commit")) m_clientAt = now;
    for (Down &d : m_down) {
        if (d.ignore || d.wid != wid) continue;
        if (show) d.showHere = true;
        if (kind == QLatin1String("v3-enabled") && !byFocus) d.v3EnabledHere = true;
        if ((kind == QLatin1String("v3-enabled") || kind == QLatin1String("v3-commit")) && cursor.height() > 0) d.cursor = cursor;
    }
    // a v3 commit comes with every keystroke while typing: log it only around a touch
    const bool afterTap = m_tap.valid && now - m_tap.at <= EVIDENCE_MS;
    if (kind != QLatin1String("v3-commit") || afterTap || !m_down.isEmpty())
        note(QStringLiteral("%1 %2%3 cursor %4,%5 h%6%7").arg(kind, e.value(QStringLiteral("win")).toString(),
             byFocus ? QStringLiteral(" byFocus") : QString()).arg(cursor.x(), 0, 'f', 0).arg(cursor.y(), 0, 'f', 0).arg(cursor.height(), 0, 'f', 0)
             .arg(e.contains(QStringLiteral("internal")) ? QStringLiteral(" internal ") + e.value(QStringLiteral("internal")).toString() : QString()));

    if (!afterTap || wid != m_tap.wid) return;
    if (show) want(wid, QStringLiteral("explicit ") + kind + QStringLiteral(" after the lift"));
    // AFTER the lift a v3 client only enables or commits when the tap touched a text widget: focus or
    // caret moved by it (Chrome field/omnibox, GTK text view - whose caret jumps to the last line when
    // the tap lands below the text, so no proximity test). Taps elsewhere gave none in every measured
    // case (Chrome page area: a disable; GTK header bar; Claude; Dolphin). An enable alone after an
    // ACTIVATING tap may be a slow focus restore: not enough.
    else if (kind == QLatin1String("v3-enabled") && !byFocus && !m_tap.activated) want(wid, QStringLiteral("v3 enabled after the lift"));
    else if (kind == QLatin1String("v3-commit")) want(wid, QStringLiteral("v3 commit after the lift"));
}
