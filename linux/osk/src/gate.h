// Gate: decides when the keyboard comes up, from what the y700_oskgate KWin effect reports.
//
// Owner, 2026-10-14: "only when I tap a text field, not because of which app it is" - touching
// Telegram to drag its window brought the keyboard up. fcitx5 (ShowVirtualKeyboard on focus-in) and
// the KWin launcher (Controller1.Show on input-method activation) both fire the moment a touch
// ACTIVATES a window, because the app puts its focus back into its text field; neither knows where the
// finger is. KWin does: the effect sends every touch and the text-input traffic as D-Bus signals.
//
// Measured with the virtual finger (tests/gate-*.sh, 2026-10-15):
//   - activation happens on touch DOWN: focus / im-active / vN-enabled arrive between down and up;
//   - Qt text-input-v2 clients ask to show the panel only for a tap on a text field: Telegram ~1-20 ms
//     after the lift, Kate/Konsole ~8 ms after the PRESS (and also on focus-in, i.e. on activation);
//   - v3 clients (Chrome, GTK) have no show request: they enable or commit after the lift only when the
//     tap touched a text widget (a tap elsewhere gives a disable or nothing).
// Policy: a show needs a TAP (one finger, short, small travel, not on a window frame, not on the
// keyboard / a panel, screen on) plus evidence from the tapped window:
//   during the touch: a v1/v2 show request (not when the touch also activated the window: then it may
//     be the app's focus-in, except for the tap-anywhere list: terminals/editors), or a v3 enable in an
//     already active window;
//   within 600 ms after the lift: a v1/v2 show request, a v3 commit, or a v3 enable (not after an
//     activating tap: that may be a slow focus restore).
// Everything else (focus restored by an activation, drags, chat history, title bars) shows nothing.
// The effect is enabled in kwinrc (KWin reloads it after a compositor restart) and also loaded on
// demand; when it is gone (silence where it always speaks) the keyboard falls back to the old
// focus-driven behaviour instead of never coming up.
#pragma once

#include <QElapsedTimer>
#include <QHash>
#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QPointF>
#include <QRectF>
#include <QStringList>
#include <functional>

class QTimer;

class Gate : public QObject
{
    Q_OBJECT
public:
    explicit Gate(QObject *parent = nullptr);
    bool alive() const { return m_alive; }
    QString log() const { return m_log.join(QLatin1Char('\n')); }
    void note(const QString &line);           // the keyboard's side of a decision, same log

    // a finger is down on an app window, or a tap's evidence window is still open
    bool busy() const;
    qint64 msSinceAppTouch() const { return m_clock.elapsed() - m_lastAppTouch; }
    qint64 silentMs() const { return m_clock.elapsed() - m_lastEvent; }
    QString textWid() const { return m_textWid; }          // window of the focused text-input surface
    QString confirmedWid() const { return m_confirmedWid; } // window of the last tap-confirmed show
    // the input method was activated by KWin itself (tray "show virtual keyboard", KWin's own text
    // fields): no client text-input traffic around it and no app touch. Not when KWin activated it for
    // one of its own focused items that is no text field (KWin 6.6 does that for any focused effect
    // scene: the task switcher cards; the effect reports it as "internal": "other", see oskgate.cpp).
    // A real forceActivate while such an item still has the focus is vetoed too (only the gamepad X
    // key can do that with a fullscreen effect up, and there is nothing to type into then).
    bool kwinInitiated() const;
    // the input method was activated within the last 400 ms for such a non-text KWin item: the Shows that
    // follow are for it, not for an X11 client either
    bool internalOther() const;
    void lost();                              // the effect went silent where it always speaks
    void ensureLoaded();

    // For X11 clients (Steam), which have no text-input: Osk decides from fcitx5's Show/Hide and the
    // last touch ANYWHERE - the tap rules above skip "exe|" windows, and Steam is one ("steam|": no
    // desktop file), like this keyboard and the panels.
    struct Touch {
        QString win, wid;
        qint64 downAt = -100000, upAt = -100000;   // m_clock ms; upAt < downAt: the finger is still down
        bool tap = false;                     // one finger, short, small travel, not a frame, screen on
        bool down() const { return upAt < downAt; }
    };
    Touch lastTouch() const { return m_recent.isEmpty() ? Touch() : m_recent.last(); }
    // the touch behind something that happened at t (m_clock ms): the last one pressed before it
    Touch touchBefore(qint64 t) const;
    qint64 now() const { return m_clock.elapsed(); }
    // 1: a window KWin manages (an app's toplevel or dialog), 0: not (layer-shell: this keyboard, panels,
    // the control centre, the dock), -1: KWin has not answered yet. Asked on the first touch of a window.
    int managed(const QString &wid) const { return wid.isEmpty() ? 0 : m_managed.value(wid, -1); }
    // asks KWin now: is that window still there and not minimized? (done runs in ctx's thread, later)
    void stillThere(const QString &wid, QObject *ctx, const std::function<void(bool)> &done);
    // the DPMS files screenOff() reads, under drmDir (/sys/class/drm; tests/gate-dpms-test.cpp)
    static QStringList panelDpms(const QString &drmDir);

signals:
    void showWanted(const QString &reason);
    void aliveChanged(bool alive);
    void touchEnded();                        // a finger lifted anywhere (a single tap: it is lastTouch())

private slots:
    void onEvent(const QString &json);
    void onCompositingToggled(bool on);

private:
    struct Down {
        QString win, wid;
        QPointF pos;
        qint64 at = 0;                        // m_clock ms at the press
        bool hard = false;                    // frame / multi-finger / screen off / no window: never a tap
        bool ignore = false;                  // hard, or keyboard / panel ("exe|", also X11 apps like Steam)
        bool activated = false;               // the text-input focus moved during this touch
        bool showHere = false;                // a v1/v2 show request from this window during the touch
        bool v3EnabledHere = false;           // a client enable (not KWin's focus re-send) in this window
        QRectF cursor;                        // last v3 cursor rectangle reported during the touch
    };
    struct Tap {
        bool valid = false;
        QString win, wid;
        QPointF pos;
        bool activated = false;
        qint64 at = 0;                        // m_clock ms at the lift
    };
    void setAlive(bool a);
    void lookUp(const QString &win, const QString &wid);
    void want(const QString &wid, const QString &reason);
    bool near(const QPointF &p, const QRectF &cursor) const;
    bool screenOff() const;
    static bool tapAnywhere(const QString &win);

    QHash<int, Down> m_down;
    Tap m_tap;
    QList<Touch> m_recent;                    // the last few touches anywhere, oldest first
    QHash<QString, int> m_managed;            // wid -> managed(): 1 / 0 / -1 asking
    QString m_textWid, m_confirmedWid;
    bool m_alive = false;
    bool m_checking = false;                  // an isEffectLoaded/loadEffect round trip is in flight
    bool m_loadRefused = false;               // KWin refused the plugin (rebuild after a KWin upgrade)
    QElapsedTimer m_clock;
    qint64 m_lastEvent = -100000, m_lastAppTouch = -100000, m_imActiveAt = -100000, m_clientAt = -100000;
    bool m_imInternalOther = false;           // the last im-active was for a KWin-internal non-text focus
    QTimer *m_check = nullptr;
    QStringList m_dpmsFiles;
    QStringList m_log;
};
