// D-Bus face of y700-shellbar (fyi.y700.Shellbar /Shellbar) and the window plumbing the QML needs.
//   reveal()      the y700-taskswitcher effect: a short slow swipe up from the bottom edge in an app (dock mode B+)
//   hideDock()    put a revealed dock away again
//   toggleDoNotDisturb()   do not disturb on / off (qml/Banners.qml); the Magic Keyboard's fn+F6
// The status bar's pull-down is forwarded to the control centre (fyi.y700.ControlCenter pullBegin/pullMove/pullEnd);
// its openChanged signal is mirrored in ccOpen so the bars ignore touches while the sheet is over them (and its
// name changing hands - a control centre that died open - resets ccOpen to false).
// KWin blur behind the dock, the banners and the app grid goes through the control centre's WlBlurWindow
// (linux/controlpanel/y700-control-center/src/wlblur.h, compiled in: CMakeLists WLBLUR_DIR), one per window - not
// KWindowEffects::enableBlurBehind, which releases the previous blur object before KWin has applied the new one and
// flickers while the region moves (README「下拉模糊闪烁」; the dock slides its region every frame as it comes up).
//   setStage(b)   the stage manager (linux/stage, KWin script y700-stage) has a group on the stage: the blurred
//                 backdrop (qml/Backdrop.qml) shows and the status bar is see-through over it. The script says it on
//                 every change it sees, so a shellbar restarted in the middle catches up at the next one.
//   holdDock(ms)  the stage manager is about to put the staged windows down for a flight (a card tapped or dropped)
//                 and brings the next ones up only as it lands: for ms no window up is not the desktop, the dock
//                 stays as it was (11-09: it slid in and out on every swap). Capped at 3 s.
//   dockApps() -> s     split screen's 「选择另一个应用」 (linux/split, KWin script y700-split): the dock's apps as JSON
//                       [{id, name, icon, wmclass}], in the dock's order
//   launchApp(s id)     ... one of them started (no activation token: the script places and focuses the new window)
//   wallpaperUrl() -> s ... the wallpaper's file:// URL (read now), "" when there is none: the picker's backdrop
#pragma once
#include <QHash>
#include <QObject>
#include <QRegion>
#include <QVariantList>

class Apps;
class QWindow;
class WlBlurWindow;

class Shell : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "fyi.y700.Shellbar")
    Q_PROPERTY(bool ccOpen READ ccOpen NOTIFY ccOpenChanged)
    Q_PROPERTY(bool stage READ stage NOTIFY stageChanged)
    Q_PROPERTY(QString wallpaper READ wallpaper NOTIFY stageChanged)
public:
    explicit Shell(QObject *parent = nullptr);
    bool ccOpen() const { return m_ccOpen; }
    bool stage() const { return m_stage; }
    QString wallpaper() const { return m_wallpaper; }   // file:// URL of the desktop's picture, read as the stage opens
    void setApps(Apps *apps) { m_apps = apps; }

public Q_SLOTS:
    Q_SCRIPTABLE void reveal() { Q_EMIT revealRequested(); }
    Q_SCRIPTABLE void hideDock() { Q_EMIT hideRequested(); }
    Q_SCRIPTABLE void setStage(bool on);
    Q_SCRIPTABLE void holdDock(int ms);
    // fn+F6 sends KEY_SLEEP; KDE's command shortcut y700-dnd-toggle.desktop calls this
    Q_SCRIPTABLE void toggleDoNotDisturb() { Q_EMIT dndToggleRequested(); }
    Q_SCRIPTABLE QString dockApps() const;
    Q_SCRIPTABLE void launchApp(const QString &id);
    Q_SCRIPTABLE QString wallpaperUrl() const;

    // QML
    // one line to stderr (the journal): QML's console.info is filtered out in the session as in the bed
    Q_INVOKABLE void log(const QString &line) { qInfo("%s", qPrintable(line)); }
    Q_INVOKABLE void pullBegin(const QString &side);   // "left" = notifications, "right" = controls
    Q_INVOKABLE void pullMove(double y);
    Q_INVOKABLE void pullEnd(double vy);
    // KWin blur behind a rounded rectangle of the window (logical px); w = 0 switches it off
    Q_INVOKABLE void setBlur(QWindow *win, int x, int y, int w, int h, int radius);
    // ... behind several rounded rectangles, rects = [{x, y, w, h}, ...] (the banners); [] switches it off
    Q_INVOKABLE void setBlurRects(QWindow *win, const QVariantList &rects, int radius);
    // the status bar over a fullscreen window: Overlay layer (true) or back to Top (qml/Main.qml barOverlay)
    Q_INVOKABLE void setOverlay(QWindow *win, bool overlay);
    // input region: touches outside fall through to whatever is below (w = 0: the whole window)
    Q_INVOKABLE void setInput(QWindow *win, int x, int y, int w, int h);
    // ... several rectangles; [] = nothing at all takes touches (not "the whole window", unlike setInput)
    Q_INVOKABLE void setInputRects(QWindow *win, const QVariantList &rects);

Q_SIGNALS:
    void revealRequested();
    void hideRequested();
    void dndToggleRequested();
    void ccOpenChanged();
    void stageChanged();
    void dockHeld(int ms);

private Q_SLOTS:
    void onCcOpen(bool open);

private:
    void ccCall(const char *method, const QVariantList &args = {});
    WlBlurWindow *blurOf(QWindow *win);
    bool m_ccOpen = false;
    bool m_stage = false;
    QString m_wallpaper;
    Apps *m_apps = nullptr;
    QHash<QWindow *, WlBlurWindow *> m_blur;       // one per window, owned by the window
};
