/*
    y700-oskgate: a KWin effect that only watches. It reports, as D-Bus signals, what the on-screen
    keyboard needs to tell "the finger tapped a text field" from "the finger touched a window and the
    app put its focus back into a text field" (owner, 2026-10-14: dragging Telegram's window brought
    the keyboard up):
      - every touch / pen tip: where it went down, which window is under it (class and unique id),
        whether that is the server-side frame, how far it travelled and how long it lasted (on lift),
        and touch cancels;
      - the text-input traffic: v1/v2 show/hide_input_panel requests, enable/disable (v3 enables
        KWin re-sends on a focus change are marked byFocus), v3 commits while enabled, focus changes,
        input-method active/inactive, each with the window and the text cursor rectangle; with an
        activation, whether KWin's own focused Qt item (an effect's QML scene) is a text field.
    Only KWin knows both halves. It never consumes or changes input, never paints, and owns no policy:
    y700-osk decides. Nothing is sent while the screen is locked (the lock screen's PIN pad taps must
    not go out on the session bus). Keep it small; every KWin upgrade means a rebuild, and a crash here
    takes the whole session with it.
    Signal: org.y700.OskGate.Event(s json) on path /org/y700/OskGate, sent by org.kde.KWin.
*/
#pragma once

#include "effect/effect.h"
#include "input_event_spy.h"

#include <QHash>
#include <QJsonObject>
#include <QPointF>
#include <QPointer>
#include <QString>
#include <chrono>
#include <memory>

namespace KWin
{

class OskGateEffect;
class SurfaceInterface;
class Window;

// A separate spy object: InputEventSpy::touchDown(TouchDownEvent *) and Effect::touchDown(id, pos,
// time) share a name, and one class deriving from both would hide one of them.
class OskGateSpy : public InputEventSpy
{
public:
    explicit OskGateSpy(OskGateEffect *gate);
    void touchDown(TouchDownEvent *event) override;
    void touchMotion(TouchMotionEvent *event) override;
    void touchUp(TouchUpEvent *event) override;
    void tabletToolTipEvent(TabletToolTipEvent *event) override;
    void cancel();

private:
    struct Touch {
        QPointF down;
        std::chrono::microseconds t0{0};
        double maxDist = 0;
        QString window;
        QString wid;
        bool frame = false;
        int fingers = 1;
    };
    Touch begin(const QPointF &pos, std::chrono::microseconds time, int fingers);
    void report(const QString &type, qint32 id, const Touch &t, const QPointF *upPos, std::chrono::microseconds time, const QString &tool);

    OskGateEffect *m_gate;
    QHash<qint32, Touch> m_touches;
    bool m_penDown = false;
    Touch m_pen;
};

class OskGateEffect : public Effect
{
    Q_OBJECT

public:
    OskGateEffect();
    ~OskGateEffect() override;

    // never in the paint chain
    bool isActive() const override
    {
        return false;
    }
    // the only Effect input hook used: InputEventSpy has no cancel callback
    void touchCancel() override;

    void emitEvent(const QJsonObject &event);
    static bool locked();
    static QString windowId(const Window *window);
    static QString windowUid(const Window *window);

private:
    void textEvent(const QString &kind, bool byFocus = false);

    std::unique_ptr<OskGateSpy> m_spy;
    QPointer<SurfaceInterface> m_lastFocus;     // the text-input focus as of the last focus-change signal
};

} // namespace KWin
