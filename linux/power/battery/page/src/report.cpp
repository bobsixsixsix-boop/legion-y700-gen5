// The battery page's backend (report.h says what it owns; DESIGN.md 6b.c is the contract it implements).
#include "report.h"
#include <QByteArray>
#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFileSystemWatcher>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QJsonValue>
#include <QList>
#include <QMetaObject>
#include <QSaveFile>
#include <QStringList>
#include <QVariant>
#include <QWindow>
#include <cstdio>
#include <signal.h>
#include <sys/prctl.h>
#include <sys/types.h>
#include <unistd.h>

namespace {

const char *const REPORT_BIN = "/usr/local/bin/y700-battery-report";
const char *const LAUNCHER = "/usr/local/bin/y700-battery";
const char *const RECORDER_COMM = "y700-batteryd";
// the tablet's battery, the one the recorder reads (recorder/src/main.rs BAT); the report takes the same one
const char *const BATTERY = "qcom-battmgr-bat";
// flightrec's run directory: its edge file is replaced by a rename on every DPMS and power-direction change
// (flightrec/src/acc.rs write_edge), the energy file next to it is rewritten in place, which a directory watch
// does not see
const char *const FLIGHTREC_DIR = "/run/y700-flightrec";
constexpr qint64 CACHE_MAX_AGE_S = 600;      // an older cache is not shown at all (评审修订)
constexpr int SKELETON_MS = 150;              // a report that comes back sooner never shows the skeleton
constexpr int LEDGER_WAIT_MS = 1000;
constexpr int REPORT_TIMEOUT_MS = 20000;      // the report's own budget is 1.5 s on 40 days, its subprocesses 5 s each
constexpr qint64 REACTIVATE_MS = 120000;
// the window's first activation comes right after start(): no second firmware round trip for the same numbers
constexpr qint64 LIVE_FRESH_MS = 5000;

// $VAR when it is an absolute path, else ~/<underHome>: the XDG base directory rule (a relative value is ignored), the
// one y700-batteryd, refresh-auto and the report follow too, so all of them find the same directories
QString xdgDir(const char *var, const char *underHome)
{
    const QString v = qEnvironmentVariable(var);
    if (v.startsWith(QLatin1Char('/'))) return v;
    return QDir::homePath() + QLatin1Char('/') + QLatin1String(underHome);
}

QString runtimeDir()
{
    const QString v = qEnvironmentVariable("XDG_RUNTIME_DIR");
    return v.startsWith(QLatin1Char('/')) ? v : QStringLiteral("/run/user/%1").arg(getuid());
}

QString cachePath()
{
    return xdgDir("XDG_CACHE_HOME", ".cache") + QLatin1String("/y700-battery/last.json");
}

// a small sysfs or /proc file, whitespace trimmed; empty when it cannot be read
QByteArray readSmall(const QString &path)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return {};
    return f.read(4096).trimmed();
}

// sysfs status -> the report's battery.status: lower case, spaces to underscores ("Not charging" -> not_charging),
// anything else unknown
QString statusName(const QString &raw)
{
    const QString s = raw.trimmed().toLower().replace(QLatin1Char(' '), QLatin1Char('_'));
    static const QStringList known = {QStringLiteral("charging"), QStringLiteral("discharging"), QStringLiteral("full"),
                                      QStringLiteral("not_charging"), QStringLiteral("unknown")};
    return known.contains(s) ? s : QStringLiteral("unknown");
}

// on the charger whatever the online flags say: held at the limit and bypass read Not charging, a full battery Full
// (the control centre's pill judges it the same way, backend.cpp parseStatus)
bool pluggedStatus(const QString &s)
{
    return s == QLatin1String("charging") || s == QLatin1String("full") || s == QLatin1String("not_charging");
}

// the error document's text ({"v":1,"error":"<中文原因>"}); one that is not a string still counts as unreadable
QString errorText(const QJsonObject &o)
{
    const QString t = o.value(QLatin1String("error")).toString();
    return t.isEmpty() ? QStringLiteral("报表的输出读不懂") : t;
}

