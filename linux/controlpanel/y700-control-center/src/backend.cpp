#include "backend.h"
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusInterface>
#include <QDBusReply>
#include <QDBusArgument>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusServiceWatcher>
#include <memory>
#include <QDir>
#include <QEvent>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QPainterPath>
#include <QPlatformSurfaceEvent>
#include <QProcessEnvironment>
#include <QQuickWindow>
#include <QRegularExpression>
#include <QWindow>
#include <QtGui/qguiapplication_platform.h>   // QNativeInterface::QWaylandApplication: Qt's wl_display
#include <qpa/qplatformwindow_p.h>            // QNativeInterface::Private::QWaylandWindow (qt6-base-private-dev): the wl_surface
#include <chrono>
#include <fcntl.h>
#include <linux/input.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <cstdio>

// Children must not inherit QT_WAYLAND_SHELL_INTEGRATION=layer-shell (set by LayerShellQt::Shell::useLayerShell
// in our own environment): a Konsole launched with it becomes a layer-shell surface with no title bar and no
// taskbar entry, impossible to close. Everything we spawn gets the plain session environment.
static QProcessEnvironment childEnv()
{
    QProcessEnvironment e = QProcessEnvironment::systemEnvironment();
    e.remove("QT_WAYLAND_SHELL_INTEGRATION");
    e.remove("QT_QPA_PLATFORM");
    return e;
}

// One shell pipeline collects everything the sheet shows. Sections are split on the === markers.
static const char *STATUS_CMD =
    "tb323fu-ctl --json status 2>/dev/null; echo ===HUD; $HOME/.local/bin/y700-hud-toggle status 2>/dev/null;"
    " echo ===ROT; /usr/local/bin/y700-autorotate status 2>/dev/null; echo ===WIFI; nmcli -t -f WIFI radio 2>/dev/null;"
    " nmcli -t -f NAME,TYPE connection show --active 2>/dev/null; echo ===BT; bluetoothctl show 2>/dev/null | grep Powered;"
    " echo ===VOL; wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null; echo ===TS; tailscale status --json 2>/dev/null;"
    " echo ===REC; pw-cli ls Node 2>/dev/null | grep -c 'media.class = \"Stream/Input/Video\"';"
    " echo ===AB; systemctl --user is-active y700-autobright.service 2>/dev/null;"
    " echo ===TSBIN; command -v tailscale 2>/dev/null";     // last: section("TS") finds the first ===TS

Backend::Backend(QObject *parent) : QObject(parent)
{
    m_poll.setInterval(5000);
    connect(&m_poll, &QTimer::timeout, this, &Backend::refresh);
    // the first query soon after start, not at the first pull: until it has answered the sheet shows the empty
    // state (10-22, the first pull after boot: the Tailscale tile said 未安装 and the battery −% for a second)
    QTimer::singleShot(1500, this, &Backend::refresh);
    m_mediaPoll.setInterval(2000);
    connect(&m_mediaPoll, &QTimer::timeout, this, &Backend::pollMedia);
    m_brightnessFlush.setSingleShot(true); m_brightnessFlush.setInterval(40);
    connect(&m_brightnessFlush, &QTimer::timeout, this, &Backend::flushBrightness);
    m_volumeFlush.setSingleShot(true); m_volumeFlush.setInterval(80);
    connect(&m_volumeFlush, &QTimer::timeout, this, &Backend::flushVolume);
    m_volumeEvent.setSingleShot(true); m_volumeEvent.setInterval(100);
    connect(&m_volumeEvent, &QTimer::timeout, this, &Backend::readVolume);
    m_refreshDebounce.setSingleShot(true); m_refreshDebounce.setInterval(500);
    connect(&m_refreshDebounce, &QTimer::timeout, this, &Backend::refresh);
    // live brightness (the Brightness applet, keys, night light) via PowerDevil's signal
    QDBusConnection::sessionBus().connect("org.kde.ScreenBrightness", "/org/kde/ScreenBrightness", "org.kde.ScreenBrightness",
                                          "BrightnessChanged", this, SLOT(onBrightnessChanged(QString,int,QString,QString)));
    m_toastTimer.setSingleShot(true); m_toastTimer.setInterval(3500);
    connect(&m_toastTimer, &QTimer::timeout, this, [this] { m_toast.clear(); Q_EMIT toastChanged(); });
    // screen recording: Spectacle is single-instance and has no "is recording" property, so st.recording is
    // set when we start one and cleared by its RecordingTaken/RecordingFailed signals or when it exits.
    // (A pgrep on "spectacle -R" was wrong both ways: the -R process forwards to the running instance.)
    QDBusConnection::sessionBus().connect(QString(), "/", "org.kde.Spectacle", "RecordingTaken", this, SLOT(onRecordingDone(QString)));
    QDBusConnection::sessionBus().connect(QString(), "/", "org.kde.Spectacle", "RecordingFailed", this, SLOT(onRecordingDone(QString)));
    auto *sw = new QDBusServiceWatcher("org.kde.Spectacle", QDBusConnection::sessionBus(), QDBusServiceWatcher::WatchForUnregistration, this);
    connect(sw, &QDBusServiceWatcher::serviceUnregistered, this, [this](const QString &) { onRecordingDone(QString()); });
    openHaptics();
    auto *nw = new QDBusServiceWatcher("org.freedesktop.Notifications", QDBusConnection::sessionBus(),
                                       QDBusServiceWatcher::WatchForOwnerChange, this);
    connect(nw, &QDBusServiceWatcher::serviceOwnerChanged, this, [this] { ++m_notifyGen; Q_EMIT notifyGenChanged(); });
}

Backend::~Backend()
{
    for (int fd : m_ff) ::close(fd);
}

// ---------------------------------------------------------------- window

void Backend::show()
{
    if (m_visible) return;
    if (m_win) m_win->show();
    m_visible = true;
    Q_EMIT visibleChanged();
    Q_EMIT openChanged(true);
    readBrightness();
    readVolume();           // ahead of refresh(): its pipeline brings the volume too, but only after 0.35 s or more
    watchVolume(true);
    refresh();
    pollMedia();
    m_poll.start();
    m_mediaPoll.start();
}

