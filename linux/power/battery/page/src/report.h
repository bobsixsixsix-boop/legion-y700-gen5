// Backend of the battery page y700-battery-page (linux/power/battery/DESIGN.md section 6; the interface is section
// 6b.c): the context object "backend" the QML reads. Everything that is not drawing is here:
//   - the live charge and charger state, read from sysfs at start, at each window activation and on flightrec's edges;
//     never taken from the cache or the report, which are seconds to minutes old by the time they are shown (评审修订)
//   - the cache ${XDG_CACHE_HOME:-~/.cache}/y700-battery/last.json: the last good report, shown at start while a new
//     one is made, and only if it is at most 10 min old by its own "now"
//   - a failed refresh: whatever data there is (the cache or an earlier good report) is dimmed with its age
//   - a refresh: USR1 to y700-batteryd (its pid file, the comm checked) for a snapshot of this very moment, at most 1 s
//     waiting for that snapshot to reach the ledger, then y700-battery-report --json in a QProcess, killed after 20 s
//   - Y700_BATTERY_REPORT=<json file> (the test bed): that file is the report; no signal, no process, no cache
// Nothing here wakes up on its own (DESIGN.md section 6: no periodic timer). A new report when the window is activated
// again more than 2 min after the last one was started; while the window stays active, when flightrec's edge file
// (/run/y700-flightrec/edge, replaced on every DPMS and power-direction change; watched with inotify) says the screen
// came back on, or on another edge with the screen on 2 min after the last start; when a live read finds the charger
// came or went; or when the QML calls refresh(). The three QTimers below are one-shots, each started by a refresh:
// 150 ms to the skeleton, 1 s for the ledger, 20 s for the report.
#pragma once
#include <QByteArray>
#include <QElapsedTimer>
#include <QObject>
#include <QProcess>
#include <QString>
#include <QTimer>
#include <QVariantMap>

class QFileSystemWatcher;
class QJsonObject;
class QWindow;

class Backend : public QObject
{
    Q_OBJECT
    // the last good report; until there is one the cache; an empty map when there is neither
    Q_PROPERTY(QVariantMap data READ data NOTIFY dataChanged)
    // a refresh is under way: the wait for the ledger and the report's run (the skeleton must cover both)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    // loading for more than 150 ms with nothing to show: the QML draws its static skeleton
    Q_PROPERTY(bool skeleton READ skeleton NOTIFY skeletonChanged)
    // "" or why the last refresh failed: the report's own error text, 报表超时, 报表没跑起来, 报表的输出读不懂, or
    // 读不了 <file> for a fixture
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
    // how many minutes ago data's report was made, by the report's own "now" (the cache's or a fresh one's), counted
    // when read; -1 without data. Shown only with an error, so it is notified with it: every failure emits
    // errorChanged, also the same error once more, so 「x 分钟前」 is counted again (dataChanged would rebuild the page)
    Q_PROPERTY(int cacheAgeMin READ cacheAgeMin NOTIFY errorChanged)
    // there is data and the last refresh failed: dimmed, 「x 分钟前的数据」, no remaining time on line 1. Not only the
    // cache: a page left open over a good report and then a timeout is just as old (10-31 审计). A property has one
    // NOTIFY: errorChanged, which setData() also emits when new data alone flips it
    Q_PROPERTY(bool stale READ stale NOTIFY errorChanged)
    Q_PROPERTY(int livePct READ livePct NOTIFY liveChanged)              // -1: unreadable
    Q_PROPERTY(QString liveStatus READ liveStatus NOTIFY liveChanged)    // the values of the report's battery.status
    Q_PROPERTY(bool livePlugged READ livePlugged NOTIFY liveChanged)     // judged as the report's battery.plugged
    Q_PROPERTY(bool fixture READ fixture CONSTANT)                       // Y700_BATTERY_REPORT is set
    Q_PROPERTY(QString startRange READ startRange CONSTANT)              // --range, or ""
    Q_PROPERTY(QString startDetail READ startDetail CONSTANT)            // --detail, or ""
public:
    Backend(const QString &startRange, const QString &startDetail, QObject *parent = nullptr);
    ~Backend() override;
    // the live state, the cache, the first refresh: called before the QML is loaded, so its first frame has the cache
    void start();
    // the window, for its activation and flightrec's edges while it is active: the live state is read again, and a
    // refresh started if the last is 2 min old (or at once when the screen came back on)
    void setWindow(QWindow *w);