// flightrec's edge line, "v1 t=7341.9 dpms=Off pw=dis" (flightrec/src/acc.rs); empty when it cannot be read
QByteArray readEdge()
{
    return readSmall(QString::fromLatin1(FLIGHTREC_DIR) + QLatin1String("/edge"));
}

// one field of an edge line: edgeField(line, "dpms") is "Off" above; empty when the line is not v1 or lacks it
QByteArray edgeField(const QByteArray &line, const char *key)
{
    const QList<QByteArray> f = line.split(' ');
    if (f.constFirst() != "v1") return {};
    const QByteArray pre = QByteArray(key) + '=';
    for (const QByteArray &kv : f) {
        if (kv.startsWith(pre)) return kv.mid(pre.size());
    }
    return {};
}

} // namespace

Backend::Backend(const QString &startRange, const QString &startDetail, QObject *parent)
    : QObject(parent), m_fixturePath(qEnvironmentVariable("Y700_BATTERY_REPORT")), m_startRange(startRange),
      m_startDetail(startDetail)
{
    m_skelTimer.setSingleShot(true);
    m_skelTimer.setInterval(SKELETON_MS);
    connect(&m_skelTimer, &QTimer::timeout, this, [this] {
        if (m_loading && m_data.isEmpty()) setSkeleton(true);
    });
    m_waitTimer.setSingleShot(true);
    m_waitTimer.setInterval(LEDGER_WAIT_MS);
    connect(&m_waitTimer, &QTimer::timeout, this, &Backend::ledgerWaitDone);
    m_killTimer.setSingleShot(true);
    m_killTimer.setInterval(REPORT_TIMEOUT_MS);
    connect(&m_killTimer, &QTimer::timeout, this, [this] {
        if (!m_proc) return;
        m_timedOut = true;
        m_proc->kill();          // finished() follows, with CrashExit
    });
}

Backend::~Backend()
{
    // quitting while the report runs: killed, not waited for (QProcess's own destructor would warn and wait)
    if (m_proc) {
        m_proc->disconnect(this);
        m_proc->kill();
        m_proc->waitForFinished(1000);
    }
}

void Backend::start()
{
    if (fixture()) {
        refresh();               // reads the file; the live state comes from it
        return;
    }
    readLive();
    readCache();
    refresh();
}

void Backend::setWindow(QWindow *w)
{
    connect(w, &QWindow::activeChanged, this, [this, w] {
        if (w->isActive()) catchUp(false, false);
    });
    // While the window stays active nothing activates it again: KWin keeps it active through DPMS off and on, and
    // there is no lock screen to come back from (熄屏不锁屏). flightrec replaces its edge file when the screen goes off
    // or on and when the power direction turns, so its directory is watched (inotify) for the window's life. No
    // flightrec directory, or a fixture: no watch, the activations alone, as before.
    if (fixture() || !QFileInfo(QString::fromLatin1(FLIGHTREC_DIR)).isDir()) return;
    m_edge = readEdge();
    auto *edges = new QFileSystemWatcher(this);
    edges->addPath(QString::fromLatin1(FLIGHTREC_DIR));
    // the window as the context: no call once it is gone
    connect(edges, &QFileSystemWatcher::directoryChanged, w, [this, w] { edgeChanged(w->isActive()); });
}

void Backend::catchUp(bool live, bool report)
{
    if (live || !m_liveRead.isValid() || m_liveRead.elapsed() > LIVE_FRESH_MS) readLive();
    // counted from the last start, not the last result: a report that keeps failing is not re-run at every touch
    if (report || !m_lastStart.isValid() || m_lastStart.elapsed() > REACTIVATE_MS) refresh();
}