void Backend::hide()
{
    if (!m_visible) return;
    m_visible = false;          // QML slides the sheet out, then calls hideDone()
    Q_EMIT visibleChanged();
    Q_EMIT openChanged(false);
    m_poll.stop();
    m_mediaPoll.stop();
    watchVolume(false);
}

void Backend::hideDone()
{
    if (!m_visible && m_win) m_win->hide();
}

static qint64 nowUs()
{
    return std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
}

void Backend::setWindow(QWindow *w)
{
    m_win = w;
    if (!w) return;
    w->installEventFilter(this);
    if (m_blurDirty) w->requestUpdate();
    m_trace = qEnvironmentVariableIsSet("Y700_CC_TRACE");
    if (auto *qw = qobject_cast<QQuickWindow *>(w)) {
        // emitted on the render thread right after the buffer went to the compositor: direct, atomics only
        connect(qw, &QQuickWindow::frameSwapped, this, [this] { m_swapUs = nowUs(); m_swaps.fetch_add(1); }, Qt::DirectConnection);
        // the hand-over itself (eventFilter says why there): render thread, GUI thread blocked. A region change alone
        // still gets this sync's commit (setBlur's update(); WlBlurWindow::sync)
        m_blurOnSync = true;
        connect(qw, &QQuickWindow::beforeSynchronizing, this, [this] {
            if (!m_blurDirty || !m_blur.attached()) return;
            m_blurDirty = false;
            trace("apply", "sync");
            m_blur.handOver(m_blurRegion);
        }, Qt::DirectConnection);
    }
    m_blur.trace = [this](const char *what, const char *detail) { trace(what, detail); };
    if (auto *native = qGuiApp->nativeInterface<QNativeInterface::QWaylandApplication>()) m_blur.bind(native->display());
    if (w->handle()) attachBlurSurface();          // else the first show creates it: QEvent::PlatformSurface (eventFilter)
}

// t is the same stamp capseq.py prints per frame (wall-clock µs mod 2^32, in ms)
void Backend::trace(const char *what, const char *detail)
{
    if (!m_trace) return;
    const qint64 now = nowUs();
    const unsigned swaps = m_swaps.load();
    fprintf(stderr, "cc-trace %s swaps_since=%u since_swap_ms=%.2f t=%u %s\n", what, swaps - m_swapsSeen,
            (now - m_swapUs.load()) / 1000.0, unsigned((quint64(now) % 4294967296ULL) / 1000), detail);
    m_swapsSeen = swaps;
}

// The blur region is only remembered here; it is handed to KWin once per frame (the sync lambda in setWindow, see
// eventFilter), through our own org_kde_kwin_blur objects (wlblur.h). Until 10-22 this called
// KWindowEffects::enableBlurBehind straight from the
// QML property change, and the curtain flickered while it moved: a frame or several painted tinted but sharp, then
// blurred again. Root cause (WAYLAND_DEBUG timeline + KWin 6.6.6 source): every enableBlurBehind() creates a new
// blur object and release()s the previous one a moment later (deleteLater), whether or not KWin has applied the
// commit carrying the new one. KWin keeps the object in the surface's pending state by QPointer, and after
// wl_surface.commit that state waits in a transaction until the buffer's dmabuf fence signals (a few ms). A release
// that lands in that gap nulls the pointer; the transaction then applies "no blur" and every frame until the next
// commit with a live object paints the tint over a sharp desktop. One region change per frame, in the wrong place,
// was enough. Handing over at the UpdateRequest only (before the render thread's commit) cut it to the rare case
// where Qt delivers a second UpdateRequest before the commit (its "requestUpdate called twice" path, 10 of 76
// hand-overs during a pull); only not releasing before KWin has applied the newer object removes it altogether.
void Backend::setBlur(int x, int y, int w, int h, int radius)
{
    const QRect r(x, y, w, h);
    if (r == m_blurRect && radius == m_blurRadius) return;
    m_blurRect = r; m_blurRadius = radius;
    if (radius <= 0) m_blurRegion = QRegion(r);
    else {
        QPainterPath path;
        path.addRoundedRect(QRectF(r), radius, radius);
        m_blurRegion = QRegion(path.toFillPolygon().toPolygon());
    }
    m_blurDirty = true;
    // a change without a repaint behind it still gets a frame (QQuickWindow::update: WlBlurWindow::setRegion says why)
    if (!m_win) return;
    if (m_blurOnSync) static_cast<QQuickWindow *>(m_win)->update();
    else m_win->requestUpdate();
}

// Until 10-23 (the hand-over at UpdateRequest, the reasons still hold for the sync that follows it):
// QEvent::UpdateRequest is Qt's "render the next frame now", delivered before the render thread touches the
// frame: the new object and its region go out ahead of the commit that paints the frame - but from the GUI thread,
// so the render thread's commit for an EARLIER frame could still land between them (below) - and
// with the state that frame paints (Qt Quick advances its animations AFTER the sync, for the next frame;
// a region set then is handed over at the next UpdateRequest, with the frame that shows it). Handing it over
// straight from setBlur() would put it in whatever commit the render thread is about to make - the previous
// frame's as often as not. Expose: the first frame of a freshly shown window comes from the expose, not from an
// UpdateRequest. Nothing is skipped: the previous object stays alive until KWin is known to have applied the new
// one (WlBlur::onFrame), so a hand-over racing the render thread's commit costs at most a region one frame ahead
// of its content, never a frame without blur.
// Since 10-23 the hand-over itself runs one step later, in beforeSynchronizing (setWindow): the sync that the
// UpdateRequest / Expose starts, on the render thread, the GUI thread blocked - the same frame and the same state,
// but on the thread that makes the commit, so the hand-over's requests can no longer be split by one (wlblur.h).
// A window that is not a QQuickWindow would still hand over here.
bool Backend::eventFilter(QObject *o, QEvent *e)
{
    if (o != m_win) return QObject::eventFilter(o, e);
    if (e->type() == QEvent::PlatformSurface) {
        // the platform window (and with it the wl_surface) appears with the first show, or goes with the window
        if (static_cast<QPlatformSurfaceEvent *>(e)->surfaceEventType() == QPlatformSurfaceEvent::SurfaceCreated) attachBlurSurface();
        else m_blur.detach();
    } else if (!m_blurOnSync && m_blurDirty && m_blur.attached()
               && (e->type() == QEvent::UpdateRequest || e->type() == QEvent::Expose)) {
        m_blurDirty = false;
        trace("apply", e->type() == QEvent::Expose ? "expose" : "update");
        m_blur.handOver(m_blurRegion);
    }
    return QObject::eventFilter(o, e);
}

