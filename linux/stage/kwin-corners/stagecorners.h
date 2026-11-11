/*
    y700-stagecorners: round corners for the windows of the stage manager (linux/stage, KWin script y700-stage:
    20 logical px, vivo 原子工作台's main window) and of split screen (linux/split, KWin script y700-split: 10,
    vivo's split windows). The scripts name them; the corners are KWin 6.6's own Window::setBorderRadius, which the
    scene's window container clips with (surface and decoration; the shadow is left alone) - no shader.
      - Maximized-full and full-screen windows keep KWin's own radius (a game, a video: square).
      - KWin's own radius (the decoration's, or none for client-side ones) is kept for each window and given back
        when it leaves both lists, a list is cleared or the effect unloads. Window::updateDecorationBorderRadius,
        which would work it out again, is protected; so every change KWin makes while we hold the window is
        recorded as its own and ours put back.
    D-Bus, on /org/y700/StageCorners of org.kde.KWin, interface org.y700.StageCorners:
      setWindows(s ids)        the stage's windows: internalIds (with or without braces) separated by spaces, "" = none
      setSplitWindows(s ids)   split screen's two, the same way (a window in both lists gets the stage's 20)
      setSplitChrome(s rect)   "x y w h" (logical px): split screen's backdrop, "" = none. The rectangle (the work
                               area) is painted #242424 at the lowest of the split windows in the stacking order, and
                               whatever is below that window is not painted inside it: the 6 px gap and the round
                               corners show the backdrop, and anything above the pair (the dock, a banner, a menu
                               that crosses the gap, another window) is drawn over it as it stacks - an overlay window
                               of the script would cover those. The split windows are painted without their shadows
                               while it is on (vivo's have none; Breeze's would fall over the other half). The lowest
                               one is painted as transformed: only so is its paint region not cut to its own bounds
                               (WorkspaceScene::paintSimpleScreen, 6.6); the windows below it lose their occlusion
                               culling then, which the cut above gives back. Off, the effect is not in the paint chain.
      touchPoint() -> s        "x y" (logical px) of the last touch event while a finger is down, "" when none is:
                               y700-split polls it while KWin moves a window by its title bar, as KWin tells a script
                               the window's geometry but not where the finger is (Workspace.cursorPos is the pointer's,
                               which touch never moves: ts-bed 11-10). TouchInputRedirection's inline getters only.
    Keep it small: every KWin upgrade means a rebuild, and a crash here takes the whole session with it.
*/
#pragma once

#include "effect/effect.h"
#include "scene/borderradius.h"

#include <QHash>
#include <QSet>

namespace KWin
{

class Window;

class StageCornersEffect : public Effect
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.y700.StageCorners")

public:
    StageCornersEffect();
    ~StageCornersEffect() override;

    bool isActive() const override
    {
        return !m_chrome.isEmpty() && !m_split.isEmpty();
    }
    void prePaintScreen(ScreenPrePaintData &data, std::chrono::milliseconds presentTime) override;
    void prePaintWindow(RenderView *view, EffectWindow *w, WindowPrePaintData &data, std::chrono::milliseconds presentTime) override;
    void paintWindow(const RenderTarget &renderTarget, const RenderViewport &viewport, EffectWindow *w, int mask,
                     const Region &deviceRegion, WindowPaintData &data) override;

public Q_SLOTS:
    Q_SCRIPTABLE void setWindows(const QString &ids);
    Q_SCRIPTABLE void setSplitWindows(const QString &ids);
    Q_SCRIPTABLE void setSplitChrome(const QString &rect);
    Q_SCRIPTABLE QString touchPoint();

private:
    static QSet<Window *> parse(const QString &ids);
    void update();
    void hold(Window *w);
    void release(Window *w, bool restore);
    void apply(Window *w);
    void fill(const RenderTarget &renderTarget, const RenderViewport &viewport, const Region &deviceRegion);

    QSet<Window *> m_stage, m_split;       // what each script asked for
    QHash<Window *, BorderRadius> m_own;   // the windows we round -> KWin's own radius for each
    bool m_setting = false;                // our own setBorderRadius, not KWin's: not recorded
    QRect m_chrome;                        // split screen's backdrop (logical), empty = none
    EffectWindow *m_low = nullptr;         // this frame: the lowest split window shown ...
    QSet<EffectWindow *> m_below;          // ... and everything stacked under it
};

} // namespace KWin