// Only a new edge line counts: one edge can come as two changes (edge.tmp made, then renamed over edge), and the
// directory holds other files. Nothing while the edge says the screen is off: nobody reads the page, and the edge that
// turns it back on catches up at once. Any other new edge (flightrec restarted, say) falls to the 5 s and 2 min rules.
// A new pw only forces a live read: the direction also turns under load on a weak charger (the report's own run is
// such a load, so a refresh on every turn could feed itself), while readLive() refreshes on a real plug change.
void Backend::edgeChanged(bool active)
{
    const QByteArray line = readEdge();
    if (line == m_edge) return;
    const QByteArray dpms = edgeField(line, "dpms"), pw = edgeField(line, "pw");
    const QByteArray wasDpms = edgeField(m_edge, "dpms"), wasPw = edgeField(m_edge, "pw");
    m_edge = line;
    if (!active || dpms == "Off") return;
    const bool screenOn = dpms == "On" && wasDpms != "On";
    const bool turned = !pw.isEmpty() && !wasPw.isEmpty() && pw != wasPw;
    catchUp(turned, screenOn);
}

int Backend::cacheAgeMin() const
{
    if (m_data.isEmpty() || m_dataNow <= 0) return -1;
    return int(qMax<qint64>(0, QDateTime::currentSecsSinceEpoch() - m_dataNow) / 60);
}

// ---------------------------------------------------------------- the live battery state

// The battery is the report's (sources.py _live_battery, the same rule): supplies whose scope reads Device are left
// out entirely - a Bluetooth controller's or mouse's battery (hid-*, hidpp_battery_*, ps-controller-battery-*) sorts
// before qcom-battmgr-bat and has online 1 for as long as it is connected; a missing scope counts as System. Of the
// rest, qcom-battmgr-bat when it is there, else the first supply of type Battery by name, gives capacity and status;
// the ones not of type Battery give online. Each read here is a firmware round trip on this battery driver
// (qcom-battmgr): only at start, at activation and on flightrec's edges. charge_counter and power_now are not read
// (DESIGN.md section 10: the first is no coulomb counter).
void Backend::readLive()
{
    if (fixture()) {
        liveFromData();
        return;
    }
    const bool before = m_liveRead.isValid();
    m_liveRead.start();
    int pct = -1;
    QString status = QStringLiteral("unknown");
    QString battery;
    bool online = false;
    const QDir ps(QStringLiteral("/sys/class/power_supply"));
    // the entries are symlinks to the devices' directories; QDir::Dirs lists them by their targets
    const QStringList names = ps.entryList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name);
    for (const QString &name : names) {
        if (name == QLatin1String(BATTERY)) {
            battery = name;
            continue;
        }
        const QString base = ps.absoluteFilePath(name) + QLatin1Char('/');
        if (readSmall(base + QLatin1String("scope")) == "Device") continue;
        if (readSmall(base + QLatin1String("type")) == "Battery") {
            if (battery.isEmpty()) battery = name;
        } else if (readSmall(base + QLatin1String("online")) == "1") {
            online = true;
        }
    }
    if (!battery.isEmpty()) {
        const QString base = ps.absoluteFilePath(battery) + QLatin1Char('/');
        bool ok = false;
        const int c = readSmall(base + QLatin1String("capacity")).toInt(&ok);
        if (ok && c >= 0 && c <= 100) pct = c;
        status = statusName(QString::fromLatin1(readSmall(base + QLatin1String("status"))));
    }
    const bool plugged = online || pluggedStatus(status);
    const bool turned = before && plugged != m_livePlugged;
    setLive(pct, status, plugged);
    // the charger came or went since the last read: the report's charger band and its 「正在充电」 banner now tell the
    // other story than line 1 (a report under way may have started before the change: it runs once more after it)
    if (turned && !m_data.isEmpty()) {
        if (m_proc || m_waiting)
            m_again = true;
        else
            refresh();
    }
}

void Backend::liveFromData()
{
    const QVariantMap b = m_data.value(QStringLiteral("battery")).toMap();
    const QVariant p = b.value(QStringLiteral("pct"));
    bool ok = false;
    int pct = p.toInt(&ok);
    if (!ok || p.isNull() || pct < 0 || pct > 100) pct = -1;     // JSON null arrives as a null QVariant
    const QString status = statusName(b.value(QStringLiteral("status")).toString());
    setLive(pct, status, b.value(QStringLiteral("plugged")).toBool() || pluggedStatus(status));
}