// The window's wl_surface to m_blur. Qt 6.10 makes it with the platform window and keeps it over hide/show (only
// the layer-shell role goes: the blur object KWin holds for the surface survives a hide, and the next show maps
// with it); a new one comes only with a role change (surfaceCreated). A fresh surface gets the region at once, so
// it is in KWin's state before the initial commit and the first frame maps blurred.
void Backend::attachBlurSurface()
{
    auto *ww = m_win ? m_win->nativeInterface<QNativeInterface::Private::QWaylandWindow>() : nullptr;
    if (!ww) return;
    if (ww != m_blurWindow) {
        m_blurWindow = ww;
        connect(ww, &QNativeInterface::Private::QWaylandWindow::surfaceCreated, this, &Backend::attachBlurSurface);
        connect(ww, &QNativeInterface::Private::QWaylandWindow::surfaceDestroyed, this, [this] { m_blur.detach(); });
    }
    if (!m_blur.attach(ww->surface())) return;
    if (!m_blurRegion.isEmpty()) {
        m_blurDirty = false;
        trace("apply", "surface");
        m_blur.handOver(m_blurRegion);
    }
}

void Backend::setSide(const QString &side)
{
    const QString s = side == QLatin1String("left") ? side : QStringLiteral("right");
    if (s == m_side) return;
    m_side = s;
    Q_EMIT sideChanged();
}

// ---------------------------------------------------------------- back key (left/right edge swipe)

// Linux has no system-wide "back": browsers and file managers go back with Alt+Left, most other apps
// (wiliwili, mpv, dialogs, a fullscreen video in the browser) take Esc (owner 10-21: per app, browsers
// Alt+Left, the rest Esc). ~/.config/y700-back.conf overrides per window class: lines `class = esc|alt-left|back`
// (back = the XF86Back media key), `#` comments; read on every swipe, so an edit counts at once.
static QList<int> backKeys(const QString &cls, bool fullScreen)
{
    static const QStringList altLeft = {"google-chrome", "chromium", "chromium-browser", "firefox", "org.mozilla.firefox",
                                        "microsoft-edge", "brave-browser", "org.kde.falkon", "org.kde.dolphin", "dolphin",
                                        "org.kde.okular", "okular"};
    const QList<int> esc = {KEY_ESC}, alt = {KEY_LEFTALT, KEY_LEFT};
    QFile f(QDir::homePath() + "/.config/y700-back.conf");
    if (f.open(QIODevice::ReadOnly)) {
        for (const QString &raw : QString::fromUtf8(f.readAll()).split('\n')) {
            const QString line = raw.section('#', 0, 0).trimmed();
            const QString k = line.section('=', 0, 0).trimmed(), v = line.section('=', 1).trimmed().toLower();
            if (k.compare(cls, Qt::CaseInsensitive) != 0) continue;
            if (v == "esc") return esc;
            if (v == "alt-left") return alt;
            if (v == "back") return {KEY_BACK};
        }
    }
    // a fullscreen browser is a video (or F11): Esc leaves fullscreen first, like Android's back
    if (altLeft.contains(cls.toLower()) && !fullScreen) return alt;
    return esc;
}

void Backend::back(const QString &resourceClass, bool fullScreen)
{
    const QList<int> keys = backKeys(resourceClass, fullScreen);
    QString err;
    if (!m_keys.chord(keys, &err)) {
        fprintf(stderr, "back: %s\n", qPrintable(err));
        return;
    }
    fprintf(stderr, "back: %s%s -> %s\n", qPrintable(resourceClass), fullScreen ? " (fullscreen)" : "",
            keys == QList<int>{KEY_ESC} ? "Esc" : keys == QList<int>{KEY_BACK} ? "XF86Back" : "Alt+Left");
}

// ---------------------------------------------------------------- haptics (aw86927, force feedback)

void Backend::openHaptics()
{
    // both motors are "aw86927-haptics" input devices with FF_RUMBLE; the user is in group input
    const QDir dir("/dev/input");
    for (const QString &name : dir.entryList({"event*"}, QDir::System | QDir::Files)) {
        const QByteArray path = dir.filePath(name).toLocal8Bit();
        int fd = ::open(path.constData(), O_RDWR | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) continue;
        char dev[64] = {0};
        ioctl(fd, EVIOCGNAME(sizeof dev - 1), dev);
        unsigned long ffbits[(FF_MAX + 1) / (8 * sizeof(unsigned long)) + 1] = {0};
        ioctl(fd, EVIOCGBIT(EV_FF, sizeof ffbits), ffbits);
        const bool rumble = ffbits[FF_RUMBLE / (8 * sizeof(unsigned long))] & (1UL << (FF_RUMBLE % (8 * sizeof(unsigned long))));
        if (QString::fromLatin1(dev).contains("haptics") && rumble) { m_ff << fd; m_ffId << -1; }
        else ::close(fd);
    }
}

void Backend::haptic()
{
    trace("haptic");
    for (int i = 0; i < m_ff.size(); ++i) {
        struct ff_effect e {};
        e.type = FF_RUMBLE;
        e.id = m_ffId[i];
        e.u.rumble.strong_magnitude = 0x5000;   // the first version (0xc000 / 28 ms) was "too heavy"
        e.u.rumble.weak_magnitude = 0x2000;
        e.replay.length = 18;           // ms: a tick, not a buzz
        e.replay.delay = 0;
        if (ioctl(m_ff[i], EVIOCSFF, &e) < 0) continue;
        m_ffId[i] = e.id;
        struct input_event play {};
        play.type = EV_FF; play.code = e.id; play.value = 1;
        if (::write(m_ff[i], &play, sizeof play) < 0) { /* ignore */ }
    }
}

