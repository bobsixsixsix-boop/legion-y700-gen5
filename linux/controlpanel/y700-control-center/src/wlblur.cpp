#include "wlblur.h"
#include "blur-client-protocol.h"
#include <QGuiApplication>
#include <QPlatformSurfaceEvent>
#include <QPointer>
#include <QWindow>
#include <QtGui/qguiapplication_platform.h>   // QNativeInterface::QWaylandApplication: Qt's wl_compositor, for the wl_region
#include <qpa/qplatformwindow_p.h>            // QNativeInterface::Private::QWaylandWindow: the window's wl_surface (qt6-base-private-dev)
#include <QQuickWindow>
#include <wayland-client.h>
#include <atomic>
#include <cstdio>
#include <cstring>

struct WlBlurListeners {
    static void global(void *data, wl_registry *reg, uint32_t name, const char *iface, uint32_t)
    {
        static_cast<WlBlur *>(data)->onGlobal(reg, name, iface);
    }
    static void remove(void *, wl_registry *, uint32_t) {}
    // Qt dispatches its queue on the GUI thread, but possibly from inside one of its own roundtrips, half-way
    // through something else: back through the event loop. gen: a detach in between makes cb a dangling address
    static void frame(void *data, wl_callback *cb, uint32_t)
    {
        auto *self = static_cast<WlBlur *>(data);
        const unsigned gen = self->m_gen;
        QPointer<WlBlur> guard(self);
        QMetaObject::invokeMethod(self, [guard, cb, gen] { if (guard) guard->onFrame(cb, gen); }, Qt::QueuedConnection);
    }
};
static const wl_registry_listener kRegistry = {WlBlurListeners::global, WlBlurListeners::remove};
static const wl_callback_listener kFrame = {WlBlurListeners::frame};

WlBlur::WlBlur(QObject *parent) : QObject(parent) {}

WlBlur::~WlBlur()
{
    detach();
    if (m_manager) org_kde_kwin_blur_manager_destroy(m_manager);   // no destructor request in the protocol: the proxy only
    if (m_registry) wl_registry_destroy(m_registry);
    if (m_queue) wl_event_queue_destroy(m_queue);  // last: every proxy on it is gone (the blur objects in detach)
}

// The registry (and the manager it binds) on a queue of our own, so the one roundtrip below dispatches only that
// queue, never Qt's default one with Qt's own listeners on it: harmless on any thread and from inside a QML call
// (y700-shellbar makes its WlBlurWindows there) - Mesa's EGL waits on its own queue the same way. After it every
// global the compositor had is in, before the window's first sync can ask for a hand-over. Once, here, not per
// hand-over: on a compositor without the manager that was a blocking roundtrip per animated frame (review 10-22).
// A global advertised later (KWin loading its blur effect after us) waits on the queue for handOver to pick it up
void WlBlur::bind(wl_display *display)
{
    if (m_registry || !display) return;
    m_display = display;
    m_queue = wl_display_create_queue(display);
    // through a wrapper, so the registry is born on our queue: moved there afterwards, Qt's event thread could
    // already have put its first globals on the default queue
    auto *wrapper = static_cast<wl_display *>(wl_proxy_create_wrapper(display));
    wl_proxy_set_queue(reinterpret_cast<wl_proxy *>(wrapper), m_queue);
    m_registry = wl_display_get_registry(wrapper);
    wl_proxy_wrapper_destroy(wrapper);
    wl_registry_add_listener(m_registry, &kRegistry, this);
    wl_display_roundtrip_queue(display, m_queue);
}

void WlBlur::onGlobal(wl_registry *reg, uint32_t name, const char *iface)
{
    if (!m_manager && strcmp(iface, org_kde_kwin_blur_manager_interface.name) == 0)
        m_manager = static_cast<org_kde_kwin_blur_manager *>(wl_registry_bind(reg, name, &org_kde_kwin_blur_manager_interface, 1));
}

bool WlBlur::attach(wl_surface *surface)
{
    if (surface == m_surface) return false;
    detach();
    m_surface = surface;
    if (trace) trace("surface", surface ? "attach" : "none");
    return surface != nullptr;
}

void WlBlur::detach()
{
    if (!m_surface) return;
    for (Entry &e : m_entries) release(e);
    if (trace) {
        char d[64];
        snprintf(d, sizeof d, "detach released=%u", unsigned(m_entries.size()));
        trace("surface", d);
    }
    m_entries.clear();
    m_surface = nullptr;
    ++m_gen;
}

void WlBlur::release(Entry &e)
{
    if (e.cb) wl_callback_destroy(e.cb);           // not back yet: a done still on its way is dropped by libwayland
    if (e.blur) org_kde_kwin_blur_release(e.blur);
}