void Backend::setLive(int pct, const QString &status, bool plugged)
{
    if (pct == m_livePct && status == m_liveStatus && plugged == m_livePlugged) return;
    m_livePct = pct;
    m_liveStatus = status;
    m_livePlugged = plugged;
    Q_EMIT liveChanged();
}

// ---------------------------------------------------------------- cache and fixture

// The age is the report's own "now", not the file's mtime: the file can be touched by a copy, and before chrony has
// set the clock the mtime says 1970. A cache from the future (the clock was stepped back) is not shown either.
void Backend::readCache()
{
    QFile f(cachePath());
    if (!f.open(QIODevice::ReadOnly)) return;
    const QJsonDocument doc = QJsonDocument::fromJson(f.readAll());
    if (!doc.isObject()) return;
    const QJsonObject o = doc.object();
    const QJsonValue now = o.value(QLatin1String("now"));
    if (o.contains(QLatin1String("error")) || o.value(QLatin1String("v")).toInteger() != 1 || !now.isDouble()) return;
    const qint64 t = now.toInteger();
    const qint64 age = QDateTime::currentSecsSinceEpoch() - t;
    if (t <= 0 || age < 0 || age > CACHE_MAX_AGE_S) return;
    setData(o);
}

// the report's stdout as it came (one JSON object), replaced as a whole: QSaveFile writes a temporary file and renames
// it, so a page killed mid-write (the launcher closes an open page) leaves the old cache, never half of a new one
void Backend::writeCache(const QByteArray &raw)
{
    if (fixture()) return;       // the test bed's data must never become the owner's cache
    const QString path = cachePath();
    if (!QDir().mkpath(QFileInfo(path).absolutePath())) {
        fprintf(stderr, "y700-battery-page: cannot make the directory of %s\n", qPrintable(path));
        return;
    }
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly) || f.write(raw) != raw.size() || !f.commit())
        fprintf(stderr, "y700-battery-page: %s not written: %s\n", qPrintable(path), qPrintable(f.errorString()));
}

// Y700_BATTERY_REPORT: the file stands for the report's stdout. An error document in it is shown like the report's,
// so the bed can show the error state too.
void Backend::loadFixture()
{
    QByteArray raw;
    bool read = false;
    {
        QFile f(m_fixturePath);
        if (f.open(QIODevice::ReadOnly)) {
            raw = f.readAll();
            read = true;
        }
    }
    QJsonParseError pe{};
    const QJsonDocument doc = QJsonDocument::fromJson(raw, &pe);
    if (!read || pe.error != QJsonParseError::NoError || !doc.isObject()) {
        setError(QStringLiteral("读不了 ") + m_fixturePath);
        return;
    }
    const QJsonObject o = doc.object();
    if (o.contains(QLatin1String("error"))) {
        setError(errorText(o));
        return;
    }
    setData(o);
    setError(QString());
    liveFromData();
}

// ---------------------------------------------------------------- refresh: recorder -> ledger -> report

void Backend::refresh()
{
    if (fixture()) {
        m_lastStart.start();
        loadFixture();
        return;
    }
    if (m_proc || m_waiting) return;
    m_lastStart.start();
    setLoading(true);
    m_skelTimer.start();
    if (!askRecorder()) runReport();
}