// ---------------------------------------------------------------- status

void Backend::refresh()
{
    if (m_status) return;       // one at a time
    m_status = new QProcess(this);
    connect(m_status, &QProcess::finished, this, [this](int, QProcess::ExitStatus) {
        const QString out = QString::fromUtf8(m_status->readAllStandardOutput());
        m_status->deleteLater(); m_status = nullptr;
        parseStatus(out);
    });
    m_status->setProcessEnvironment(childEnv());
    m_queryStart = QDateTime::currentMSecsSinceEpoch();
    m_status->start("/bin/sh", {"-c", QString::fromLatin1(STATUS_CMD)});
}

void Backend::parseStatus(const QString &out)
{
    QVariantMap st = m_st;
    auto section = [&](const QString &tag) -> QString {
        const int i = out.indexOf("===" + tag);
        if (i < 0) return {};
        const int s = i + tag.size() + 3;
        // the next marker ends the section whether or not the command before it printed a final newline
        // (`tailscale status --json` does not: with "\n===" as the delimiter the ===REC marker added on
        // 2026-10-14 became part of the TS JSON, it failed to parse and the tile said "not installed")
        const int e = out.indexOf("===", s);
        return out.mid(s, e < 0 ? -1 : e - s).trimmed();
    };
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    const QString json = out.left(out.indexOf("===HUD"));
    const QJsonObject j = QJsonDocument::fromJson(json.toUtf8()).object();
    if (!j.isEmpty()) {
        const QJsonObject bat = j.value("Battery").toObject();
        st["bypass"] = bat.value("Bypass").toBool();
        st["battery"] = bat.value("Capacity").toInt(-1);
        st["charging"] = bat.value("InputCurrentMa").toInt() > 0;
        st["profile"] = j.value("Gpu").toObject().value("Profile").toString();
        st["torch"] = j.value("Torch").toObject().value("On").toBool();
        const QJsonObject rf = j.value("Refresh").toObject();
        // configured rate: the fixed one in manual mode, else the auto policy's ceiling (idle drops are not shown)
        st["hz"] = rf.value("Policy").toString() == "manual" ? rf.value("Rate").toInt() : rf.value("MaxHz").toInt();
    }
    const QString hud = section("HUD");                 // off | full | mini (y700-hud-toggle status)
    st["hud"] = (hud == "full" || hud == "mini") ? hud : QStringLiteral("off");
    st["rotLocked"] = section("ROT").contains(" never");
    const QStringList wifi = section("WIFI").split('\n');
    st["wifi"] = !wifi.isEmpty() && wifi.first() == "enabled";
    QString ssid;
    for (const QString &l : wifi) if (l.endsWith(":802-11-wireless")) { ssid = l.chopped(16); break; }
    st["ssid"] = ssid;
    st["bt"] = section("BT").contains("yes");
    // automatic brightness (linux/display/y700-autobright): whether its user service runs
    const QString ab = section("AB");
    st["autobright"] = ab == "active" || ab == "activating";
    const QString vol = section("VOL");           // "Volume: 0.40 [MUTED]"
    const QRegularExpressionMatch m = QRegularExpression("Volume: ([0-9.]+)").match(vol);
    st["volume"] = m.hasMatch() ? m.captured(1).toDouble() : 0.0;
    st["muted"] = vol.contains("MUTED");
    // the pipeline may have read the level before a drag wrote it, or before a sink event's readVolume() that
    // already landed (that one started later, so it is the newer sample)
    if (volumeOurs(m_queryStart) || m_queryStart < m_volumeAt) {
        st["volume"] = m_st.value("volume", st["volume"]); st["muted"] = m_st.value("muted", st["muted"]);
    } else {
        m_volumeAt = m_queryStart;
    }
    // Tailscale: BackendState Running | Stopped | NeedsLogin | NoState, "" = no answer, plus our tailnet address.
    // tsInstalled is whether the binary is there at all: "" with it there is tailscaled not answering (the tile
    // once called that 未安装)
    const QJsonObject ts = QJsonDocument::fromJson(section("TS").toUtf8()).object();
    st["ts"] = ts.value("BackendState").toString();
    st["tsInstalled"] = !section("TSBIN").isEmpty();
    const QJsonArray ips = ts.value("Self").toObject().value("TailscaleIPs").toArray();
    st["tsIp"] = ips.isEmpty() ? QString() : ips.first().toString();
    st["tsName"] = ts.value("Self").toObject().value("DNSName").toString().section('.', 0, 0);
    // keep the optimistic value of anything toggled while this query ran, or in the last 1.5 s, or still
    // running/queued: the pipeline may have sampled the old hardware state. This comes AFTER every field
    // is parsed (the Tailscale state was once assigned after this loop and undid the protection).
    static const QMap<QString, QString> keyOf = {{"wifi", "wifi"}, {"bt", "bt"}, {"rot", "rotLocked"}, {"hud", "hud"},
                                                 {"bypass", "bypass"}, {"torch", "torch"}, {"profile", "profile"}, {"hz", "hz"}, {"ts", "ts"},
                                                 {"autobright", "autobright"}};
    for (auto it = keyOf.cbegin(); it != keyOf.cend(); ++it) {
        const qint64 last = m_lastAction.value(it.key(), 0);
        if (m_running.contains(it.key()) || m_queued.contains(it.key()) || last >= m_queryStart || now - last < 1500)
            if (m_st.contains(it.value())) st[it.value()] = m_st[it.value()];
    }
    // recording: set by startRecording(), cleared by Spectacle's RecordingTaken/RecordingFailed or exit (the
    // constructor). In GUI mode a failed or cancelled recording emits no signal and Spectacle lives on, so
    // the flag also needs the evidence: a recording in progress is a screencast consumer node in PipeWire
    // (Stream/Input/Video). None 10 s after we asked -> it never started.
    bool rec = m_st.value("recording", false).toBool();
    if (rec && section("REC").toInt() == 0 && now - m_recordStart > 10000) rec = false;
    st["recording"] = rec;
    m_st = st;
    Q_EMIT stChanged();
}

