// y700 task switcher view: the stacked cards (vivo OriginOS style), replacing upstream's TaskSwitcher.qml
// (and with it Task / TaskList / FlickContainer / TaskSwitcherHelpers). One instance per screen, created
// by the C++ plugin each time the switcher opens and destroyed when it closes.
//
// A port of the approved design's state machine (design/y700-taskswitcher-mockup.html). While the view
// exists KWin paints nothing but this scene, so it draws everything: the desktop (DesktopBackground +
// the panel), the cards (live WindowThumbnails), and at zoom 1 the app on screen exactly where it is.
// Every exit animates to its end picture first and then hides instantly (instantHide), so the switch
// to the real windows is invisible. README "多任务卡片 → 实现要点" has the why of each part.
pragma ComponentBehavior: Bound

import QtQuick
import Qt5Compat.GraphicalEffects

import org.kde.kirigami as Kirigami
import org.kde.kwin 3.0 as KWinComponents
import org.kde.plasma.private.mobileshell.taskswitcherplugin as TaskSwitcherPlugin

import "stack.js" as Stack

FocusScope {
    id: root
    focus: true

    property TaskSwitcherPlugin.MobileTaskSwitcherState state
    // main.qml's AppQuit (y700-taskswitcher.patch): a swiped-away app is quit, not only its window closed
    property QtObject appQuit: null
    readonly property QtObject targetScreen: KWinComponents.SceneView.screen

    property TaskSwitcherPlugin.TaskFilterModel tasksModel: TaskSwitcherPlugin.TaskFilterModel {
        screenName: root.targetScreen.name
        windowModel: root.state.taskModel
    }

    // the bottom-edge swipe is a finger on the tablet's own panel (DSI-1): with a monitor on DP every
    // screen gets a view, and only this one follows the edge; the others stay as they are until it ends
    readonly property bool edgeOwner: /^DSI/.test(targetScreen.name)
        || !(KWinComponents.Workspace.screens || []).some(o => /^DSI/.test(o.name))
    readonly property bool passive: !edgeOwner && state.gestureInProgress

    // Plasma's "animation speed: instant" (Kirigami follows it): springs jump, nothing slides
    readonly property bool reduced: Kirigami.Units.longDuration < 1

    // ---- geometry (fixed while open; the view is rebuilt on every open) ----
    property rect workArea: Qt.rect(0, 0, width, height)   // relative to this view
    property point viewOrigin: Qt.point(0, 0)                // this view's top left, global
    property var geo: Stack.geometry(width, height)
    property var docks: []                                   // panel windows, drawn on the desktop layer
    property var appDocks: []                                // those up when the effect started: over the app

    // ---- state (plain JS objects; nothing binds to them, render() writes the items) ----
    property string mode: "desk"     // app | desk | recents | opening | leaving | homing | gesture
    property var gesture: null       // the one pointer (or edge swipe) in progress
    property var cards: []           // alive cards, newest first (rank = index)
    property var flying: []          // closed cards still on their way out, or parked until the window goes
    property var focusCard: null     // the app on screen in mode app
    property var originCard: null    // the app the cards were opened from (null = from the desktop)
    property var openTarget: null    // the card being opened
    property var spr: null             // springs: s z e b h lift anc pj
    property int zTop: 0
    property bool built: false
    property bool ended: false       // instantHide asked for: no more input, no more frames

    // ---- written by render() for the chrome ----
    property real blurOpacity: 0
    property real layerScale: 1
    property real layerX: 0
    property real layerY: 0
    property real stackOpacity: 1
    property real clearOpacity: 0
    property real overPanelOpacity: 0
    property bool emptyShown: false
    property bool clearArmed: false
    property bool clearPressed: false
    property point glowAt: Qt.point(0, 0)   // the press point on the clear button, for its glow
    property string toastText: ""
    property bool toastOn: false
    // the header's ▾ menu (11-10): one item, 「分屏」 (linux/split). splitOk: the split screen script runs (its handle
    // window, parked off screen, is listed while it is loaded) and the stage manager is off (its strip's caption
    // ends in " on", Stage.qml); fixed while the cards are up, as the rest of the geometry
    property bool splitOk: false
    property var menuCard: null      // the card whose menu is up
    property rect menuRect: Qt.rect(0, 0, 150, 60)   // on screen (this view's coordinates)
    property real menuOx: 0          // where it grows from: the ▾, relative to menuRect
    property bool menuPressed: false
    property var splitAfter: null    // 「分屏」 chosen: the card opens, then the split shortcut

    // ---- frame clock: KWin drives QML animations by presentation time (RenderLoopDrivenQAnimationDriver),
    // so a linear NumberAnimation's value is the frame's time; FrameAnimation would use the wall clock ----
    property real clock: 0
    property real lastClock: -1
    NumberAnimation on clock {
        id: ticker
        running: false
        from: 0
        to: 3600000
        duration: 3600000
        loops: Animation.Infinite
    }
    onClockChanged: frame()

    function kick(): void {
        if (!ended && !ticker.running) {
            lastClock = -1;
            ticker.restart();
        }
    }

    // ================= model =================
    Instantiator {
        id: models
        model: root.tasksModel
        delegate: QtObject {
            required property QtObject window
            required property int index
        }
        onObjectAdded: (index, object) => root.modelAdded(index, object)
        onObjectRemoved: (index, object) => root.modelRemoved(object)
    }

    Component {
        id: cardComponent
        StackCard {}
    }

    Component.onCompleted: initialSetup()

    function initialSetup(): void {
        const scr = targetScreen;
        const desk = KWinComponents.Workspace.currentDesktop;
        const full = KWinComponents.Workspace.clientArea(KWinComponents.Workspace.FullScreenArea, scr, desk);
        const max = KWinComponents.Workspace.clientArea(KWinComponents.Workspace.MaximizeArea, scr, desk);
        viewOrigin = Qt.point(full.x, full.y);
        workArea = Qt.rect(max.x - full.x, max.y - full.y, max.width, max.height);
        geo = Stack.geometry(max.width, max.height);
        docks = KWinComponents.Workspace.stackingOrder.filter(w => w.dock && w.output === scr && !w.minimized);
        appDocks = docks;                       // the panels over the app as it was, before minimizeAll() maps more

        const aw = KWinComponents.Workspace.activeWindow;
        // upstream e04c10bc (10-06, master only; 6.6.5's C++ still takes any non-desktop window): a minimized app
        // can stay the active window until the shell takes focus, and the cards would open in "app" mode on a card
        // that is already put away. Upstream asks isShown(); minimized is the case it names. Not seen here
        // (10-23: minimizeAll() puts the active window away last and KWin hands the focus to the desktop before
        // minimizedChanged), kept so it cannot happen when something else minimized the app
        state.updateWasInActiveTask(aw && !aw.minimized ? aw : null);
        const all = KWinComponents.Workspace.windows;
        splitOk = all.some(w => w.caption === "y700-split handle") && !all.some(w => w.caption === "y700-stage strip on");

        spr = {
            s: Stack.spring(0, Stack.K.scroll),
            z: Stack.spring(1, Stack.K.zoom),
            e: Stack.spring(1, Stack.K.enter),
            b: Stack.spring(0, Stack.K.blur),
            h: Stack.spring(0, Stack.K.home),
            lift: Stack.spring(0, Stack.K.lift, .3),
            anc: Stack.spring(0, Stack.K.zoom, .05),
            pj: Stack.spring(0, Stack.K.scroll),
        };

        const list = [];
        for (let i = 0; i < models.count; i++) {
            const o = models.objectAt(i);
            if (o && o.window) {
                list.push(makeCard(o.window, o, list.length));
            }
        }
        cards = list;
        zTop = list.length;
        list.forEach((c, i) => { c.zk = list.length - i; });
        built = true;

        const fi = aw ? cards.findIndex(c => c.window === aw) : -1;
        if (!passive) minimizeAll();
        if (passive && cards.length) {          // another screen's swipe: show this one's top window as it is
            mode = "app"; focusCard = cards[0];
            spr.s.jump(restS(0)); spr.z.jump(1); spr.e.jump(1); spr.b.jump(0);
        } else if (state.wasInActiveTask && fi >= 0) {
            mode = "app"; focusCard = cards[fi];
            spr.s.jump(restS(fi)); spr.z.jump(1); spr.e.jump(1); spr.b.jump(0);
        } else {
            mode = "desk"; focusCard = null;
            spr.s.jump(restS(0)); spr.z.jump(0); spr.e.jump(0); spr.b.jump(0);
        }
        spr.anc.jump(anchorX());
        render();
        console.info("y700-taskswitcher: open " + (mode === "app" ? "from an app" : "from the desktop")
            + ", " + cards.length + " cards, " + (state.gestureInProgress ? "edge swipe" : "shortcut"));

        // opened by the shortcut (not by a finger on the edge): go straight to the cards
        if (!state.gestureInProgress) {
            if (mode === "app") {
                originCard = focusCard;
                enterRecentsFromApp(0, 0);
            } else {
                openRecentsFromDesk(0);
            }
        }
        kick();
    }

    function makeCard(w, mobj, i) {
        const r = geo.ratio;
        const gx = w.x - viewOrigin.x - workArea.x, gy = w.y - viewOrigin.y - workArea.y;
        const item = cardComponent.createObject(stack, {
            window: w,
            wid: w.internalId,
            cw: geo.cw,
            ch: geo.ch,
            win: Qt.rect(gx * r, gy * r, w.width * r, w.height * r),
            guarded: Stack.guarded(w.resourceClass, w.desktopFileName),
            name: Stack.appName(w.caption),
            icon: w.icon,
            zoomK: geo.k,
            dpr: targetScreen.devicePixelRatio || 1,
            reduced: root.reduced,
            menuable: root.splitOk && !Stack.guarded(w.resourceClass, w.desktopFileName),
        });
        return {
            item: item, window: w, mobj: mobj, guarded: item.guarded,
            slot: Stack.spring(i, Stack.K.slot),
            ty: Stack.spring(0, Stack.K.back, .3),
            press: Stack.spring(1, Stack.K.press),
            zk: 0, gone: false, parked: false, closedAt: 0, checkAt: 0,
            rect: null,
        };
    }

    // a window left the model: closed by us (it is flying or parked) or by itself (still in the stack)
    function modelRemoved(object): void {
        if (!built || ended) {
            return;
        }
        const c = cards.concat(flying).find(x => x.mobj === object);
        if (!c) {
            return;
        }
        c.gone = true;
        // the finger is on this very card (a game quit mid-swipe): let go of it, so it flies off instead of
        // staying pinned to the finger, and the release neither opens it nor leaves the cards
        const g = gesture;
        if (g && g.card === c) {
            c.ty.held = false;
            c.press.to(1, ...Stack.K.press);
            g.card = null;
            if (g.kind === "swipe") g.kind = "dead";
            else if (g.kind === "pending") g.caught = true;
        }
        if (cards.indexOf(c) >= 0) {
            closeCard(c, -1800, false);
        } else if (c.parked) {
            destroyCard(c);
        }
    }

    function destroyCard(c): void {
        flying = flying.filter(x => x !== c);
        if (c.item) {
            c.item.destroy();
            c.item = null;
        }
    }

    // ================= stack math =================
    function maxS(): int { return Math.max(0, cards.length - 1); }

    // scroll value at rest with card i in front: the two end cards rest centred, like vivo
    function restS(i): real {
        const n = cards.length, d = geo.delta;
        if (n <= 1 || i <= 0) return -d;
        if (i >= n - 1) return n - 1 - d;
        return i;
    }
    // the card whose resting scroll is nearest
    function idxAt(v): int {
        let k = 0;
        for (let i = 1; i <= maxS(); i++) {
            if (Math.abs(restS(i) - v) < Math.abs(restS(k) - v)) k = i;
        }
        return k;
    }
    // like vivo: the looks hold still over the end segment, so a centred end card keeps the front look
    function propS(v): real {
        const n = cards.length, d = geo.delta;
        if (n <= 1) return v + d;
        if (v < -d) return -1 + (v + 1) / (1 - d);
        if (v <= 0) return 0;
        if (v >= n - 2 && v <= n - 1 - d) return n - 2 + (v - (n - 2)) / (1 - d);
        if (v > n - 1 - d && v <= n - 1) return n - 1;
        return v;
    }
    // where the anchor card rests in the stack
    function anchorX(): real {
        const c = openTarget || focusCard, i = c ? cards.indexOf(c) : -1;
        return i < 0 ? Stack.xAt(geo, geo.delta) : Stack.xAt(geo, i - restS(i));
    }
    // vivo also keeps the newest card's name at its end, and the newer card's lying on the oldest one
    function nameAlpha(c, dp): real {
        const i = cards.indexOf(c), n = cards.length;
        if (i === 0 && spr.s.v < 0) return 1;
        if (n >= 2 && i === n - 2 && spr.s.v >= n - 2) return 1;
        return Stack.labelAlpha(dp);
    }

    // ================= transitions =================
    function rerank(): void { cards.forEach((c, i) => c.slot.to(i)); }

    function enterRecentsFromApp(vz, vs): void {     // the app shrank into its card; settle into the stack
        mode = "recents";
        spr.z.to(0, ...Stack.K.zoom, vz);
        spr.s.to(restS(idxAt(spr.s.v)), ...Stack.K.scroll, vs);
        spr.b.to(1, ...Stack.K.blur);
        spr.e.to(1, ...Stack.K.enter);
        kick();
    }
    function openRecentsFromDesk(ve): void {
        mode = "recents"; originCard = null;
        spr.e.to(1, ...Stack.K.enter, ve);
        spr.s.to(restS(idxAt(spr.s.v)), ...Stack.K.scroll);
        spr.b.to(1, ...Stack.K.blur);
        spr.z.to(0, ...Stack.K.zoom);
        kick();
    }
    function disarmAll(): void {      // a confirmation (or the ▾ menu) never outlives the card screen it was given on
        clearArmed = false;
        clearTimer.stop();
        closeMenu();
        cards.concat(flying).forEach(c => { if (c.item) c.item.disarm(); });
    }
    function openCard(c, vs): void {  // tap, quick switch, or "close the cards = back to where I was"
        disarmAll();
        if (!c || cards.indexOf(c) < 0) {
            leaveToDesk();
            return;
        }
        mode = "opening"; openTarget = c;
        spr.s.to(restS(cards.indexOf(c)), ...Stack.K.scroll, vs);
        spr.z.to(1, ...Stack.K.zoom);
        spr.e.to(1, ...Stack.K.enter);
        // activate now (like upstream): it un-minimizes and renders behind us while the card zooms in
        activate(c);
        kick();
    }
    // leave without choosing: back to the app the cards were opened from, else the desktop
    // (owner 2026-10-21: 「关卡片回原应用」; vivo always goes to the desktop)
    function dismiss(): void {
        if (mode !== "recents" || gesture) {
            return;
        }
        if (originCard && cards.indexOf(originCard) >= 0) openCard(originCard);   // keeps the scroll's coast
        else leaveToDesk();
    }
    function leaveToDesk(): void {
        disarmAll(); mode = "leaving"; openTarget = null;
        spr.e.to(0, ...Stack.K.leave);
        spr.b.to(0, ...Stack.K.leave);
        spr.z.to(Math.min(spr.z.v, 0), ...Stack.K.leave);
        kick();
    }
    function goHomeFromApp(): void {   // fast flick up from an app
        disarmAll(); mode = "homing";
        spr.h.to(1, ...Stack.K.home);
        spr.b.to(0, ...Stack.K.home);
        kick();
    }
    function settle(): void {          // after the springs, every frame: finish transitions
        if (mode === "opening" && openTarget && spr.z.rest && Math.abs(spr.s.v - spr.s.t) < .004) {
            finishOpen(openTarget);
        } else if (mode === "leaving" && spr.e.rest && spr.b.rest) {
            finishDesk();
        } else if (mode === "homing" && spr.h.rest) {
            finishDesk();
        }
    }
    function activate(c): void {
        const w = c.window;
        if (w && !w.deleted) {
            KWinComponents.Workspace.activeWindow = w;
        }
    }
    function finishOpen(c): void {
        activate(c);
        // 「分屏」 (the ▾ menu): the app is active and on screen now; the split script (linux/split) takes it to the
        // left half once this effect is gone (the call comes back to KWin through kglobalaccel after this returns;
        // the script also waits up to 1 s for an active app)
        if (splitAfter === c) {
            splitAfter = null;
            splitShortcut.call();
        }
        // only the chosen app comes back: an opening caught and retargeted (or an edge swipe that caught
        // it) had already un-minimized the first target, which would stay up behind this one. c is active,
        // so minimizing the rest does not move the focus
        for (const x of cards.concat(flying)) {
            const w = x.window;
            if (x !== c && w && !w.deleted && !w.minimized) w.minimized = true;
        }
        hideNow();
    }
    function finishDesk(): void {
        minimizeAll();
        hideNow();
    }
    function hideNow(): void {
        ended = true;
        ticker.stop();
        state.deactivate(true);
    }

    // everything down, the active window last. Minimized first, it hands the focus to the next window in
    // KWin's focus chain for a moment, which is minimized right after; Claude desktop (Electron, Wayland)
    // then came back un-minimized and active ~50 ms later (2026-10-21). With the others first the focus
    // goes straight from the active window to the desktop.
    function minimizeAll(): void {
        const act = KWinComponents.Workspace.activeWindow;
        const mine = built ? cards.concat(flying).map(c => c.window) : null;   // a window we never showed stays up
        let last = null;
        for (let i = 0; i < models.count; i++) {
            const o = models.objectAt(i), w = o ? o.window : null;
            if (!w || w.deleted || w.minimized) continue;
            if (mine && mine.indexOf(w) < 0) continue;
            if (w === act) { last = w; continue; }
            w.minimized = true;
        }
        if (last && !last.minimized) last.minimized = true;
    }

    // ================= closing cards =================
    function closeCard(c, v, callClose): void {
        const i = cards.indexOf(c);
        if (i < 0) return;
        const p0 = propS(spr.s.v) + spr.pj.v, sh = i < idxAt(spr.s.t) ? 1 : 0;
        if (sh) {                  // a newer card went: renumber everything by one without moving anything on screen
            cards.concat(flying).forEach(x => { x.slot.v -= 1; x.slot.t -= 1; });
            spr.s.v -= 1; spr.s.t -= 1;
            if (gesture && gesture.s0 !== undefined) gesture.s0 -= 1;   // a held scroll keeps its place
        }
        const rest = cards.slice(); rest.splice(i, 1); cards = rest;
        flying = flying.concat([c]);
        c.closedAt = i;
        c.ty.to(-(geo.top + geo.ch + 80), ...Stack.K.fly, Math.min(v, -1800));
        rerank();                  // the cards behind (or the newer ones) slide over to close the gap
        spr.pj.jump(p0 - sh - propS(spr.s.v)); spr.pj.to(0, ...Stack.K.scroll);
        if (cards.length) spr.s.to(restS(idxAt(spr.s.t)), ...Stack.K.scroll);
        if (c === originCard) originCard = null;
        if (c === focusCard) focusCard = null;
        if (c === openTarget) { openTarget = null; leaveToDesk(); }
        if (c.item) c.item.disarm();
        if (callClose) requestClose(c);
        if (!cards.length) emptyTimer.restart();   // vivo: 「无近期应用」, then out
        kick();
    }
    function requestClose(c): void {
        c.checkAt = Date.now() + 1500;
        closeCheck.start();
        if (!c.window || c.window.deleted) return;
        if (appQuit && !c.guarded) appQuit.watch(c.window);   // a game is never quit: it runs inside Steam's unit
        c.window.closeWindow();
    }
    // a window that is still there 1.5 s after closeWindow is probably asking "save changes?" (its dialog
    // is hidden behind us): its card comes back, so the question is one tap away instead of lost
    Timer {
        id: closeCheck
        interval: 250
        repeat: true
        onTriggered: {
            const now = Date.now();
            let waiting = false;
            for (const c of root.flying.slice()) {
                if (c.gone || !c.checkAt) continue;
                if (now < c.checkAt) { waiting = true; continue; }
                if (!c.window || c.window.deleted) { c.checkAt = 0; continue; }
                // not under a finger or mid-transition: keep it due and try again (emptyTimer waits for it too)
                if (root.gesture || root.mode !== "recents") { waiting = true; continue; }
                c.checkAt = 0;
                root.reinsert(c);
            }
            if (!waiting) stop();
        }
    }
    function reinsert(c): void {
        flying = flying.filter(x => x !== c);
        c.parked = false;
        insertCard(c, Math.min(c.closedAt, cards.length));
        console.info("y700-taskswitcher: card back, its window did not close");
        toast("没关掉：它可能在问要不要保存，点开看看");
    }
    // a window that appeared while the cards are up (launched from a notification, the pad, a dialog of a
    // closing app): it gets a card, otherwise it could not be picked and leaving would minimize it unseen
    function modelAdded(index, object): void {
        if (!built || ended || !object || !object.window) return;
        if (cards.concat(flying).some(x => x.window === object.window)) return;
        if (mode !== "recents" && mode !== "desk") {   // mid-zoom: left alone (and not minimized, see minimizeAll) ...
            if (late.indexOf(object) < 0) late = late.concat([object]);
            return;
        }
        const c = makeCard(object.window, object, 0);
        c.zk = ++zTop;
        c.ty.jump(geo.H - geo.top);      // rises into its place from below
        insertCard(c, Stack.clamp(index, 0, cards.length));
        console.info("y700-taskswitcher: card added for a new window");
    }
    // ... until the stack settles (10-21 on the device: a cold Konsole mapped 3.6 s after launch, while the
    // finger was already on the edge; the cards came up without it and it sat active behind them)
    property var late: []
    onModeChanged: if (late.length && (mode === "recents" || mode === "desk")) addLate()
    function addLate(): void {
        const l = late;
        late = [];
        for (const o of l) {
            for (let i = 0; i < models.count; i++)
                if (models.objectAt(i) === o) { modelAdded(i, o); break; }   // gone meanwhile: not in the model
        }
    }
    // put c into the stack at rank i, renumbering so nothing already on screen moves
    function insertCard(c, i): void {
        const n = cards.length;
        const p0 = propS(spr.s.v) + spr.pj.v;
        const sh = n && i <= idxAt(spr.s.t) ? 1 : 0;   // a newer card comes back: renumber so nothing moves
        if (sh) {
            cards.concat(flying).forEach(x => { x.slot.v += 1; x.slot.t += 1; });
            spr.s.v += 1; spr.s.t += 1;
            if (gesture && gesture.s0 !== undefined) gesture.s0 += 1;   // a held scroll keeps its place
        }
        const next = cards.slice(); next.splice(i, 0, c); cards = next;
        c.slot.jump(i);
        c.ty.to(0, ...Stack.K.back);
        rerank();
        spr.pj.jump(p0 + sh - propS(spr.s.v)); spr.pj.to(0, ...Stack.K.scroll);
        spr.s.to(restS(idxAt(spr.s.t)), ...Stack.K.scroll);
        emptyTimer.stop();
        kick();
    }
    Timer {
        id: emptyTimer
        interval: root.reduced ? 1 : 600
        onTriggered: {
            if (root.mode !== "recents" || root.cards.length) return;
            // a window still deciding whether to close (see closeCheck) may come back: wait for it
            if (root.flying.some(c => c.checkAt && !c.gone)) { restart(); return; }
            root.leaveToDesk();
        }
    }

    function onClear(): void {
        if (mode !== "recents") return;
        if (!clearArmed) {
            clearArmed = true;
            clearTimer.restart();
            return;
        }
        clearArmed = false; clearTimer.stop();
        const keep = cards.filter(c => c.guarded), victims = cards.filter(c => !c.guarded);
        if (!victims.length) {
            toast("游戏卡片留着：要关就在卡片上划两次");
            return;
        }
        const p0 = propS(spr.s.v) + spr.pj.v;
        // renumber so the card that stays in front keeps its place on screen: it only slides to the centre
        const f = keep.reduce((a, c) => !a || Math.abs(c.slot.t - spr.s.t) < Math.abs(a.slot.t - spr.s.t) ? c : a, null);
        const off = f ? f.slot.t - keep.indexOf(f) : 0;
        cards.concat(flying).forEach(x => { x.slot.v -= off; x.slot.t -= off; });
        spr.s.v -= off; spr.s.t -= off;
        victims.forEach((c, k) => {   // all in the same frame, translate only (vivo)
            c.closedAt = cards.indexOf(c) - k;
            c.ty.to(-(geo.top + geo.ch + 80), 900, 1, -5200);
            if (c === originCard) originCard = null;
            if (c === focusCard) focusCard = null;
        });
        flying = flying.concat(victims);
        cards = keep;
        rerank();
        spr.pj.jump(p0 - off - propS(spr.s.v)); spr.pj.to(0, ...Stack.K.scroll);
        victims.forEach(c => requestClose(c));
        if (cards.length) {
            spr.s.to(restS(cards.indexOf(f)), ...Stack.K.scroll);
            toast("游戏卡片留着：要关就在卡片上划两次");
        } else {
            emptyTimer.restart();
        }
        kick();
    }
    Timer {
        id: clearTimer
        interval: 3000
        onTriggered: root.clearArmed = false
    }
    function toast(msg): void {
        toastText = msg;
        toastOn = true;
        toastTimer.restart();
    }
    Timer {
        id: toastTimer
        interval: 2600
        onTriggered: root.toastOn = false
    }

    // ================= frame =================
    function frame(): void {
        if (ended || !spr) {
            ticker.stop();
            return;
        }
        const now = clock;
        let dt = lastClock < 0 || now <= lastClock ? 1 / 60 : (now - lastClock) / 1000;
        lastClock = now;
        dt = Math.min(.05, dt);
        spr.anc.t = anchorX();       // the zoom anchor follows the card it is anchored on
        const list = [spr.s, spr.z, spr.e, spr.b, spr.h, spr.lift, spr.anc, spr.pj];
        const all = cards.concat(flying.filter(c => !c.parked));
        for (const c of all) list.push(c.slot, c.ty, c.press);
        for (const sp of list) sp.step(dt, reduced);
        let moving = false;
        for (const c of flying) {
            if (c.parked) continue;
            if (c.ty.v <= c.ty.t + 2 || c.ty.rest) park(c);
            else moving = true;
        }
        settle();
        if (ended) return;
        render();
        // a finger that moves keeps the clock going. Stopped and restarted by every touch event, it drew every
        // other one a frame late and the next one over it: a held drag looked like half the frame rate with
        // double steps (10-21, 「滑动不松手就很卡」). A finger resting 250 ms lets it stop; its next motion kicks
        const moved = gesture && Date.now() - gesture.last.t < 250;
        if (!moving && !moved && list.every(sp => sp.held || sp.rest)) ticker.stop();
    }
    // off screen: hidden, kept until its window is really gone (or comes back, see closeCheck)
    function park(c): void {
        c.parked = true;
        if (c.item) c.item.shown = false;
        if (c.gone) destroyCard(c);
    }

    function render(): void {
        const g = geo, zz = spr.z.v, L = 1 + (g.k - 1) * zz;
        const tx = -spr.anc.v * g.k * zz, ty = -g.top * g.k * zz;
        const zc = Stack.clamp(zz), ev = Stack.clamp(spr.e.v), hv = spr.h.v;
        const sEff = spr.s.v - 3 * (1 - spr.e.v), pEff = propS(spr.s.v) + spr.pj.v - 3 * (1 - spr.e.v);
        const inApp = mode === "app" && !gesture;
        const anchorCard = openTarget || focusCard;

        blurOpacity = Stack.clamp(spr.b.v);
        const hs = 1 - .22 * hv;
        layerScale = L * hs;
        layerX = workArea.x + tx * hs + g.W * (1 - hs) / 2;
        layerY = workArea.y + ty * hs + g.H * (1 - hs) * .62 + spr.lift.v;
        stackOpacity = 1 - hv;

        for (const c of cards.concat(flying)) {
            if (c.parked || !c.item) continue;
            const it = c.item;
            const d = c.slot.v - sEff, dp = c.slot.v - pEff;
            let x = Stack.xAt(g, d);
            if (d < 0) x = spr.anc.v + (x - spr.anc.v) * (1 + .35 * zc);   // newer cards pushed off to the right while zoomed
            const sc = Stack.lin(Stack.T.scale, dp) * c.press.v;
            const isFocus = c === anchorCard || (mode !== "recents" && zc > .02 && Math.abs(d) < .5);
            const hide = inApp && c !== focusCard;
            let alpha = Stack.lin(Stack.T.alpha, dp);
            if (spr.e.v < 1) alpha *= Stack.clamp(spr.e.v * 1.4);
            const y = g.top + c.ty.v;
            it.px = x;
            it.py = y;
            it.ps = sc;
            it.palpha = alpha;               // a card swiped or flying off only moves, it doesn't fade (vivo)
            // screen rect for hit testing (picture + header); off-screen cards are not drawn at all, so their
            // live thumbnails and masks cost nothing (the shadow reaches ~54 px past the picture)
            const Ls = layerScale, top = y + g.ch * (1 - sc) / 2;
            const l = layerX + x * Ls, r = layerX + (x + g.cw * sc) * Ls, m = 64 * Ls;
            it.shown = !hide && alpha > 0.001 && l - m < width && r + m > 0;
            it.zk = c.zk;
            it.pdim = Stack.lin(Stack.T.dim, dp) * (1 - zc);
            it.phead = Stack.lin(Stack.T.head, dp) * Stack.clamp(1 - zc * 1.8);
            it.pname = nameAlpha(c, dp);
            it.pshadow = Stack.lin(Stack.T.shadow, dp) * (1 - zc);
            it.pradius = isFocus ? Stack.RADIUS * (1 - zc) / Math.max(1, L) : Stack.RADIUS;
            it.pzoom = isFocus ? zc : 0;
            it.anchor = c === anchorCard;
            // not gated on the zoom alone: during an edge swipe it hovers near 0 and would reallocate the texture
            it.hires = c === anchorCard && (mode !== "recents" || zc > .001);
            c.rect = {
                l: l, r: r,
                t: layerY + (top - Stack.HEAD * sc) * Ls, b: layerY + (top + g.ch * sc) * Ls,
                z: c.zk, hidden: !it.shown,
            };
            // the header (icon, name, ▾: card-local x 9..9 + headW, y -40..-10), 6 px more each way: a tap there opens
            // its menu instead of the app; only while the header is plainly there
            c.head = it.menuable && it.phead > .5 ? {
                l: layerX + (x + 3 * sc) * Ls, r: layerX + (x + (15 + it.headW) * sc) * Ls,
                t: layerY + (top - 46 * sc) * Ls, b: layerY + (top - 4 * sc) * Ls,
                x0: layerX + (x + 9 * sc) * Ls, bot: layerY + (top - 10 * sc) * Ls,
                chev: layerX + (x + (9 + it.headW - 6) * sc) * Ls,
            } : null;
        }

        const rv = mode === "recents" || mode === "opening" || mode === "leaving"
            || (gesture && (gesture.kind === "edgeApp" || gesture.kind === "edgeDesk"));
        const ca = rv ? Stack.clamp((1 - zc) * 1.4 - .2) * Stack.clamp(ev * 1.6 - .4) : 0;
        clearOpacity = cards.length ? ca : 0;
        emptyShown = mode === "recents" && !cards.length;
        // the panel sits above a maximized app: while the app is (nearly) full screen, so does ours
        const fs = anchorCard && anchorCard.window && anchorCard.window.fullScreen;
        overPanelOpacity = anchorCard && !fs ? Stack.clamp(zc * 2 - 1) : 0;
    }

    // ================= input =================
    function hitCard(p) {
        let best = null;
        for (const c of cards) {
            const r = c.rect;
            if (r && !r.hidden && p.x >= r.l && p.x <= r.r && p.y >= r.t && p.y <= r.b && (!best || r.z > best.rect.z)) best = c;
        }
        return best;
    }
    function holdAll(on): void {
        for (const sp of [spr.s, spr.z, spr.e, spr.b, spr.anc]) {
            sp.held = on;
            if (on) sp.vel = 0;
        }
    }
    function overHead(c, p): bool {
        const h = c && c.head;
        return !!h && mode === "recents" && p.x >= h.l && p.x <= h.r && p.y >= h.t && p.y <= h.b;
    }
    // the menu under the ▾, left-aligned with the header's icon, 8 px below the header; kept on screen
    function openMenu(c): void {
        const h = c.head;
        if (!h) return;
        const mw = 150, mh = 6 + 48 + 6;
        const x = Math.max(12, Math.min(width - mw - 12, h.x0));
        const y = Math.min(height - mh - 12, h.bot + 8);
        menuRect = Qt.rect(x, y, mw, mh);
        menuOx = Math.max(0, Math.min(mw, h.chev - x));
        menuPressed = false;
        menuCard = c;
        console.info("y700-taskswitcher: menu " + Math.round(x) + "," + Math.round(y));
    }
    function closeMenu(): void {
        menuCard = null;
        menuPressed = false;
    }
    function overMenuItem(p): bool {
        const r = menuRect;
        return !!menuCard && p.x >= r.x && p.x <= r.x + r.width && p.y >= r.y + 6 && p.y <= r.y + 54;
    }
    function splitCard(c): void {
        closeMenu();
        if (!c || cards.indexOf(c) < 0) return;
        console.info("y700-taskswitcher: menu split");
        splitAfter = c;
        openCard(c, 0);
    }
    KWinComponents.DBusCall {
        id: splitShortcut
        service: "org.kde.kglobalaccel"; path: "/component/kwin"; dbusInterface: "org.kde.kglobalaccel.Component"
        method: "invokeShortcut"; arguments: ["y700-split"]
    }
    function overClear(p): bool {
        const cx = width / 2, cy = height * .904, hw = clearArmed ? 130 : 32;
        return clearOpacity > .01 && mode === "recents" && cards.length > 0
            && Math.abs(p.x - cx) <= hw && Math.abs(p.y - cy) <= 32;
    }

    // a finger on the screen (not on the edge: KWin's screen edge takes those, see edgeMove)
    function down(p): void {
        if (ended || gesture) return;
        const g = { start: p, last: p, samples: [p], kind: null, card: null, edge: false };
        if (menuCard) {        // the menu up: this finger is for it (its item, or anywhere else = close it)
            g.kind = "menu";
            menuPressed = overMenuItem(p);
        } else if (overClear(p)) {
            g.kind = "clear";
            clearPressed = true;
            glowAt = face.mapFromItem(root, p.x, p.y);
        } else if (mode === "recents" || mode === "leaving") {
            g.caught = mode === "leaving" || Math.abs(spr.s.vel) > .5;   // a tap that stops the motion is not a click
            if (mode === "leaving") {
                mode = "recents";
                spr.e.to(1, ...Stack.K.enter);
                spr.b.to(1, ...Stack.K.blur);
            }
            g.card = hitCard(p); g.kind = "pending"; g.s0 = spr.s.v;
            g.head = !g.caught && overHead(g.card, p);
            if (g.head) g.card.item.headDown = true;
            else if (g.card && !reduced) g.card.press.to(.97, ...Stack.K.press);
            spr.s.held = true; spr.s.vel = 0;
        } else {
            return;            // opening / homing: the finger only counts from the edge
        }
        gesture = g;
        kick();
    }
    function move(p): void {
        const g = gesture;
        if (!g) return;
        g.samples.push(p);
        if (g.samples.length > 30) g.samples.shift();
        const dx = p.x - g.start.x, dy = p.y - g.start.y, ddx = p.x - g.last.x;
        g.last = p;
        if (g.kind === "pending" && Math.hypot(dx, dy) > 8) {
            g.kind = Math.abs(dx) > Math.abs(dy) || !g.card ? "scroll" : "swipe";
            if (g.card) { g.card.press.to(1, ...Stack.K.press); g.card.item.headDown = false; }
            g.head = false;
            if (g.kind === "swipe") { g.card.ty.held = true; g.card.ty.vel = 0; g.ty0 = g.card.ty.v; }
        }
        if (g.kind === "scroll") {
            const raw = g.s0 + dx / geo.E, lo = restS(0), hi = restS(maxS());
            const rub = x => .42 * x / (1 + x);
            spr.s.v = raw < lo ? lo - rub(lo - raw) : raw > hi ? hi + rub(raw - hi) : raw;
            spr.s.t = spr.s.v;
        } else if (g.kind === "swipe") {
            const t = g.ty0 + dy;
            g.card.ty.v = g.card.ty.t = t > 0 ? t * .22 : t;
        } else if (g.kind === "edgeApp") {
            const up = Math.max(0, -dy), travel = height * .42;
            const p01 = up / travel;
            const zz = g.z0 - p01;                    // starts from wherever an opening card was caught
            spr.z.v = spr.z.t = zz >= 0 ? zz : -(1 - Math.exp(zz * 1.2)) * .16;   // past the stack: rubber
            const L = 1 + (geo.k - 1) * Stack.clamp(spr.z.v, -1, 1);
            spr.s.v = spr.s.t = spr.s.v + ddx / (geo.E * L);
            spr.b.v = spr.b.t = Stack.clamp(p01 * 2.6);
            spr.e.v = spr.e.t = 1;
            spr.lift.v = spr.lift.t = -Math.min(up, travel) * .32 * (1 - Stack.clamp(spr.z.v));
        } else if (g.kind === "edgeDesk") {
            const up = Math.max(0, -dy), p01 = up / 300;
            spr.e.v = spr.e.t = p01 <= 1 ? Math.max(g.e0, p01) : 1 + (1 - Math.exp(-(p01 - 1))) * .12;
            spr.s.v = spr.s.t = g.s0 + dx * .35 / geo.E;
            spr.b.v = spr.b.t = Stack.clamp(p01 * 3);
        } else if (g.kind === "edgeRecents") {
            spr.lift.v = spr.lift.t = Math.min(0, dy) * .28;
        } else if (g.kind === "clear") {
            clearPressed = overClear(p);
        } else if (g.kind === "menu") {
            menuPressed = overMenuItem(p);
        }
        kick();
        // the touch comes in after this frame's animation tick (Qt hands it over when the frame is built):
        // drawn only by the next tick, every frame of a drag would show where the finger was a frame ago
        if (!ended) render();
    }
    KWinComponents.DBusCall {
        id: dockReveal
        service: "fyi.y700.Shellbar"; path: "/Shellbar"; dbusInterface: "fyi.y700.Shellbar"; method: "reveal"
    }
    function up(p): void {
        const g = gesture;
        if (!g) return;
        if (p) g.samples.push(p);
        const last = p || g.last;
        const v = Stack.velocity(g.samples, Date.now()), sp = Math.hypot(v.x, v.y);
        gesture = null;
        holdAll(false);
        const dy = last.y - g.start.y, upAmt = -dy;
        if (closeCheck.running) closeCheck.restart();   // a card held back by the finger comes back now-ish
        if (g.kind === "clear") {
            clearPressed = false;
            if (overClear(last)) onClear();
        } else if (g.kind === "menu") {
            const c = menuCard;
            if (overMenuItem(last)) splitCard(c);
            else closeMenu();
        } else if (g.kind === "pending") {
            spr.s.held = false;
            if (g.card) { g.card.press.to(1, ...Stack.K.press); g.card.item.headDown = false; }
            if (g.caught) spr.s.to(restS(idxAt(spr.s.v)), ...Stack.K.scroll);
            else if (g.head && overHead(g.card, last)) openMenu(g.card);
            else if (g.card) openCard(g.card, 0);
            else dismiss();
        } else if (g.kind === "scroll") {
            spr.s.held = false;
            const vs = v.x / geo.E * 1000;                         // cards per second
            const base = idxAt(g.s0);
            let target = idxAt(spr.s.v + vs * .16);                 // project the flick, snap to the nearest rest
            if (target === base && Math.abs(v.x) * 1000 > 60) target = base + Math.sign(v.x);   // vivo: >60 px/s turns one card
            target = Stack.clamp(target, base - 4, base + 4);
            spr.s.to(restS(Stack.clamp(target, 0, maxS())), ...Stack.K.scroll, vs);
        } else if (g.kind === "swipe" && cards.indexOf(g.card) >= 0) {
            const c = g.card;
            c.ty.held = false;
            const dist = geo.top + geo.ch * (1 + Stack.lin(Stack.T.scale, -1)) / 2 + 3, prog = -c.ty.v / dist;   // to the card's bottom
            const commit = (v.y < -.4 && c.ty.v < -24) || prog > .5;   // vivo: half the way out, or a flick
            if (commit && c.guarded && !c.item.armed) {
                c.item.arm();
                c.ty.to(0, ...Stack.K.back, v.y * 1000);
            } else if (commit) {
                closeCard(c, v.y * 1000, true);
            } else {
                c.ty.to(0, ...Stack.K.back, v.y * 1000);
            }
        } else if (g.kind === "edgeApp") {
            spr.lift.to(0, 260, .9, v.y * 1000 * .32);
            const travel = height * .42, vz = v.y * 1000 / travel, vs = v.x * 1000 / geo.E;
            const flickUp = sp > .5 && -v.y > 1.7 * Math.abs(v.x);
            const flickSide = sp > .5 && Math.abs(v.x) > 1.7 * Math.abs(v.y);
            if ((flickUp && upAmt > 40) || upAmt > height * .55) {
                mode = "gesture";
                goHomeFromApp();
            } else if (flickSide && upAmt < travel * .5) {
                const base = idxAt(g.s0);
                let tgt = Math.round(spr.s.v + Math.sign(v.x) * .5);
                if (tgt === base) tgt = base + Math.sign(v.x);     // a sideways flick always moves at least one app
                openCard(cards[Stack.clamp(tgt, 0, maxS())] || focusCard, vs);
            } else if (upAmt > 70) {
                enterRecentsFromApp(vz, vs);
            } else {
                const back = (Math.abs(spr.s.v - g.s0) < .5 ? focusCard : cards[idxAt(spr.s.v)]) || focusCard;
                openCard(back, vs);
                // dock mode B+ (linux/dock y700-shellbar, 10-22): a short slow swipe that lands back on the same app
                // brings the dock up over it. Not running = the call fails quietly.
                if (back === focusCard && upAmt > 16) dockReveal.call();
            }
        } else if (g.kind === "edgeDesk") {
            const flickUp = sp > .5 && -v.y > 1.7 * Math.abs(v.x), flickDown = sp > .5 && v.y > 1.7 * Math.abs(v.x);
            if (!flickDown && (flickUp || spr.e.v > .38)) openRecentsFromDesk(-v.y * 1000 / 300);
            else leaveToDesk();
        } else if (g.kind === "edgeRecents") {
            spr.lift.to(0, ...Stack.K.lift);
            if (upAmt > 50 || (sp > .5 && v.y < 0)) leaveToDesk();
        }
        kick();
    }
    // the system took the touch away: undo, commit nothing
    function cancelGesture(): void {
        const g = gesture;
        if (!g) return;
        gesture = null;
        holdAll(false);
        spr.s.held = false;
        clearPressed = false;
        menuPressed = false;
        if (g.card) { g.card.press.to(1, ...Stack.K.press); g.card.ty.held = false; g.card.item.headDown = false; }
        if (g.kind === "pending" || g.kind === "scroll") spr.s.to(restS(idxAt(spr.s.v)), ...Stack.K.scroll);
        else if (g.kind === "swipe" && cards.indexOf(g.card) >= 0) g.card.ty.to(0, ...Stack.K.back);
        else if (g.kind === "edgeApp") { spr.lift.to(0, 260, .9); openCard(focusCard, 0); }
        else if (g.kind === "edgeDesk") leaveToDesk();
        else if (g.kind === "edgeRecents") spr.lift.to(0, ...Stack.K.lift);
        kick();
    }

    // ---- the bottom edge, from the C++ plugin: cumulative offsets since the finger touched it ----
    // p0: where the gesture starts in the plugin's cumulative offsets; {0,0} unless picked up late
    function edgeDown(p0): bool {
        closeMenu();
        splitAfter = null;     // 「分屏」 caught on its way: the swipe decides where it goes, split screen is off
        const p = { x: p0.x, y: p0.y, t: Date.now() };
        const g = { start: p, last: p, samples: [p], kind: null, card: null, edge: true };
        if (mode === "homing") {     // caught on its way home: it is the desktop now, and the swipe starts from there
            spr.h.jump(0); spr.z.jump(0); spr.e.jump(0); spr.b.jump(0); spr.s.jump(restS(0)); spr.pj.jump(0);
            focusCard = null; originCard = null; mode = "desk";
        }
        if (mode === "app" || mode === "opening") {      // catch it mid-flight too (first-frame interruptible)
            g.kind = "edgeApp";
            if (mode === "opening" && openTarget) { focusCard = openTarget; openTarget = null; }
            if (!focusCard) return edgeAsDesk(g);
            originCard = focusCard; mode = "gesture";
            g.z0 = spr.z.v; g.s0 = spr.s.v;
            holdAll(true); spr.h.jump(0);
        } else if (mode === "desk" || mode === "leaving") {
            return edgeAsDesk(g);
        } else if (mode === "recents") {
            g.kind = "edgeRecents";
        } else {
            return false;
        }
        gesture = g;
        kick();
        return true;
    }
    function edgeAsDesk(g): bool {
        g.kind = "edgeDesk"; mode = "gesture"; originCard = null; focusCard = null;
        g.e0 = Stack.clamp(spr.e.v); g.s0 = spr.s.v;
        spr.z.jump(0); spr.h.jump(0);
        holdAll(true);
        gesture = g;
        kick();
        return true;
    }
    property bool edgeLate: false     // the edge moved while a finger on the cards owned the input
    function edgeMove(x, y): void {
        if (ended || !spr) return;
        if (!gesture) {
            // picked up after the other finger lifted: start from here, or the stack jumps by the offset so far
            if (!edgeDown(edgeLate ? { x: x, y: y } : { x: 0, y: 0 })) return;
            edgeLate = false;
        } else if (!gesture.edge) {
            edgeLate = true;
            return;            // a finger on the cards drives it; the edge waits
        }
        move({ x: x, y: y, t: Date.now() });
    }
    function edgeUp(): void {
        edgeLate = false;
        if (ended || !spr) return;
        if (gesture && gesture.edge) {
            up(null);
        } else if (!gesture && mode === "app") {
            openCard(focusCard, 0);      // touched the edge and let go without moving: back where it was
        } else if (!gesture && mode === "desk") {
            leaveToDesk();
        }
    }

    Connections {
        target: root.state
        function onTouchPositionChanged(): void {
            if (!root.edgeOwner) return;
            root.edgeMove(root.state.touchXPosition, root.state.touchYPosition);
        }
        function onGestureInProgressChanged(): void {
            if (root.edgeOwner && !root.state.gestureInProgress) root.edgeUp();
        }
    }

    MouseArea {
        id: input
        anchors.fill: parent
        z: 10
        enabled: !root.ended
        preventStealing: true
        onPressed: (mouse) => root.down({ x: mouse.x, y: mouse.y, t: Date.now() })
        onPositionChanged: (mouse) => {
            if (root.gesture && !root.gesture.edge) root.move({ x: mouse.x, y: mouse.y, t: Date.now() });
        }
        onReleased: (mouse) => {
            if (root.gesture && !root.gesture.edge) root.up({ x: mouse.x, y: mouse.y, t: Date.now() });
        }
        onCanceled: {
            if (root.gesture && !root.gesture.edge) root.cancelGesture();
        }
    }

    // keyboard: the same springs, nothing extra; not while a finger is down
    Keys.onPressed: (event) => {
        if (root.gesture || root.ended) return;
        if (event.key === Qt.Key_Escape && root.menuCard) {
            root.closeMenu();
            event.accepted = true;
        } else if (event.key === Qt.Key_Escape) {
            root.dismiss();
            event.accepted = true;
        } else if (root.mode === "recents" && (event.key === Qt.Key_Left || event.key === Qt.Key_Right)) {
            const i = Stack.clamp(root.idxAt(root.spr.s.t) + (event.key === Qt.Key_Left ? 1 : -1), 0, root.maxS());
            root.spr.s.to(root.restS(i), ...Stack.K.scroll);
            root.kick();
            event.accepted = true;
        } else if (root.mode === "recents" && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
            root.openCard(root.cards[root.idxAt(root.spr.s.t)]);
            event.accepted = true;
        }
    }

    // called by the C++ plugin's deactivate(): our own exits come here after their animation (nothing to
    // do); anyone else (the shortcut of another effect, a D-Bus call) gets a quick fade
    function hideAnimation(): void {
        if (ended) return;
        ended = true;
        ticker.stop();
        fadeOut.start();
    }
    NumberAnimation {
        id: fadeOut
        target: root
        property: "opacity"
        to: 0
        duration: root.reduced ? 0 : 180
        easing.type: Easing.OutCubic
    }
    function instantHide(): void { state.deactivate(true); }
    function hide(): void { dismiss(); }

    // ================= scene =================
    // A panel (the dock, linux/dock) drawn on this scene. In the real scene KWin blurs what is behind the
    // dock's body (the dock asks for it: org_kde_kwin_blur, README「模糊怎么给 KWin」); a WindowThumbnail is only
    // the window's own pixels, so here the dock was see-through: clear while the cards left for the desktop,
    // frosted the moment the effect ended and KWin painted the real window (owner, 10-22: 「后台卡片回桌面的时候
    // Dock 会先透明然后才模糊」; linux/dock/tests/glass.sh and dock-glass.sh catch it). Under the thumbnail goes a
    // blurred copy of what this scene has behind the panel (source), kept to where the window has pixels: the
    // rounded body, 30 % alpha; the band outside it is transparent and stays so.
    // The blur must be as heavy as KWin's, or the dock visibly changes when the effect ends and KWin's own takes
    // over (owner, 10-22 13:10: 「从淡模糊变成浓模糊，还是会有割裂感」). KWin's at strength 12 (kwinrc
    // [Effect-blur]: 5 passes of dual kawase, offset 3, a sigma of tens of pixels) is far beyond FastBlur's 64, so
    // the scene is copied at 1/k size, blurred there (a blur of the small copy is k times one at full size) and the
    // panel's rectangle stretched back; the small copy is the whole scene, so the panel's edges get what is around
    // them, as KWin's do (its blur samples beyond the window). Calibrated in the bed (dock-glass-run.sh, 10-22) by
    // the width the blur gives a sharp step in the wallpaper (dock-glass.sh edge()) against KWin's own dock, the
    // bed's KWin at the real strength (sb-bed.sh copies [Effect-blur]): KWin 192; k 4 / radius 40 -> 118,
    // k 8 / 28 -> 131, 8 / 32 -> 158, 8 / 36 -> 181, k 6 / 44 -> 195-204 (taken). An earlier calibration (26 at
    // full size) ran the bed at KWin's default strength and by a sharpness metric that floors for any heavy
    // blur: too light, the owner saw the dock jump from it to KWin's when the effect ended.
    component PanelGlass: Item {
        id: glass
        required property QtObject modelData
        required property Item source
        property bool live: true
        readonly property real k: 6
        // modelData goes null under a live delegate: a dock unmapped while the view is up (the cards back to an
        // app hide it; KWin makes a new window when it maps again) is still in the list refreshDocks() makes
        // at windowRemoved, and when KWin then destroys it every binding below threw (journal 10-21..10-23: 219
        // TypeErrors, lines x/y/width/height/internalId). Nothing to draw for it any more, so hidden
        visible: modelData !== null
        x: modelData ? modelData.x - root.viewOrigin.x : 0
        y: modelData ? modelData.y - root.viewOrigin.y : 0
        width: modelData ? modelData.width : 0
        height: modelData ? modelData.height : 0
        ShaderEffectSource {        // the scene at 1/k
            id: behind
            width: Math.round(glass.source.width / glass.k)
            height: Math.round(glass.source.height / glass.k)
            sourceItem: glass.source
            textureSize: Qt.size(width, height)
            live: glass.live
            visible: false
        }
        FastBlur {
            id: behindBlur
            width: behind.width
            height: behind.height
            source: behind
            radius: 44          // x k: calibrated in the bed (dock-glass-run.sh) against KWin's blur at strength 12
            transparentBorder: false
            visible: false
        }
        ShaderEffectSource {        // the panel's rectangle out of the small blurred copy; the mask stretches it
            id: behindCrop
            anchors.fill: parent
            sourceItem: behindBlur
            sourceRect: Qt.rect(glass.x / glass.k, glass.y / glass.k, glass.width / glass.k, glass.height / glass.k)
            textureSize: Qt.size(Math.max(1, Math.round(glass.width / glass.k)), Math.max(1, Math.round(glass.height / glass.k)))
            live: glass.live
            smooth: true
            visible: false
        }
        KWinComponents.WindowThumbnail {   // the window's alpha, as the mask
            id: shape
            anchors.fill: parent
            wId: glass.modelData ? glass.modelData.internalId : ""   // "": a null QUuid, the thumbnail lets go
            visible: false
        }
        ThresholdMask {
            anchors.fill: parent
            source: behindCrop
            maskSource: shape
            // ThresholdMask: smoothstep(threshold*(1+spread)-spread, threshold*(1+spread), mask.a). The dock's
            // body is alpha ~0.30, its 1 px border 0.13, the rounded corners fade through 0: 0.11 / 0.10 puts the
            // ramp at 0.021-0.121, so the body and the border take the glass, the corners' antialiasing fades it
            // and nothing outside the dock gets any (0.08 / 0.5 would have let 85 % of it leak out)
            threshold: 0.11
            spread: 0.10
        }
        KWinComponents.WindowThumbnail {
            anchors.fill: parent
            wId: glass.modelData ? glass.modelData.internalId : ""   // "": a null QUuid, the thumbnail lets go
        }
    }
    // the dock's window comes and goes (hidden in an app, shown on the desktop: it is unmapped and KWin makes a
    // new window for it), also while the cards are up: minimizeAll() at the start puts the dock up, and a dock
    // that maps here joins the desktop layer at once instead of popping in when the effect ends
    Connections {
        target: KWinComponents.Workspace
        function onWindowAdded(w): void { if (root.built && w && w.dock) root.refreshDocks(); }
        function onWindowRemoved(w): void {
            if (root.built && w && w.dock) root.refreshDocks();
            if (w && w.dock) root.appDocks = root.appDocks.filter(d => d !== w);
        }
    }
    function refreshDocks(): void {
        const scr = targetScreen;
        docks = KWinComponents.Workspace.stackingOrder.filter(w => w.dock && w.output === scr && !w.minimized);
    }

    // everything under the panel-over-an-app layer, in one item: what that layer's glass blurs
    Item {
        id: below
        anchors.fill: parent
        // an opaque floor: without it a missing / still-loading wallpaper leaves the scene translucent and
        // the subpixel-antialiased labels get colour fringes (seen in the headless bed, which has no wallpaper)
        Rectangle {
            anchors.fill: parent
            color: "#16181E"
        }
        // the desktop: wallpaper + desktop icons (the plasmashell desktop window) and the panel
        Item {
            id: deskSharp
            anchors.fill: parent
            // opaque, only skipped while the blurred copy covers it. It used to crossfade (opacity 1 - blurOpacity)
            // against the copy, but an Item's opacity is applied to each descendant separately (no layer): the
            // wallpaper at 1 - b, then the panel glass at 1 - b over it, so mid-fade the sharp wallpaper showed
            // through the dock with weight b(1 - b) (the bed, 10-22: the rim at 350 while both ends sat at 2-17).
            // The copy is opaque (FastBlur with transparentBorder false), so fading only it is the same crossfade.
            visible: root.blurOpacity < 0.998
            Item {
                id: deskContent
                anchors.fill: parent
                KWinComponents.DesktopBackground {
                    id: wallpaper
                    anchors.fill: parent
                    activity: KWinComponents.Workspace.currentActivity
                    desktop: KWinComponents.Workspace.currentDesktop
                    outputName: root.targetScreen.name
                }
                Repeater {
                    model: root.docks
                    delegate: PanelGlass { source: wallpaper }
                }
            }
        }
        // blurred copy (icons blur with the wallpaper, as on vivo) + 30 % #16181E so white names stay legible
        Item {
            anchors.fill: parent
            opacity: root.blurOpacity
            visible: opacity > 0.002
            FastBlur {
                id: deskBlur
                anchors.fill: parent
                source: deskContent
                radius: 64
                transparentBorder: false
                visible: false
            }
            HueSaturation {            // the mockup's saturate(150%), so the blur doesn't go grey
                anchors.fill: parent
                source: deskBlur
                saturation: 0.5
            }
            Rectangle {
                anchors.fill: parent
                color: Qt.rgba(22 / 255, 24 / 255, 30 / 255, 0.30)
            }
        }

        // the cards; their coordinates are the work area's, zoomed onto the anchor card by the transform
        Item {
            id: stack
            x: 0
            y: 0
            width: root.geo.W
            height: root.geo.H
            opacity: root.stackOpacity
            transform: [
                Scale { xScale: root.layerScale; yScale: root.layerScale },
                Translate { x: root.layerX; y: root.layerY }
            ]
        }
    }

    // the panel above a maximized app while it is on screen (its glass blurs the app under it; the copy of the
    // scene it takes is only refreshed while this layer shows). Only the panels that were up when the effect
    // started (appDocks): minimizeAll() maps the desktop's dock at once, and that one belongs to the desktop
    // layer, not over the app (review, 10-22: with the live list it slid up over the app mid-gesture)
    Item {
        anchors.fill: parent
        opacity: root.overPanelOpacity
        visible: opacity > 0.002
        Repeater {
            model: root.appDocks
            delegate: PanelGlass { source: below; live: root.overPanelOpacity > 0.002 }
        }
    }

    // 「无近期应用」
    Text {
        renderType: Text.QtRendering   // stays sharp while the stack layer scales
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.workArea.y + root.geo.top + root.geo.ch / 2 - 16
        text: "无近期应用"
        color: Qt.rgba(1, 1, 1, 0.78)
        font.pixelSize: 20
        font.weight: Font.DemiBold
        opacity: root.emptyShown ? 1 : 0
        Behavior on opacity { enabled: !root.reduced; NumberAnimation { duration: 200 } }
    }

    // close all: a 52 px round button; the first tap turns it into a red "tap again" block for 3 s
    Item {
        id: clearButton
        x: (root.width - width) / 2
        y: root.height * .904 - height / 2
        width: face.width
        height: 52
        opacity: root.clearOpacity
        visible: opacity > 0.01
        Rectangle {
            id: face
            anchors.centerIn: parent
            height: 52
            width: root.clearArmed ? Math.max(240, clearLabel.implicitWidth + 24 + 10 + 44) : 52
            radius: root.clearArmed ? 14 : 26
            color: root.clearArmed ? Qt.rgba(1, 59 / 255, 48 / 255, 0.94) : Qt.rgba(1, 1, 1, 0.16)
            border.width: 1
            border.color: root.clearArmed ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(1, 1, 1, 0.16)
            scale: root.clearPressed && !root.reduced ? 0.94 : 1
            clip: true
            Behavior on width { enabled: !root.reduced; NumberAnimation { duration: 220; easing.type: Easing.OutQuint } }
            Behavior on radius { enabled: !root.reduced; NumberAnimation { duration: 220; easing.type: Easing.OutQuint } }
            Behavior on color { enabled: !root.reduced; ColorAnimation { duration: 150 } }
            Behavior on scale { enabled: !root.reduced; NumberAnimation { duration: 160; easing.type: Easing.OutQuint } }

            // the touch glow under the finger (mockup .glow): on at once, fades in 220 ms
            RadialGradient {
                x: root.glowAt.x - 80
                y: root.glowAt.y - 80
                width: 160
                height: 160
                opacity: root.clearPressed ? 1 : 0
                visible: opacity > 0.01
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.26) }
                    GradientStop { position: 0.5; color: Qt.rgba(1, 1, 1, 0) }
                }
                Behavior on opacity {
                    enabled: !root.reduced
                    NumberAnimation { duration: root.clearPressed ? 0 : 220 }
                }
            }
            Row {
                anchors.centerIn: parent
                spacing: root.clearArmed ? 10 : 0
                Behavior on spacing { enabled: !root.reduced; NumberAnimation { duration: 220; easing.type: Easing.OutQuint } }
                Item {       // the "x"
                    width: 24
                    height: 24
                    anchors.verticalCenter: parent.verticalCenter
                    Rectangle { anchors.centerIn: parent; width: 2; height: 17; radius: 1; color: "white"; rotation: 45; antialiasing: true }
                    Rectangle { anchors.centerIn: parent; width: 2; height: 17; radius: 1; color: "white"; rotation: -45; antialiasing: true }
                }
                Item {       // the label grows out of the X (a Text's width does not clip it, hence the wrapper)
                    anchors.verticalCenter: parent.verticalCenter
                    clip: true
                    height: clearLabel.implicitHeight
                    width: root.clearArmed ? clearLabel.implicitWidth : 0
                    opacity: root.clearArmed ? 1 : 0
                    visible: width > 0.5
                    Behavior on width { enabled: !root.reduced; NumberAnimation { duration: 220; easing.type: Easing.OutQuint } }
                    Behavior on opacity { enabled: !root.reduced; NumberAnimation { duration: 150 } }
                    Text {
                        id: clearLabel
                        renderType: Text.QtRendering   // stays sharp while the stack layer scales
                        text: "再点一次全部关闭"
                        color: "white"
                        font.pixelSize: 18
                        font.weight: Font.DemiBold
                    }
                }
            }
        }
    }

    // the header's ▾ menu (vivo's long-press menu, as linux/split's handle menu: #282828, radius 18, a row 48 high,
    // icon 16 at 20, text 15 at 46, 6 px top and bottom; in 0.3 -> 1.02 -> 1 from the ▾, out to 0.3 in 200 ms)
    Kirigami.ShadowedRectangle {
        id: menuBox
        property real s: 0.3
        x: root.menuRect.x; y: root.menuRect.y; width: root.menuRect.width; height: root.menuRect.height
        radius: 18
        color: "#282828"
        shadow.size: 22
        shadow.yOffset: 6
        shadow.color: Qt.rgba(0, 0, 0, 0.39)
        transform: Scale { origin.x: root.menuOx; origin.y: 0; xScale: menuBox.s; yScale: menuBox.s }
        opacity: 0
        visible: opacity > 0.005
        // the press: radius 12 keeps its corners inside the box's 18 at 6 px in
        Rectangle {
            visible: root.menuPressed
            x: 0; y: 6; width: parent.width; height: 48
            radius: 12
            color: Qt.rgba(1, 1, 1, 0.15)
        }
        Kirigami.Icon {
            x: 20; y: 6 + (48 - 16) / 2; width: 16; height: 16
            source: "view-split-left-right"
            isMask: true
            color: Qt.rgba(1, 1, 1, 0.9)
        }
        Text {
            renderType: Text.QtRendering
            x: 46; y: 6; height: 48
            verticalAlignment: Text.AlignVCenter
            text: "分屏"
            color: Qt.rgba(1, 1, 1, 0.9)
            font.pixelSize: 15
        }
    }
    readonly property bool menuUp: menuCard !== null
    onMenuUpChanged: {
        if (menuUp) {
            menuOut.stop();
            if (reduced) { menuBox.s = 1; menuBox.opacity = 1; return; }
            menuBox.s = 0.3; menuBox.opacity = 0; menuIn.restart();
        } else if (menuBox.opacity > 0) {
            menuIn.stop();
            if (reduced) { menuBox.opacity = 0; return; }
            menuOut.restart();
        }
    }
    SequentialAnimation {
        id: menuIn
        ParallelAnimation {
            NumberAnimation { target: menuBox; property: "s"; to: 1.02; duration: 250; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.37, 0.75, 0.46, 1, 1, 1] }
            NumberAnimation { target: menuBox; property: "opacity"; to: 1; duration: 250; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.33, 0, 0.67, 1, 1, 1] }
        }
        NumberAnimation { target: menuBox; property: "s"; to: 1; duration: 150; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.33, 0, 0.67, 1, 1, 1] }
    }
    ParallelAnimation {
        id: menuOut
        NumberAnimation { target: menuBox; property: "s"; to: 0.3; duration: 200; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.3, 0, 0.5, 1, 1, 1] }
        NumberAnimation { target: menuBox; property: "opacity"; to: 0; duration: 200; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.3, 0, 0.5, 1, 1, 1] }
    }

    // toast
    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        y: 34 + (root.toastOn || root.reduced ? 0 : -8)
        width: toastLabel.implicitWidth + 44
        height: toastLabel.implicitHeight + 24
        radius: 14
        color: Qt.rgba(28 / 255, 31 / 255, 38 / 255, 0.96)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.08)
        opacity: root.toastOn ? 1 : 0
        visible: opacity > 0.01
        Behavior on opacity { enabled: !root.reduced; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on y { enabled: !root.reduced; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Text {
            renderType: Text.QtRendering   // stays sharp while the stack layer scales
            id: toastLabel
            anchors.centerIn: parent
            text: root.toastText
            color: "white"
            font.pixelSize: 17
            font.weight: Font.Medium
        }
    }
}
