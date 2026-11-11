/*
    y700-stagecorners - see stagecorners.h.
*/
#include "stagecorners.h"

#include "core/colorspace.h"
#include "core/rendertarget.h"
#include "core/renderviewport.h"
#include "effect/effecthandler.h"
#include "effect/effectwindow.h"
#include "input.h"
#include "opengl/glshader.h"
#include "opengl/glshadermanager.h"
#include "opengl/glvertexbuffer.h"
#include "touch_input.h"
#include "window.h"

#include <QDBusConnection>
#include <QUuid>
#include <QVector2D>

namespace KWin
{

static const QString PATH = QStringLiteral("/org/y700/StageCorners");
static constexpr qreal RADIUS = 20;         // the stage (vivo 原子工作台)
static constexpr qreal RADIUS_SPLIT = 10;   // split screen (vivo's split windows)

StageCornersEffect::StageCornersEffect()
{
    QDBusConnection::sessionBus().registerObject(PATH, this, QDBusConnection::ExportScriptableSlots);
}

StageCornersEffect::~StageCornersEffect()
{
    QDBusConnection::sessionBus().unregisterObject(PATH);
    const auto held = m_own.keys();
    for (Window *w : held) release(w, true);
}

QSet<Window *> StageCornersEffect::parse(const QString &ids)
{
    QSet<Window *> want;
    for (const QString &id : ids.split(u' ', Qt::SkipEmptyParts)) {
        const QUuid uuid = QUuid::fromString(id);
        EffectWindow *ew = uuid.isNull() ? nullptr : effects->findWindow(uuid);
        Window *w = ew ? ew->window() : nullptr;
        if (w && !w->isDeleted()) want.insert(w);
    }
    return want;
}

void StageCornersEffect::setWindows(const QString &ids)
{
    m_stage = parse(ids);
    update();
}

void StageCornersEffect::setSplitWindows(const QString &ids)
{
    m_split = parse(ids);
    update();
    if (!m_chrome.isEmpty()) effects->addRepaint(m_chrome);
}

void StageCornersEffect::setSplitChrome(const QString &rect)
{
    const QStringList p = rect.split(u' ', Qt::SkipEmptyParts);
    QRect r;
    if (p.size() == 4) r = QRect(p[0].toInt(), p[1].toInt(), p[2].toInt(), p[3].toInt());
    if (!r.isValid()) r = QRect();
    if (r == m_chrome) return;
    if (!m_chrome.isEmpty()) effects->addRepaint(m_chrome);
    m_chrome = r;
    if (!m_chrome.isEmpty()) effects->addRepaint(m_chrome);
    else { m_low = nullptr; m_below.clear(); }
}

void StageCornersEffect::prePaintScreen(ScreenPrePaintData &data, std::chrono::milliseconds presentTime)
{
    m_low = nullptr;
    m_below.clear();
    if (!m_chrome.isEmpty()) {
        const QList<EffectWindow *> order = effects->stackingOrder();   // bottom first
        for (EffectWindow *ew : order) {
            Window *w = ew->window();
            if (w && m_split.contains(w) && !ew->isDeleted() && !ew->isMinimized() && ew->isOnCurrentDesktop()) {
                m_low = ew;
                break;
            }
            m_below.insert(ew);
        }
        if (!m_low) m_below.clear();
    }
    effects->prePaintScreen(data, presentTime);
}

void StageCornersEffect::prePaintWindow(RenderView *view, EffectWindow *w, WindowPrePaintData &data, std::chrono::milliseconds presentTime)
{
    if (w == m_low) data.setTransformed();   // its paint region is then not cut to its bounds: the gap, the other half
    effects->prePaintWindow(view, w, data, presentTime);
}

void StageCornersEffect::paintWindow(const RenderTarget &renderTarget, const RenderViewport &viewport, EffectWindow *w,
                                     int mask, const Region &deviceRegion, WindowPaintData &data)
{
    if (!m_low) {
        effects->paintWindow(renderTarget, viewport, w, mask, deviceRegion, data);
        return;
    }
    const Rect area = viewport.mapToDeviceCoordinatesAligned(Rect(m_chrome));
    if (m_below.contains(w)) {   // behind the backdrop
        const Region r = deviceRegion - area;
        if (!r.isEmpty()) effects->paintWindow(renderTarget, viewport, w, mask, r, data);
        return;
    }
    Window *win = w->window();
    if (!win || !m_split.contains(win)) {
        effects->paintWindow(renderTarget, viewport, w, mask, deviceRegion, data);
        return;
    }
    if (w == m_low) fill(renderTarget, viewport, deviceRegion & area);
    // its frame only: no shadow over the gap or the other half
    const Region own = deviceRegion & viewport.mapToDeviceCoordinatesAligned(RectF(w->frameGeometry()));
    if (!own.isEmpty()) effects->paintWindow(renderTarget, viewport, w, mask, own, data);
}

// #242424, opaque: two triangles per device rect, as ShowPaintEffect::paintGL draws its rects (KWin 6.6)
void StageCornersEffect::fill(const RenderTarget &renderTarget, const RenderViewport &viewport, const Region &deviceRegion)
{
    if (deviceRegion.isEmpty() || !effects->isOpenGLCompositing()) return;
    QList<QVector2D> verts;
    verts.reserve(deviceRegion.rects().size() * 6);
    for (const Rect &deviceRect : deviceRegion.rects()) {
        const auto r = deviceRect.translated(viewport.scaledRenderRect().topLeft());
        verts.push_back(QVector2D(r.x() + r.width(), r.y()));
        verts.push_back(QVector2D(r.x(), r.y()));
        verts.push_back(QVector2D(r.x(), r.y() + r.height()));
        verts.push_back(QVector2D(r.x(), r.y() + r.height()));
        verts.push_back(QVector2D(r.x() + r.width(), r.y() + r.height()));
        verts.push_back(QVector2D(r.x() + r.width(), r.y()));
    }
    GLVertexBuffer *vbo = GLVertexBuffer::streamingBuffer();
    vbo->reset();
    ShaderBinder binder(ShaderTrait::UniformColor | ShaderTrait::TransformColorspace);
    binder.shader()->setUniform(GLShader::Mat4Uniform::ModelViewProjectionMatrix, viewport.projectionMatrix());
    binder.shader()->setColorspaceUniforms(ColorDescription::sRGB, renderTarget.colorDescription(), RenderingIntent::Perceptual);
    binder.shader()->setUniform(GLShader::ColorUniform::Color, QColor(0x24, 0x24, 0x24));
    vbo->setVertices(verts);
    vbo->render(GL_TRIANGLES);
}

QString StageCornersEffect::touchPoint()
{
    const InputRedirection *in = input();
    const TouchInputRedirection *t = in ? in->touch() : nullptr;
    if (!t || t->touchPointCount() == 0) return QString();
    const QPointF p = t->position();
    return QString::number(p.x(), 'f', 1) + u' ' + QString::number(p.y(), 'f', 1);
}

void StageCornersEffect::update()
{
    const QSet<Window *> want = m_stage | m_split;
    const auto held = m_own.keys();
    const bool same = QSet<Window *>(held.begin(), held.end()) == want;
    for (Window *w : held) if (!want.contains(w)) release(w, true);
    for (Window *w : want) {
        if (!m_own.contains(w)) hold(w);
        else apply(w);   // it may have gone from one list to the other
    }
    if (!same) qInfo("y700-stagecorners: %lld window(s) rounded", qlonglong(m_own.size()));   // only when the set changes
}

void StageCornersEffect::hold(Window *w)
{
    m_own.insert(w, w->borderRadius());
    connect(w, &Window::borderRadiusChanged, this, [this, w] {
        if (m_setting) return;
        m_own[w] = w->borderRadius();   // KWin's (the decoration changed it): the window's own from now on
        apply(w);
    });
    connect(w, &Window::maximizedChanged, this, [this, w] { apply(w); });
    connect(w, &Window::fullScreenChanged, this, [this, w] { apply(w); });
    connect(w, &Window::closed, this, [this, w] { release(w, false); });
    connect(w, &QObject::destroyed, this, [this, w] { m_own.remove(w); m_stage.remove(w); m_split.remove(w); });
    apply(w);
}

void StageCornersEffect::release(Window *w, bool restore)
{
    m_stage.remove(w);   // a closed window must not come back with the next update
    m_split.remove(w);
    auto it = m_own.find(w);
    if (it == m_own.end()) return;
    const BorderRadius own = it.value();
    m_own.erase(it);
    disconnect(w, nullptr, this, nullptr);
    if (restore && !w->isDeleted() && !(w->borderRadius() == own)) {
        m_setting = true;
        w->setBorderRadius(own);
        m_setting = false;
    }
}

void StageCornersEffect::apply(Window *w)
{
    const auto it = m_own.constFind(w);
    if (it == m_own.constEnd()) return;
    const bool square = w->isFullScreen() || w->maximizeMode() == MaximizeFull;
    const BorderRadius want = square ? it.value() : BorderRadius(m_stage.contains(w) ? RADIUS : RADIUS_SPLIT);
    if (w->borderRadius() == want) return;
    m_setting = true;
    w->setBorderRadius(want);
    m_setting = false;
}

} // namespace KWin