void Backend::showToast(const QString &text)
{
    // the journal's record of what the owner was told (and the tray test's check of the wording)
    fprintf(stderr, "toast: %s\n", text.toUtf8().constData());
    m_toast = text; Q_EMIT toastChanged();
    m_toastTimer.start();
}

// ---------------------------------------------------------------- brightness / volume

void Backend::readBrightness()
{
    QDBusInterface d("org.kde.ScreenBrightness", "/org/kde/ScreenBrightness/display0", "org.kde.ScreenBrightness.Display");
    const int max = d.property("MaxBrightness").toInt();
    const int cur = d.property("Brightness").toInt();
    if (max > 0) { m_brightnessMax = max; m_brightness = double(cur) / max; Q_EMIT brightnessChanged(); }
}

void Backend::onBrightnessChanged(const QString &display, int value, const QString &, const QString &)
{
    // the signal carries the value: no D-Bus round trip, and our own writes echoing back are ignored
    if (display != "display0" || m_brightnessMax <= 0) return;
    if (QDateTime::currentMSecsSinceEpoch() - m_lastBrightnessWrite < 300) return;
    m_brightness = double(value) / m_brightnessMax;
    Q_EMIT brightnessChanged();
}

void Backend::setBrightness(double frac)
{
    m_pendingBrightness = qBound(0.01, frac, 1.0);
    m_brightness = m_pendingBrightness; Q_EMIT brightnessChanged();
    if (!m_brightnessFlush.isActive()) m_brightnessFlush.start();
}

void Backend::flushBrightness()
{
    if (m_pendingBrightness < 0 || m_brightnessMax <= 0) return;
    QDBusInterface d("org.kde.ScreenBrightness", "/org/kde/ScreenBrightness/display0", "org.kde.ScreenBrightness.Display");
    d.call(QDBus::NoBlock, "SetBrightness", int(m_pendingBrightness * m_brightnessMax), 1u /* silent: no OSD */);
    m_lastBrightnessWrite = QDateTime::currentMSecsSinceEpoch();
    m_pendingBrightness = -1;
}

void Backend::setVolume(double frac)
{
    m_pendingVolume = qBound(0.0, frac, 1.0);
    m_st["volume"] = m_pendingVolume; m_st["muted"] = false; Q_EMIT stChanged();
    if (!m_volumeFlush.isActive()) m_volumeFlush.start();
}

void Backend::flushVolume()
{
    // one pactl at a time (spawning wpctl every few ms stalled the drag); the newest value wins
    if (m_pendingVolume < 0 || m_volumeProc) return;
    const int pct = int(m_pendingVolume * 100 + 0.5);
    m_pendingVolume = -1;
    m_volumeProc = new QProcess(this);
    connect(m_volumeProc, &QProcess::finished, this, [this](int code, QProcess::ExitStatus status) {
        const bool ok = status == QProcess::NormalExit && code == 0;
        const QString err = QString::fromUtf8(m_volumeProc->readAllStandardError()).trimmed().section('\n', -1).left(80);
        m_volumeProc->deleteLater(); m_volumeProc = nullptr;
        // a failed write is reported and not protected: the next poll shows the real level
        m_lastVolumeWrite = ok ? QDateTime::currentMSecsSinceEpoch() : 0;
        if (!ok) showToast(QStringLiteral("音量设置失败") + (err.isEmpty() ? QString() : QStringLiteral("：") + err));
        if (m_pendingVolume >= 0) flushVolume();
    });
    m_volumeProc->setProcessEnvironment(childEnv());
    m_volumeProc->start("/bin/sh", {"-c", QString("pactl set-sink-mute @DEFAULT_SINK@ 0; pactl set-sink-volume @DEFAULT_SINK@ %1%").arg(pct)});
}

// A drag in progress, one still queued, one that finished after the sample may have been taken (since: when the
// reader started) or less than 1.5 s ago: the level on screen is ours, newer than the sample, keep it
bool Backend::volumeOurs(qint64 since) const
{
    return m_volumeProc || m_pendingVolume >= 0 || m_lastVolumeWrite >= since
        || QDateTime::currentMSecsSinceEpoch() - m_lastVolumeWrite < 1500;
}

// The volume alone: one wpctl, 12-15 ms on the tablet. Until 10-22 show() left it to refresh()'s pipeline, 0.35 s
// idle (tb323fu-ctl alone 0.25 s) and more under load, so for that long the pill showed the level from the last
// time the curtain was up; changed with the keys while it was closed (30 % -> 80 %), a drag started then moved the
// sound from the stale 30 % (relative drag, Pill.qml round 12: a nudge gave 32 %).
void Backend::readVolume()
{
    if (m_volumeRead) { m_volumeReread = true; return; }    // one at a time; an event meanwhile reads again after it
    if (volumeOurs(QDateTime::currentMSecsSinceEpoch())) return;
    const qint64 start = QDateTime::currentMSecsSinceEpoch();
    m_volumeRead = new QProcess(this);
    connect(m_volumeRead, &QProcess::finished, this, [this, start](int, QProcess::ExitStatus) {
        const QString out = QString::fromUtf8(m_volumeRead->readAllStandardOutput());   // "Volume: 0.40 [MUTED]"
        m_volumeRead->deleteLater(); m_volumeRead = nullptr;
        const QRegularExpressionMatch m = QRegularExpression("Volume: ([0-9.]+)").match(out);
        // no answer keeps what is shown (the pipeline would say 0); a drag since the sample keeps its level, and so
        // does a newer sample that landed first (the pipeline started after this one)
        if (m.hasMatch() && !volumeOurs(start) && start >= m_volumeAt) {
            m_volumeAt = start;
            const QVariant v = m.captured(1).toDouble(), muted = out.contains("MUTED");
            if (m_st.value("volume") != v || m_st.value("muted") != muted) { m_st["volume"] = v; m_st["muted"] = muted; Q_EMIT stChanged(); }
        }
        if (m_volumeReread) { m_volumeReread = false; readVolume(); }
    });
    m_volumeRead->setProcessEnvironment(childEnv());
    m_volumeRead->start("/bin/sh", {"-c", "exec wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null"});
}