// USR1 asks y700-batteryd for a snapshot now (it answers one per 10 s), so the report sees the last minutes too and
// not only the ledger's last 5 min (screen on) or 30 min (off) snapshot. Not sent when the pid file is missing or
// names another program (a stale file after a crash: the pid may be anything by now) - the report then runs at once
// on the ledger as it is.
bool Backend::askRecorder()
{
    bool ok = false;
    const qint64 pid = readSmall(runtimeDir() + QLatin1String("/y700-battery/pid")).toLongLong(&ok);
    if (!ok || pid <= 1) return false;
    if (readSmall(QStringLiteral("/proc/%1/comm").arg(pid)) != RECORDER_COMM) return false;
    m_stateDir = xdgDir("XDG_STATE_HOME", ".local/state") + QLatin1String("/y700-battery");
    // the ledger's boot8 (recorder/src/main.rs): the boot id's first 8 characters, which hold no dash
    m_boot8 = QString::fromLatin1(readSmall(QStringLiteral("/proc/sys/kernel/random/boot_id")))
                  .remove(QLatin1Char('-'))
                  .left(8);
    QString path;
    newestPart(&m_partN, &m_partSize, &path);
    // watched before the signal, so a snapshot written at once is not missed: the part for its growth, the directory
    // for a new part (the recorder starts one at 4 MiB). Inotify underneath; the watcher lives only for this wait.
    m_watch = new QFileSystemWatcher(this);
    connect(m_watch, &QFileSystemWatcher::fileChanged, this, &Backend::ledgerMoved);
    connect(m_watch, &QFileSystemWatcher::directoryChanged, this, &Backend::ledgerMoved);
    if (QFileInfo(m_stateDir).isDir()) m_watch->addPath(m_stateDir);
    if (!path.isEmpty()) m_watch->addPath(path);
    if (::kill(pid_t(pid), SIGUSR1) != 0) {
        delete m_watch;
        m_watch = nullptr;
        return false;
    }
    m_waiting = true;
    m_waitTimer.start();
    return true;
}

// The part of this boot's ledger the recorder writes now, the highest-numbered: b-<boot8>.jsonl is part 0,
// b-<boot8>.<n>.jsonl part n (recorder/src/ledger.rs part_name). n = -1 when this boot has none yet.
void Backend::newestPart(int *n, qint64 *size, QString *path) const
{
    *n = -1;
    *size = -1;
    path->clear();
    if (m_boot8.isEmpty()) return;
    const QString pre = QLatin1String("b-") + m_boot8 + QLatin1Char('.');
    const QFileInfoList parts = QDir(m_stateDir).entryInfoList({pre + QLatin1String("*jsonl")}, QDir::Files);
    for (const QFileInfo &fi : parts) {
        const QString rest = fi.fileName().mid(pre.size());
        int k = -1;
        if (rest == QLatin1String("jsonl")) {
            k = 0;
        } else if (rest.endsWith(QLatin1String(".jsonl"))) {
            bool ok = false;
            const uint v = rest.chopped(6).toUInt(&ok);
            if (ok && v < 1000000) k = int(v);
        }
        if (k > *n) {
            *n = k;
            *size = fi.size();
            *path = fi.absoluteFilePath();
        }
    }
}

// A snapshot is one write() of its whole group of lines (recorder/src/main.rs commit), so the first growth means the
// S line is complete. A new part shows in the directory before its first group is written into it: that part is
// watched in turn.
void Backend::ledgerMoved()
{
    if (!m_waiting) return;
    int n = -1;
    qint64 size = -1;
    QString path;
    newestPart(&n, &size, &path);
    if (n > m_partN && size <= 0) {
        if (m_watch && !path.isEmpty()) m_watch->addPath(path);
        return;
    }
    if (n > m_partN || (n == m_partN && size > m_partSize)) ledgerWaitDone();
}

// the snapshot arrived, or 1 s passed (USR1 within 10 s of the last one is not answered: reopening the page soon
// waits the whole second, which is accepted in 6b.c)
void Backend::ledgerWaitDone()
{
    if (!m_waiting) return;
    m_waiting = false;
    m_waitTimer.stop();
    if (m_watch) {
        m_watch->deleteLater();  // possibly inside its own signal
        m_watch = nullptr;
    }
    runReport();
}

void Backend::runReport()
{
    auto *p = new QProcess(this);
    m_proc = p;
    m_timedOut = false;
    // stdout is the JSON; a traceback goes where ours goes. The environment is passed on as it is: the report finds
    // the ledger, the runtime directory and the time zone the way we do.
    p->setProcessChannelMode(QProcess::ForwardedErrorChannel);
    p->setStandardInputFile(QProcess::nullDevice());
    // The report dies with the page: the launcher closes an open page with SIGTERM, which ends it without ~Backend.
    // Runs in the child between fork and exec; the getppid check covers a page that died before the prctl. The death
    // signal survives the exec (python3 is not setuid) and follows the thread that forked, Qt's main thread here.
    const pid_t page = ::getpid();
    p->setChildProcessModifier([page] {
        ::prctl(PR_SET_PDEATHSIG, SIGKILL);
        if (::getppid() != page) ::_exit(1);
    });
    connect(p, &QProcess::finished, this, [this, p](int code, QProcess::ExitStatus status) {
        if (p == m_proc) reportFinished(code, status);
    });
    // FailedToStart is the one error not followed by finished()
    connect(p, &QProcess::errorOccurred, this, [this, p](QProcess::ProcessError e) {
        if (e == QProcess::FailedToStart && p == m_proc) reportFailedToStart();
    });
    m_killTimer.start();
    p->start(QString::fromLatin1(REPORT_BIN), {QStringLiteral("--json")});
}