void WlBlur::handOver(const QRegion &region)
{
    if (!m_surface) return;
    if (!m_manager && m_queue) wl_display_dispatch_queue_pending(m_display, m_queue);   // advertised since bind: no blocking
    auto *native = qGuiApp->nativeInterface<QNativeInterface::QWaylandApplication>();
    wl_compositor *compositor = native ? native->compositor() : nullptr;
    if (!m_manager || !compositor) {
        static std::atomic<bool> said{false};      // several windows, each with its own render thread (y700-shellbar)
        if (!said.exchange(true)) fprintf(stderr, "wlblur: no org_kde_kwin_blur_manager on this compositor: no blur\n");
        return;
    }
    // surface (logical) coordinates, as KWindowSystem passes them. KWin draws no line between a null region and an
    // empty one: both reach it as an empty QRegion, and BlurEffect::blurRegion() widens an empty one to the WHOLE
    // window (KWindowEffects::enableBlurBehind(w, true) with its default QRegion() is exactly that). So "nothing
    // blurred" is the protocol's unset, which takes the next commit as a create would; the frame callback below
    // then proves the older objects unreferenced the same way
    org_kde_kwin_blur *blur = nullptr;
    if (region.isEmpty()) {
        org_kde_kwin_blur_manager_unset(m_manager, m_surface);
    } else {
        wl_region *r = wl_compositor_create_region(compositor);
        for (const QRect &rect : region) wl_region_add(r, rect.x(), rect.y(), rect.width(), rect.height());
        blur = org_kde_kwin_blur_manager_create(m_manager, m_surface);
        org_kde_kwin_blur_set_region(blur, r);
        org_kde_kwin_blur_commit(blur);
        wl_region_destroy(r);
    }
    // requested after the object was created, so it rides with the commit that takes the object, or a later one:
    // once it is back, every older object is referenced by nothing (onFrame)
    wl_callback *cb = wl_surface_frame(m_surface);
    wl_callback_add_listener(cb, &kFrame, this);
    m_entries.push_back({blur, cb});
}

void WlBlur::onFrame(wl_callback *cb, unsigned gen)
{
    if (gen != m_gen) return;
    size_t k = 0;
    while (k < m_entries.size() && m_entries[k].cb != cb) ++k;
    if (k == m_entries.size()) return;
    wl_callback_destroy(m_entries[k].cb);
    m_entries[k].cb = nullptr;
    // KWin has applied the commit that took entry k (or a later one): the surface's object is k's or newer.
    // Entry k stays until a newer one is proven the same way
    for (size_t i = 0; i < k; ++i) release(m_entries[i]);
    m_entries.erase(m_entries.begin(), m_entries.begin() + k);
    if (trace) {
        char d[64];
        snprintf(d, sizeof d, "released=%u left=%u", unsigned(k), unsigned(m_entries.size()));
        trace("done", d);
    }
}

// ---- WlBlurWindow: Backend's hand-over (backend.cpp setWindow / eventFilter / attachBlurSurface), for any window

WlBlurWindow::WlBlurWindow(QWindow *win) : QObject(win), m_win(win)
{
    if (auto *native = qGuiApp->nativeInterface<QNativeInterface::QWaylandApplication>()) m_blur.bind(native->display());
    win->installEventFilter(this);
    if (auto *qw = qobject_cast<QQuickWindow *>(win)) {
        m_onSync = true;
        connect(qw, &QQuickWindow::beforeSynchronizing, this, &WlBlurWindow::sync, Qt::DirectConnection);
    }
    if (win->handle()) attach();                   // else the first show creates it: QEvent::PlatformSurface
}

void WlBlurWindow::setRegion(const QRegion &region)
{
    if (region == m_region) return;
    m_region = region;
    m_dirty = true;
    // a change without a repaint behind it still gets a sync and a commit (sync()). A QQuickWindow's own update():
    // the basic loop presents only a frame asked for that way (requestUpdate alone renders it with SkipPresent)
    if (m_onSync) static_cast<QQuickWindow *>(m_win)->update();
    else m_win->requestUpdate();
}

// QQuickWindow: the hand-over is sync()'s. Any other window: UpdateRequest, before the render thread's commit for
// the frame being requested; Expose: the first frame of a freshly shown window comes from the expose, not from an
// UpdateRequest
bool WlBlurWindow::eventFilter(QObject *o, QEvent *e)
{
    if (o != m_win) return QObject::eventFilter(o, e);
    if (e->type() == QEvent::PlatformSurface) {
        if (static_cast<QPlatformSurfaceEvent *>(e)->surfaceEventType() == QPlatformSurfaceEvent::SurfaceCreated) attach();
        else m_blur.detach();
    } else if (!m_onSync && m_dirty && m_blur.attached()
               && (e->type() == QEvent::UpdateRequest || e->type() == QEvent::Expose)) {
        m_dirty = false;
        m_blur.handOver(m_region);
    }
    return QObject::eventFilter(o, e);
}

// The render thread, the GUI thread blocked (m_region / m_dirty are the GUI thread's): the requests go out on the
// thread that makes this frame's commit, before it. A change of region alone still gets that commit: setRegion's
// update() brings the sync and marks the frame for presenting; Qt 6's threaded loop presents after every sync anyway
// (6.10 qsgthreadedrenderloop.cpp: "Qt 6 no longer aborts when !syncResultedInChanges"). No update() from here: the
// threaded loop clears a repaint request made during the sync, and in the basic one it would only come a frame late
void WlBlurWindow::sync()
{
    if (!m_dirty || !m_blur.attached()) return;
    m_dirty = false;
    m_blur.handOver(m_region);
}

// The window's wl_surface: Qt keeps it over hide/show, a new one comes with a role change (surfaceCreated). A fresh
// surface gets the region at once, so it is in KWin's state before the initial commit and the first frame maps blurred
void WlBlurWindow::attach()
{
    auto *ww = m_win->nativeInterface<QNativeInterface::Private::QWaylandWindow>();
    if (!ww) return;
    if (ww != m_ww) {
        m_ww = ww;
        connect(ww, &QNativeInterface::Private::QWaylandWindow::surfaceCreated, this, &WlBlurWindow::attach);
        connect(ww, &QNativeInterface::Private::QWaylandWindow::surfaceDestroyed, this, [this] { m_blur.detach(); });
    }
    if (!m_blur.attach(ww->surface())) return;
    if (!m_region.isEmpty()) {
        m_dirty = false;
        m_blur.handOver(m_region);
    }
}