// While the curtain is up, the sound server's sink events (the volume keys, the App, headphones taking over) re-read
// the volume at once instead of at the next 5 s poll: a drag must not start from a level changed meanwhile. Only
// while it is up: closed, nothing shows the level and show() reads it anyway, while a subscriber left running would
// wake this process for every client that comes and goes on the server all day (the speaker guard's pactl calls, a
// connect every few seconds when idle, tens per volume step; README「控制中心」第十三轮). If pactl dies meanwhile
// (pipewire-pulse restarted) the 5 s poll is left; the next show() starts it again.
void Backend::watchVolume(bool on)
{
    if (!on) {
        m_volumeEvent.stop();
        if (m_volumeWatch) { m_volumeWatch->kill(); m_volumeWatch = nullptr; }     // finished -> deleteLater
        return;
    }
    if (m_volumeWatch) return;
    auto *p = new QProcess(this);
    m_volumeWatch = p;
    QProcessEnvironment env = childEnv();
    env.insert("LC_ALL", "C");          // pactl translates its events (事件“change”于 接收器 #127)
    p->setProcessEnvironment(env);
    connect(p, &QProcess::readyReadStandardOutput, this, [this, p] {
        while (p->canReadLine()) {
            const QByteArray l = p->readLine();
            // "Event 'change' on sink #127" (a level or mute), "... on server #N" (the default sink changed);
            // streams (sink-input) and clients are not the level
            if (p == m_volumeWatch && (l.contains(" on sink #") || l.contains(" on server")) && !m_volumeEvent.isActive())
                m_volumeEvent.start();
        }
    });
    connect(p, &QProcess::finished, p, &QObject::deleteLater);
    p->start("/bin/sh", {"-c", "exec pactl subscribe 2>/dev/null"});
}

// ---------------------------------------------------------------- actions

void Backend::setLocal(const QString &key, const QVariant &v)
{
    m_st[key] = v;
    Q_EMIT stChanged();
}

// Toggles may be tapped as fast as the user likes: one command per name runs at a time, a newer one
// issued meanwhile replaces anything queued, and the status refresh is debounced behind the last one.
void Backend::act(const QString &name, const QString &cmd)
{
    if (m_running.contains(name)) {
        // state setters coalesce (newest wins); the one-shot system actions must not pile up
        if (name == "android" || name == "power") return;
        m_queued[name] = cmd;
        return;
    }
    startAction(name, cmd);
}

void Backend::startAction(const QString &name, const QString &cmd)
{
    auto *p = new QProcess(this);
    m_running[name] = p;
    if (name == "android" || name == "power") { m_busy = name; Q_EMIT busyChanged(); }
    connect(p, &QProcess::finished, this, [this, p, name](int code, QProcess::ExitStatus status) {
        const bool ok = status == QProcess::NormalExit && code == 0;
        QString err = QString::fromUtf8(p->readAllStandardError()).trimmed();
        p->deleteLater();
        m_running.remove(name);
        m_lastAction[name] = QDateTime::currentMSecsSinceEpoch();
        if (m_busy == name) { m_busy.clear(); Q_EMIT busyChanged(); }
        if (!ok) {
            // say so, and drop the optimistic value at once instead of letting it flip back silently
            static const QMap<QString, QString> label = {{"wifi", "Wi‑Fi"}, {"bt", "蓝牙"}, {"rot", "旋转锁定"}, {"hud", "性能浮层"},
                {"bypass", "旁路供电"}, {"torch", "手电筒"}, {"profile", "性能模式"}, {"hz", "刷新率"}, {"android", "切换到 Android"},
                {"power", "电源操作"}, {"wifi-connect", "连接 Wi‑Fi"}, {"bt-dev", "蓝牙设备"}, {"ts", "Tailscale"}, {"autobright", "自动亮度"}};
            err = err.section('\n', -1).left(80);
            showToast(label.value(name, name) + QStringLiteral("失败") + (err.isEmpty() ? QString() : QStringLiteral("：") + err));
            m_lastAction[name] = 0;
        }
        Q_EMIT actionFinished(name, ok);
        if (m_queued.contains(name)) startAction(name, m_queued.take(name));
        else if (ok) m_refreshDebounce.start();
        else refresh();
    });
    p->setProcessEnvironment(childEnv());
    p->start("/bin/sh", {"-c", cmd});
}

void Backend::launch(const QString &cmd)
{
    QProcess p;
    p.setProgram("/bin/sh"); p.setArguments({"-c", cmd});
    p.setProcessEnvironment(childEnv());
    p.setStandardOutputFile(QProcess::nullDevice()); p.setStandardErrorFile(QProcess::nullDevice());
    if (!p.startDetached()) showToast(QStringLiteral("无法启动：") + cmd.section(' ', 0, 0));
}

void Backend::startRecording()
{
    m_st["recording"] = true; m_recordStart = QDateTime::currentMSecsSinceEpoch(); Q_EMIT stChanged();
    launch("spectacle -R screen");      // forwards to the running Spectacle if there is one
}