void Backend::reportFinished(int code, QProcess::ExitStatus status)
{
    QProcess *p = m_proc;
    m_proc = nullptr;
    m_killTimer.stop();
    const QByteArray out = p->readAllStandardOutput();
    p->deleteLater();
    QJsonParseError pe{};
    const QJsonDocument doc = QJsonDocument::fromJson(out, &pe);
    const bool object = pe.error == QJsonParseError::NoError && doc.isObject();
    const QJsonObject o = doc.object();
    if (m_timedOut) {
        setError(QStringLiteral("报表超时"));
    } else if (object && o.contains(QLatin1String("error"))) {
        // the report's error document ({"v":1,"error":...}, exit 2): its reason is the page's error line
        setError(errorText(o));
    } else if (object && status == QProcess::NormalExit && code == 0 && o.value(QLatin1String("v")).toInteger() == 1) {
        setData(o);
        setError(QString());
        writeCache(out);
    } else {
        // a crash, an exit without the error document, or a version this page does not read
        setError(QStringLiteral("报表的输出读不懂"));
    }
    endLoading();
}

void Backend::reportFailedToStart()
{
    QProcess *p = m_proc;
    m_proc = nullptr;
    m_killTimer.stop();
    fprintf(stderr, "y700-battery-page: %s: %s\n", REPORT_BIN, qPrintable(p->errorString()));
    p->deleteLater();
    setError(QStringLiteral("报表没跑起来"));
    endLoading();
}

void Backend::endLoading()
{
    m_skelTimer.stop();
    setSkeleton(false);
    setLoading(false);
    // the charger came or went while this one was under way (readLive)
    if (m_again) {
        m_again = false;
        refresh();
    }
}

// ---------------------------------------------------------------- QML calls

// The launcher closes the battery page open on this screen - this one too - and opens KDE's in its place: one battery
// page per screen, whichever kind (../y700-battery says why).
void Backend::openKde()
{
    if (!QProcess::startDetached(QString::fromLatin1(LAUNCHER), {QStringLiteral("--kde")}))
        fprintf(stderr, "y700-battery-page: %s --kde did not start\n", LAUNCHER);
}

void Backend::quit()
{
    // queued: the key handler that asks for it is still on the stack, inside the window about to close
    QMetaObject::invokeMethod(QCoreApplication::instance(), [] { QCoreApplication::quit(); }, Qt::QueuedConnection);
}

// ---------------------------------------------------------------- property setters

void Backend::setData(const QJsonObject &o)
{
    const bool wasStale = stale();
    m_data = o.toVariantMap();
    m_dataNow = o.value(QLatin1String("now")).toInteger();
    Q_EMIT dataChanged();
    if (stale() != wasStale) Q_EMIT errorChanged();   // stale's NOTIFY
    if (!m_data.isEmpty()) setSkeleton(false);
}

// A failure notifies even when its text is the last one's: stale and cacheAgeMin hang on errorChanged, and a second
// 报表超时 an hour later must show the age of now, not of the first one
void Backend::setError(const QString &e)
{
    if (e.isEmpty() && m_error.isEmpty()) return;
    m_error = e;
    Q_EMIT errorChanged();
}

void Backend::setLoading(bool on)
{
    if (on == m_loading) return;
    m_loading = on;
    Q_EMIT loadingChanged();
}

void Backend::setSkeleton(bool on)
{
    if (on == m_skeleton) return;
    m_skeleton = on;
    Q_EMIT skeletonChanged();
}
