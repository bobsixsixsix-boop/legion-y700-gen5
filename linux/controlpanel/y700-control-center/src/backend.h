// Backend of the Y700 control centre: window show/hide (D-Bus fyi.y700.ControlCenter), the state map
// the QML reads, the shell commands behind every tile, haptics, MPRIS, Wi-Fi/Bluetooth lists.
// Everything runs as the logged-in user.
#pragma once
#include <QObject>
#include <QProcess>
#include <QTimer>
#include <QVariantMap>
#include <QVariantList>
#include <QRect>
#include <QRegion>
#include <QMap>
#include <QHash>
#include <QDateTime>
#include <QPointer>
#include <atomic>
#include <functional>
#include "fakekeys.h"
#include "wlblur.h"

class QWindow;

class Backend : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "fyi.y700.ControlCenter")
    Q_PROPERTY(bool visible READ visible NOTIFY visibleChanged)
    Q_PROPERTY(QVariantMap st READ st NOTIFY stChanged)
    Q_PROPERTY(QString busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(double brightness READ brightness NOTIFY brightnessChanged)
    Q_PROPERTY(QVariantMap media READ media NOTIFY mediaChanged)
    Q_PROPERTY(QVariantList wifiList READ wifiList NOTIFY wifiListChanged)
    Q_PROPERTY(QVariantList btList READ btList NOTIFY btListChanged)
    Q_PROPERTY(bool scanning READ scanning NOTIFY scanningChanged)
    Q_PROPERTY(QString toast READ toast NOTIFY toastChanged)
    // which half of the curtain is up: "right" = controls, "left" = notifications (vivo OriginOS: the top edge's
    // left half pulls the notification centre, the right half the control centre)
    Q_PROPERTY(QString side READ side NOTIFY sideChanged)
    // bumped whenever org.freedesktop.Notifications changes owner (plasmashell restarted, or gone in phase 3):
    // the QML rebuilds its notification model, whose watcher registration died with the old owner
    Q_PROPERTY(int notifyGen READ notifyGen NOTIFY notifyGenChanged)
public:
    explicit Backend(QObject *parent = nullptr);
    ~Backend() override;
    void setWindow(QWindow *w);
    bool visible() const { return m_visible; }
    QVariantMap st() const { return m_st; }
    QString busy() const { return m_busy; }
    double brightness() const { return m_brightness; }
    QVariantMap media() const { return m_media; }
    QVariantList wifiList() const { return m_wifi; }
    QVariantList btList() const { return m_bt; }
    bool scanning() const { return m_scanning; }
    QString toast() const { return m_toast; }
    QString side() const { return m_side; }
    int notifyGen() const { return m_notifyGen; }

public Q_SLOTS:
    // D-Bus (fyi.y700.ControlCenter /ControlCenter): the KWin touch-edge script calls toggle()
    Q_SCRIPTABLE void toggle() { m_visible ? hide() : show(); }
    Q_SCRIPTABLE void show();
    Q_SCRIPTABLE void showSide(const QString &side) { setSide(side); show(); }   // "left" | "right"
    Q_SCRIPTABLE void hide();
    Q_SCRIPTABLE void haptic();                        // one short tick on both motors
    Q_SCRIPTABLE void stopRecording();                 // = a click on Spectacle's tray icon (its only "stop"); D-Bus for tests
    // the left/right edge swipe (KWin script y700-edge): the back key for the active window's app
    Q_SCRIPTABLE void back(const QString &resourceClass, bool fullScreen);
    // the pull-down strip y700-cc-pull: the finger's screen y while it pulls, its speed (px/s) at the end
    Q_SCRIPTABLE void pullBegin() { pullBeginSide(QStringLiteral("right")); }
    // y700-shellbar (linux/dock): the same with the half of the top edge the finger started on
    Q_SCRIPTABLE void pullBeginSide(const QString &side) { setSide(side); Q_EMIT pulled(0, 0.0); show(); }   // pulling first: show() must not animate it
    Q_SCRIPTABLE void pullMove(double y) { Q_EMIT pulled(1, y); }
    Q_SCRIPTABLE void pullEnd(double vy) { trace("pullEnd"); Q_EMIT pulled(2, vy); }
    // QML
    Q_INVOKABLE void hideDone();                       // slide-out animation finished -> unmap the window
    Q_INVOKABLE void act(const QString &name, const QString &cmd);   // run a shell command, then refresh
    Q_INVOKABLE void launch(const QString &cmd);       // detached (terminal, recorder)
    Q_INVOKABLE void setBrightness(double frac);
    Q_INVOKABLE void setVolume(double frac);
    // blur behind a rectangle of the window; radius rounds its corners (0: the curtain, straight edges)
    Q_INVOKABLE void setBlur(int x, int y, int w, int h, int radius = 0);
    Q_INVOKABLE void setSide(const QString &side);
    Q_INVOKABLE void refresh();
    Q_INVOKABLE void setLocal(const QString &key, const QVariant &v);   // optimistic UI state until the next refresh
    Q_INVOKABLE void mediaControl(const QString &method);               // PlayPause | Next | Previous
    Q_INVOKABLE void scanWifi();
    Q_INVOKABLE void scanBt();
    Q_INVOKABLE void wifiConnect(const QString &ssid, const QString &uuid, bool secured);   // uuid: saved profile, else ""
    Q_INVOKABLE void startRecording();                  // Spectacle screen recording; st.recording follows its signals
    Q_INVOKABLE void tsLogin();                         // `tailscale login`: open its URL as soon as it is printed
    // not toast(): a Q_INVOKABLE named like the toast property is shadowed by it in QML ("Property 'toast' ... is not a
    // function", reproduced on the tablet 10-19), so the recording hint on the screenshot tile never showed
    Q_INVOKABLE void notify(const QString &text) { showToast(text); }
    Q_INVOKABLE void btToggle(const QString &mac, bool connected);
    void onBrightnessChanged(const QString &display, int value, const QString &client, const QString &ctx);   // PowerDevil signal
    void onRecordingDone(const QString &);              // Spectacle RecordingTaken / RecordingFailed

protected:
    bool eventFilter(QObject *o, QEvent *e) override;   // on the window: hands the blur region to KWin once per frame

Q_SIGNALS:
    Q_SCRIPTABLE void openChanged(bool open);           // D-Bus, for y700-cc-pull (unmaps itself while open)
    void pulled(int phase, double value);              // QML: 0 begin, 1 move (y), 2 end (velocity)
    void visibleChanged();
    void stChanged();
    void busyChanged();
    void brightnessChanged();
    void mediaChanged();
    void wifiListChanged();
    void btListChanged();
    void scanningChanged();
    void toastChanged();
    void sideChanged();
    void notifyGenChanged();
    void actionFinished(const QString &name, bool ok);   // every act() command: QML uses it to end the touch shield

private:
    void parseStatus(const QString &out);
    void readBrightness();
    void readVolume();                        // one wpctl, ~15 ms: at show() and on sink events while open
    void watchVolume(bool on);                // pactl subscribe while the curtain is up (sink events -> readVolume)
    bool volumeOurs(qint64 since) const;      // a drag owns the level: a sample taken since `since` (ms) must not undo it
    void flushBrightness();
    void flushVolume();
    void startAction(const QString &name, const QString &cmd);
    void pollMedia();
    void openHaptics();
    void runCapture(const QString &cmd, std::function<void(const QString &)> done);
    void showToast(const QString &text);
    void mediaFetch(const QStringList &names);
    void attachBlurSurface();                 // the window's wl_surface to m_blur, and the region with it
    // Y700_CC_TRACE=1: one stderr line per blur hand-over (apply / done / surface), pull end and haptic, with the
    // frames swapped since the last one (tests/blur-flicker.sh lines them up with its frames; README「下拉模糊闪烁」)
    void trace(const char *what, const char *detail = "");

    QWindow *m_win = nullptr;
    bool m_visible = false;
    QVariantMap m_st, m_media;
    QVariantList m_wifi, m_bt;
    QString m_busy, m_toast;
    QString m_side = QStringLiteral("right");
    int m_notifyGen = 0;
    bool m_scanning = false, m_mediaBusy = false;
    QHash<QString, QString> m_identity;      // MPRIS service -> Identity (fetched once per player)
    double m_brightness = 0;
    int m_brightnessMax = 0;
    double m_pendingBrightness = -1, m_pendingVolume = -1;
    qint64 m_lastBrightnessWrite = 0;      // ms; our own writes echo back as BrightnessChanged
    qint64 m_lastVolumeWrite = 0;          // ms; a status poll sampled before this must not undo the drag
    qint64 m_queryStart = 0;               // ms; when the running status pipeline was started (older writes are in it)
    qint64 m_volumeAt = 0;                 // ms; when the volume sample on screen was started (readVolume or the
                                           // pipeline): an older one landing later is not applied
    qint64 m_recordStart = 0;              // ms; when we asked Spectacle to record
    QProcess *m_tsLogin = nullptr;
    QTimer m_poll, m_mediaPoll, m_brightnessFlush, m_volumeFlush, m_refreshDebounce, m_toastTimer;
    QTimer m_volumeEvent;                    // sink events gather here (a held volume key repeats) before one readVolume
    QProcess *m_status = nullptr;
    QProcess *m_volumeProc = nullptr;
    QProcess *m_volumeRead = nullptr;        // readVolume's wpctl
    bool m_volumeReread = false;             // a sink event came while it ran: read again after it
    QPointer<QProcess> m_volumeWatch;        // watchVolume's pactl subscribe (deletes itself once it has exited)
    QMap<QString, QProcess *> m_running;     // action name -> its process
    QMap<QString, QString> m_queued;         // action name -> newest command issued while one was running
    QMap<QString, qint64> m_lastAction;      // action name -> ms when its last command finished
    QRect m_blurRect;
    int m_blurRadius = -1;
    QRegion m_blurRegion;                    // what setBlur() asked for last
    bool m_blurDirty = false;                // ... and not yet handed to KWin (setWindow's sync lambda, eventFilter)
    bool m_blurOnSync = false;               // the window is a QQuickWindow: handed over in its beforeSynchronizing
    WlBlur m_blur;                           // the org_kde_kwin_blur objects on the window's surface (wlblur.h)
    QObject *m_blurWindow = nullptr;         // the platform window whose surfaceCreated/Destroyed are connected
    bool m_trace = false;                    // Y700_CC_TRACE
    std::atomic<unsigned> m_swaps{0};        // QQuickWindow::frameSwapped count (written on the render thread)
    std::atomic<qint64> m_swapUs{0};         // ... and when the last one was
    unsigned m_swapsSeen = 0;                // m_swaps at the last trace line
    FakeKeys m_keys;
    QList<int> m_ff;                         // force-feedback fds (aw86927-haptics, left + right)
    QList<int> m_ffId;                       // uploaded effect id per fd (-1 = none yet)
};