void Backend::stopRecording()
{
    // Spectacle 6.6 has no D-Bus "stop". While recording it shows a StatusNotifierItem whose Activate (a
    // click on the tray icon) finishes the recording and saves it to ~/Videos/Screencasts. With the Plasma
    // panel gone (dock phase 3) there is no tray to click, so we find that item ourselves: the registered
    // item whose bus connection belongs to the Spectacle process. (10-22: the owner was stuck in a recording;
    // the old fallback, OpenWithoutScreenshot, opens the screenshot window, which has no stop button.)
    QDBusConnection bus = QDBusConnection::sessionBus();
    QDBusConnectionInterface *ci = bus.interface();
    const QDBusReply<uint> specPid = ci->servicePid(QStringLiteral("org.kde.Spectacle"));
    bool done = false;
    if (specPid.isValid()) {
        QDBusMessage get = QDBusMessage::createMethodCall("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
                                                          "org.freedesktop.DBus.Properties", "Get");
        get << QStringLiteral("org.kde.StatusNotifierWatcher") << QStringLiteral("RegisteredStatusNotifierItems");
        const QDBusMessage r = bus.call(get, QDBus::Block, 500);
        const QStringList items = r.type() == QDBusMessage::ReplyMessage && !r.arguments().isEmpty()
            ? r.arguments().first().value<QDBusVariant>().variant().toStringList() : QStringList();
        for (const QString &it : items) {      // "service/path", service = a unique or a well-known name
            const int slash = it.indexOf('/');
            const QString svc = slash > 0 ? it.left(slash) : it;
            const QString path = slash > 0 ? it.mid(slash) : QStringLiteral("/StatusNotifierItem");
            const QDBusReply<uint> pid = ci->servicePid(svc);
            if (!pid.isValid() || pid.value() != specPid.value()) continue;
            QDBusMessage act = QDBusMessage::createMethodCall(svc, path, "org.kde.StatusNotifierItem", "Activate");
            act << 0 << 0;
            done = bus.send(act);
            break;
        }
    }
    if (!done) {    // no tray item (not recording after all, or a Spectacle that changed): show its window
        launch("qdbus6 org.kde.Spectacle / org.kde.Spectacle.OpenWithoutScreenshot");
        showToast(QStringLiteral("没找到录屏的停止入口，已打开 Spectacle"));
    }
}

void Backend::tsLogin()
{
    // `tailscale login` prints the auth URL at once and then blocks until the browser flow finishes (or
    // fails). Read its output as it arrives and open the URL immediately; the process lives on (up to
    // 3 min) so the login can complete. The previous shell pipeline waited for the whole command to end,
    // i.e. for its timeout, before xdg-open ran.
    if (m_tsLogin) return;
    auto *p = new QProcess(this);
    m_tsLogin = p;
    p->setProcessChannelMode(QProcess::MergedChannels);
    p->setProcessEnvironment(childEnv());
    auto opened = std::make_shared<bool>(false);
    connect(p, &QProcess::readyReadStandardOutput, this, [this, p, opened] {
        const QString out = QString::fromUtf8(p->readAllStandardOutput());
        const QRegularExpressionMatch m = QRegularExpression("https://login\\.tailscale\\.com/[A-Za-z0-9/._-]+").match(out);
        if (m.hasMatch() && !*opened) { *opened = true; launch("xdg-open '" + m.captured(0) + "'"); }
    });
    connect(p, &QProcess::finished, this, [this, p, opened](int code, QProcess::ExitStatus) {
        p->deleteLater(); m_tsLogin = nullptr;
        if (!*opened) showToast(QStringLiteral("Tailscale 登录没有给出网址") + (code ? QStringLiteral("（退出码 %1）").arg(code) : QString()));
        refresh();
    });
    QTimer::singleShot(180000, p, [p] { if (p->state() != QProcess::NotRunning) p->kill(); });
    p->start("tailscale", {"login"});
}

void Backend::onRecordingDone(const QString &)
{
    if (!m_st.value("recording", false).toBool()) return;
    m_st["recording"] = false; Q_EMIT stChanged();
}

void Backend::runCapture(const QString &cmd, std::function<void(const QString &)> done)
{
    auto *p = new QProcess(this);
    connect(p, &QProcess::finished, this, [p, done](int, QProcess::ExitStatus) {
        const QString out = QString::fromUtf8(p->readAllStandardOutput());
        p->deleteLater();
        done(out);
    });
    p->setProcessEnvironment(childEnv());
    p->start("/bin/sh", {"-c", cmd});
}

// ---------------------------------------------------------------- MPRIS (now playing)

void Backend::pollMedia()
{
    // all asynchronous: a slow or hung player (every call used to block the GUI thread up to 300 ms, per
    // player, per call) must not stall the sliders
    if (m_mediaBusy) return;
    m_mediaBusy = true;
    auto *w = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().interface()->asyncCall("ListNames"), this);
    connect(w, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        const QDBusPendingReply<QStringList> r = *w; w->deleteLater();
        QStringList players;
        if (r.isValid()) for (const QString &n : r.value()) if (n.startsWith("org.mpris.MediaPlayer2.")) players << n;
        if (players.isEmpty()) {
            m_mediaBusy = false;
            if (!m_media.isEmpty()) { m_media.clear(); Q_EMIT mediaChanged(); }
            return;
        }
        mediaFetch(players);
    });
}

void Backend::mediaFetch(const QStringList &names)
{
    struct Acc { int left; QList<QVariantMap> found; };
    auto acc = std::make_shared<Acc>(); acc->left = names.size();
    auto finish = [this, acc] {
        if (--acc->left > 0) return;
        QVariantMap best;
        for (const QVariantMap &m : acc->found)
            if (best.isEmpty() || (m["status"] == "Playing" && best["status"] != "Playing")) best = m;
        m_mediaBusy = false;
        if (best != m_media) { m_media = best; Q_EMIT mediaChanged(); }
    };
    for (const QString &name : names) {
        if (!m_identity.contains(name)) {       // fetched once per player; until then the bus name's last part
            m_identity[name] = name.section('.', 3);
            QDBusMessage g = QDBusMessage::createMethodCall(name, "/org/mpris/MediaPlayer2", "org.freedesktop.DBus.Properties", "Get");
            g << "org.mpris.MediaPlayer2" << "Identity";
            auto *iw = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(g, 1000), this);
            connect(iw, &QDBusPendingCallWatcher::finished, this, [this, name](QDBusPendingCallWatcher *iw) {
                const QDBusPendingReply<QVariant> r = *iw; iw->deleteLater();
                if (r.isValid() && !r.value().toString().isEmpty()) m_identity[name] = r.value().toString();
            });
        }
        QDBusMessage msg = QDBusMessage::createMethodCall(name, "/org/mpris/MediaPlayer2", "org.freedesktop.DBus.Properties", "GetAll");
        msg << "org.mpris.MediaPlayer2.Player";
        auto *w = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(msg, 1000), this);
        connect(w, &QDBusPendingCallWatcher::finished, this, [this, name, acc, finish](QDBusPendingCallWatcher *w) {
            const QDBusPendingReply<QVariantMap> all = *w; w->deleteLater();
            if (all.isValid()) {
                const QVariantMap pl = all.value();
                QVariantMap meta;
                const QVariant mv = pl.value("Metadata");
                if (mv.canConvert<QDBusArgument>()) mv.value<QDBusArgument>() >> meta;
                else meta = mv.toMap();
                QVariantMap m;
                m["service"] = name;
                m["status"] = pl.value("PlaybackStatus").toString();
                m["title"] = meta.value("xesam:title").toString();
                m["artist"] = meta.value("xesam:artist").toStringList().join(", ");
                m["identity"] = m_identity.value(name);
                if (!m["title"].toString().isEmpty() || m["status"].toString() == "Playing") acc->found << m;
            }
            finish();
        });
    }
}

