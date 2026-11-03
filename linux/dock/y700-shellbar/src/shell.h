// D-Bus face of y700-shellbar (fyi.y700.Shellbar /Shellbar) and the window plumbing the QML needs.
//   reveal()      the y700-taskswitcher effect: a short slow swipe up from the bottom edge in an app (dock mode B+)
//   hideDock()    put a revealed dock away again
// The status bar's pull-down is forwarded to the control centre (fyi.y700.ControlCenter pullBegin/pullMove/pullEnd);
// its openChanged signal is mirrored in ccOpen so the bars ignore touches while the sheet is over them (and its
// name changing hands - a control centre that died open - resets ccOpen to false).
// KWin blur behind the dock, the banners and the app grid goes through the control centre's WlBlurWindow
// (linux/controlpanel/y700-control-center/src/wlblur.h, compiled in: CMakeLists WLBLUR_DIR), one per window - not
// KWindowEffects::enableBlurBehind, which releases the previous blur object before KWin has applied the new one and
// flickers while the region moves (README「下拉模糊闪烁」; the dock slides its region every frame as it comes up).
#pragma once
#include <QHash>
#include <QObject>
#include <QRegion>
#include <QVariantList>

class QWindow;
class WlBlurWindow;

class Shell : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "fyi.y700.Shellbar")
    Q_PROPERTY(bool ccOpen READ ccOpen NOTIFY ccOpenChanged)
public:
    explicit Shell(QObject *parent = nullptr);
    bool ccOpen() const { return m_ccOpen; }

public Q_SLOTS:
    Q_SCRIPTABLE void reveal() { Q_EMIT revealRequested(); }
    Q_SCRIPTABLE void hideDock() { Q_EMIT hideRequested(); }

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
    void ccOpenChanged();

private Q_SLOTS:
    void onCcOpen(bool open);

private:
    void ccCall(const char *method, const QVariantList &args = {});
    WlBlurWindow *blurOf(QWindow *win);
    bool m_ccOpen = false;
    QHash<QWindow *, WlBlurWindow *> m_blur;       // one per window, owned by the window
};