    QVariantMap data() const { return m_data; }
    bool loading() const { return m_loading; }
    bool skeleton() const { return m_skeleton; }
    QString error() const { return m_error; }
    int cacheAgeMin() const;
    bool stale() const { return !m_error.isEmpty() && !m_data.isEmpty(); }
    int livePct() const { return m_livePct; }
    QString liveStatus() const { return m_liveStatus; }
    bool livePlugged() const { return m_livePlugged; }
    bool fixture() const { return !m_fixturePath.isEmpty(); }
    QString startRange() const { return m_startRange; }
    QString startDetail() const { return m_startDetail; }

    // USR1 -> wait for the ledger -> the report (a fixture is only read again); nothing while one is under way (a
    // charger change seen meanwhile runs it once more afterwards)
    Q_INVOKABLE void refresh();
    // KDE's battery page through the launcher: it closes the open battery pages on this screen, this one included,
    // and opens KDE's in their place
    Q_INVOKABLE void openKde();
    // close the window and quit (queued: called from a QML key handler)
    Q_INVOKABLE void quit();

Q_SIGNALS:
    void dataChanged();
    void loadingChanged();
    void skeletonChanged();
    void errorChanged();
    void liveChanged();

private:
    // readLive() when the last read is over 5 s old or `live`, refresh() when the last start is over 2 min old or
    // `report`: the activation and the edges share it
    void catchUp(bool live, bool report);
    void edgeChanged(bool active);            // something changed in /run/y700-flightrec: the edge file says what
    void readLive();
    void liveFromData();                      // fixture: the live state is the file's battery block
    void setLive(int pct, const QString &status, bool plugged);
    void readCache();
    void writeCache(const QByteArray &raw);
    void loadFixture();
    bool askRecorder();                       // false: no signal sent, the report runs on the ledger as it is
    void newestPart(int *n, qint64 *size, QString *path) const;
    void ledgerMoved();
    void ledgerWaitDone();
    void runReport();
    void reportFinished(int code, QProcess::ExitStatus status);
    void reportFailedToStart();
    void endLoading();
    void setData(const QJsonObject &o);       // a report (v 1, no error key): the cache, a fresh one or a fixture
    void setError(const QString &e);
    void setLoading(bool on);
    void setSkeleton(bool on);

    const QString m_fixturePath;
    const QString m_startRange, m_startDetail;
    QVariantMap m_data;
    qint64 m_dataNow = 0;                     // m_data's report "now", epoch s
    bool m_loading = false, m_skeleton = false;
    QString m_error;
    int m_livePct = -1;
    QString m_liveStatus = QStringLiteral("unknown");
    bool m_livePlugged = false;
    QElapsedTimer m_lastStart;                // the last refresh's start (the 2 min rule)
    QElapsedTimer m_liveRead;                 // the last sysfs read (the first activation follows start() at once)
    QByteArray m_edge;                        // the flightrec edge line last read, "" when unread
    bool m_again = false;                     // the charger came or went while a refresh was under way: one more
    QTimer m_skelTimer, m_waitTimer, m_killTimer;
    QProcess *m_proc = nullptr;               // the report while it runs
    bool m_timedOut = false;
    // the wait for the recorder's snapshot: the newest part of this boot's ledger and its size before the signal
    QFileSystemWatcher *m_watch = nullptr;
    bool m_waiting = false;
    QString m_stateDir, m_boot8;
    int m_partN = -1;
    qint64 m_partSize = -1;
};
