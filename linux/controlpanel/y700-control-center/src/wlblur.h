// The curtain's frosted glass is KWin's blur effect; this tells it where, through org_kde_kwin_blur - the protocol
// KWindowEffects::enableBlurBehind speaks too (KWindowSystem's wayland plugin, protocol/blur.xml). Not through
// KWindowSystem because of WHEN it releases the previous object: a moment after the new one is created, whether or
// not KWin has applied the commit carrying the new one yet. KWin holds a surface's blur object by QPointer in the
// surface state; a commit waits in a transaction until the buffer's dmabuf fence signals, and a release in that gap
// nulls the pointer: the blur effect then erases the window's region, and the curtain paints its tint over a sharp
// desktop until the next commit with a live object (the flicker of 10-22, README「下拉模糊闪烁」).
// Here an object is released only once a frame callback requested AFTER a newer object was created has come back:
// KWin fires it when the commit carrying it has been applied, so by then the newer object is the surface's and the
// old one is referenced by nothing. Every region change is handed over, one object each, ahead of the commit that
// paints it; none is skipped or held back, nothing is released on a timer.
// WHERE the hand-over runs (10-23): a QQuickWindow's on the render thread, in beforeSynchronizing (the GUI thread
// blocked, so the GUI-side region is read without a lock), the same thread that then makes the frame's
// wl_surface.commit: the hand-over's requests (create, set_region, commit, frame) cannot be split by it. Handed over
// on the GUI thread (at UpdateRequest, until 10-23) the render thread's commit for an earlier frame could land
// between create and set_region, and KWin would take a new object with no region yet = the WHOLE window blurred for a
// frame or two (the 10-22 three-way review; rare). Windows that are not QQuickWindows keep the UpdateRequest path.
// Either way every WlBlur call is on one thread at a time: the GUI thread outside the sync, the render thread inside it.
#pragma once
#include <QObject>
#include <QRegion>
#include <deque>
#include <functional>

struct wl_display;
struct wl_event_queue;
struct wl_registry;
struct wl_surface;
struct wl_callback;
struct org_kde_kwin_blur_manager;
struct org_kde_kwin_blur;

class WlBlur : public QObject
{
    Q_OBJECT
public:
    explicit WlBlur(QObject *parent = nullptr);
    ~WlBlur() override;
    // Qt's own connection (a blur object lives on its surface's connection). One roundtrip right here, on a queue of
    // our own, so the manager global is in before any hand-over (wlblur.cpp)
    void bind(wl_display *display);
    // the window's wl_surface. Qt keeps it over hide/show (6.10: setVisible(false) only drops the layer-shell
    // role) and makes a new one only when the window is destroyed or changes role; every object handed over
    // belongs to it. True when it is a new one (the caller hands the region over again)
    bool attach(wl_surface *surface);
    void detach();                                 // the surface is going away, and every object on it with it
    bool attached() const { return m_surface != nullptr; }
    // a new blur object with this region (surface coordinates), taken by the next wl_surface.commit - the one Qt's
    // render thread makes for the frame being synced. An empty region is an unset: no blur (not an empty object -
    // KWin blurs the WHOLE window for one of those, wlblur.cpp). No blocking call: may run on the render thread
    void handOver(const QRegion &region);
    size_t pending() const { return m_entries.size(); }
    std::function<void(const char *what, const char *detail)> trace;   // Backend::trace (Y700_CC_TRACE), when set

private:
    friend struct WlBlurListeners;
    struct Entry { org_kde_kwin_blur *blur; wl_callback *cb; };      // blur null for an unset; cb null once it is back
    void onGlobal(wl_registry *reg, uint32_t name, const char *iface);
    void onFrame(wl_callback *cb, unsigned gen);
    void release(Entry &e);

    wl_display *m_display = nullptr;
    wl_event_queue *m_queue = nullptr;             // the registry's and the manager's (bind): not Qt's default queue
    wl_registry *m_registry = nullptr;
    org_kde_kwin_blur_manager *m_manager = nullptr;
    wl_surface *m_surface = nullptr;
    unsigned m_gen = 0;                            // bumped by detach: a done queued from before it is ignored
    std::deque<Entry> m_entries;                   // oldest first; the last one is the surface's, or about to be
};

class QWindow;

// One window's blur region, handed over the way Backend does it for the curtain (the comment on
// Backend::eventFilter): remembered here, given to KWin through WlBlur at the window's next sync (a QQuickWindow's
// beforeSynchronizing, on the render thread, ahead of that frame's commit; any other window: its next UpdateRequest
// or Expose) and again whenever the window's wl_surface is a new one.
// For processes with several blurred windows (y700-shellbar: the dock, the banners), one of these per window.
class WlBlurWindow : public QObject
{
    Q_OBJECT
public:
    explicit WlBlurWindow(QWindow *win);           // owned by the window
    void setRegion(const QRegion &region);         // surface (logical) coordinates; empty = nothing blurred

protected:
    bool eventFilter(QObject *o, QEvent *e) override;

private:
    void attach();
    void sync();                                   // beforeSynchronizing (render thread, GUI thread blocked)

    QWindow *m_win;
    WlBlur m_blur;
    QRegion m_region;
    bool m_dirty = false;
    bool m_onSync = false;                         // a QQuickWindow: handed over in sync(), not at UpdateRequest
    QObject *m_ww = nullptr;                       // the QWaylandWindow whose surface signals are connected
};