void Backend::mediaControl(const QString &method)
{
    const QString service = m_media.value("service").toString();
    if (service.isEmpty()) return;
    QDBusInterface player(service, "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player");
    player.call(QDBus::NoBlock, method);
    QTimer::singleShot(400, this, &Backend::pollMedia);
}

// ---------------------------------------------------------------- Wi-Fi / Bluetooth lists

static QStringList splitNm(const QString &line)
{
    // nmcli -t escapes ':' inside values as '\:'
    QStringList out; QString cur;
    for (int i = 0; i < line.size(); ++i) {
        if (line[i] == '\\' && i + 1 < line.size()) { cur += line[++i]; continue; }
        if (line[i] == ':') { out << cur; cur.clear(); continue; }
        cur += line[i];
    }
    out << cur;
    return out;
}

void Backend::scanWifi()
{
    // rescan first (takes ~2 s), then list; known = a saved profile whose 802-11-wireless.ssid matches
    // (profile NAMEs can differ from the SSID), connected later by UUID
    if (!m_scanning) { m_scanning = true; Q_EMIT scanningChanged(); }
    runCapture("nmcli dev wifi rescan >/dev/null 2>&1; sleep 2; nmcli -t -f IN-USE,SSID,SIGNAL,SECURITY dev wifi list 2>/dev/null; echo ===KNOWN;"
               " nmcli -t -f UUID,TYPE connection show 2>/dev/null | grep ':802-11-wireless$' | cut -d: -f1 |"
               " while read u; do printf '%s:%s\\n' \"$u\" \"$(nmcli -g 802-11-wireless.ssid connection show \"$u\" 2>/dev/null)\"; done",
               [this](const QString &out) {
        const QStringList parts = out.split("===KNOWN");
        QHash<QString, QString> known;      // ssid -> uuid
        if (parts.size() > 1) for (const QString &l : parts[1].split('\n')) {
            const int i = l.indexOf(':');
            if (i > 0) { const QString ssid = splitNm(l.mid(i + 1).trimmed()).join(':'); if (!ssid.isEmpty()) known[ssid] = l.left(i); }
        }
        QVariantList list; QSet<QString> seen;
        for (const QString &l : parts[0].split('\n')) {
            const QStringList f = splitNm(l);
            if (f.size() < 4 || f[1].isEmpty() || seen.contains(f[1])) continue;
            seen << f[1];
            QVariantMap e;
            e["ssid"] = f[1]; e["inUse"] = f[0] == "*"; e["signal"] = f[2].toInt();
            e["secured"] = !f[3].trimmed().isEmpty(); e["known"] = known.contains(f[1]); e["uuid"] = known.value(f[1]);
            list << e;
        }
        std::sort(list.begin(), list.end(), [](const QVariant &a, const QVariant &b) {
            const QVariantMap x = a.toMap(), y = b.toMap();
            if (x["inUse"] != y["inUse"]) return x["inUse"].toBool();
            if (x["known"] != y["known"]) return x["known"].toBool();
            return x["signal"].toInt() > y["signal"].toInt();
        });
        m_wifi = list; Q_EMIT wifiListChanged();
        m_scanning = false; Q_EMIT scanningChanged();
    });
}

void Backend::wifiConnect(const QString &ssid, const QString &uuid, bool secured)
{
    const QString q = QString(ssid).replace("'", "'\\''");
    if (!uuid.isEmpty()) act("wifi-connect", QString("nmcli con up uuid '%1'").arg(uuid));
    else if (!secured) act("wifi-connect", QString("nmcli dev wifi connect '%1'").arg(q));
    else {
        // a new secured network needs its password typed: the settings window must not open under our
        // full-screen overlay, so the sheet goes away first (like every other app launch)
        hide();
        launch("systemsettings kcm_networkmanagement");
        return;
    }
    QTimer::singleShot(3000, this, &Backend::scanWifi);
}

void Backend::scanBt()
{
    runCapture("bluetoothctl devices 2>/dev/null; echo ===CONN; bluetoothctl devices Connected 2>/dev/null",
               [this](const QString &out) {
        const QStringList parts = out.split("===CONN");
        QSet<QString> conn;
        if (parts.size() > 1) for (const QString &l : parts[1].split('\n')) { const QStringList f = l.split(' '); if (f.size() >= 2) conn << f[1]; }
        QVariantList list;
        for (const QString &l : parts[0].split('\n')) {
            const QStringList f = l.split(' ');
            if (f.size() < 3 || f[0] != "Device") continue;
            QVariantMap e;
            e["mac"] = f[1]; e["name"] = f.mid(2).join(' '); e["connected"] = conn.contains(f[1]);
            list << e;
        }
        std::sort(list.begin(), list.end(), [](const QVariant &a, const QVariant &b) {
            return a.toMap()["connected"].toBool() && !b.toMap()["connected"].toBool();
        });
        m_bt = list; Q_EMIT btListChanged();
    });
}

void Backend::btToggle(const QString &mac, bool connected)
{
    act("bt-dev", QString("bluetoothctl %1 %2").arg(connected ? "disconnect" : "connect", mac));
    QTimer::singleShot(2500, this, &Backend::scanBt);
}
