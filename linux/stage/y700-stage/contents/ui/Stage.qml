// y700-stage: Stage Manager (linux/stage/README.md, design in RESEARCH.md, the look in
// design/y700-stage-mockup.html after vivo OriginOS 原子工作台). While on, one group of one or two windows
// floats on the stage (rounded 20 by the y700_stagecorners effect, over the shellbar's blurred backdrop);
// the last 4 other groups are cards in a column on the left, in perspective; every other group is minimized.
// New window = new group on stage; tap a card = that group to the stage; drag a one-window card onto the
// stage = the pair; long press = 「拆开」/「关闭」. On the desktop (nothing staged) the column slides away:
// groups come back from the dock, the desktop and the task switcher. Off by default: the control centre's
// tile writes [Script-y700-stage] Active to kwinrc and calls y700-stage-on / -off.
// Own code (ideas from HyprKwin's stage manager, no code taken; numbers from the vivo ROM, no code taken).
import QtQuick
import Qt5Compat.GraphicalEffects
import org.kde.kwin as K
import org.kde.kirigami as Kirigami

Item {
    id: root

    // geometry (the mockup at 1600 x 1002 with a 28 status bar): the stage 220 from the left (cards at 32,
    // 172 wide, then 16), 12 under the work area's top, 16 from its right and bottom; a pair 12 apart
    readonly property int padL: 220
    readonly property int padT: 12
    readonly property int padR: 16
    readonly property int padB: 16
    readonly property int pairGap: 12
    readonly property int cardX: 32
    readonly property int cardW: 172
    readonly property int cardGap: 16
    readonly property int pairCardGap: 6
    readonly property real persp: 0.9   // a card's right edge is 0.9 of its left, towards the column's middle
    readonly property int rCard: 10
    readonly property int rStage: 20    // the effect's radius too (kwin-corners/stagecorners.cpp)
    readonly property int maxCards: 4
    readonly property int hideX: -(cardX + cardW + 40)
    // curves (vivo, [x1, y1, x2, y2, 1, 1]): the main one (card <-> stage, the column), standard, reorder,
    // press down / up (and the lift), the card left behind by a drag, the drop target, the menu in / out
    readonly property var cMain: [0.45, 0.85, 0.28, 1, 1, 1]
    readonly property var cStd: [0.33, 0, 0.67, 1, 1, 1]
    readonly property var cReord: [0.25, 0.1, 0.25, 1, 1, 1]
    readonly property var cDown: [0.25, 0.45, 0.30, 1, 1, 1]
    readonly property var cUp: [0.25, 0.45, 0.35, 1, 1, 1]
    readonly property var cDrag: [0.4, 0, 0.6, 1, 1, 1]
    readonly property var cDim: [0.28, 0.4, 0.2, 1, 1, 1]
    readonly property var cMenuIn: [0.37, 0.75, 0.46, 1, 1, 1]
    readonly property var cMenuOut: [0.3, 0, 0.5, 1, 1, 1]
    readonly property bool reduced: Kirigami.Units.longDuration < 1
    // every duration follows the system's animation speed (Kirigami's longDuration: 200 ms at 1x, read in
    // ts-bed 11-08): reduced motion = 0 = instant. DebugSpeed (ts-bed, which has no KDE platform theme for
    // Kirigami to follow): a fixed factor, to photograph a flight slowed down
    readonly property real k: Number(KWin.readConfig("DebugSpeed", 0)) || Kirigami.Units.longDuration / 200
    // flight(): how long the shellbar holds the dock (holdDock). An int property: a plain JS number goes out over
    // D-Bus as a double, and the shellbar's holdDock(int) never heard it (sb-bed 11-09)
    readonly property int holdMs: Math.round(50 + 500 * k + 400)
    // Debug=true (ts-bed only): one "state" line per change, with window captions, which may be private
    readonly property bool debug: String(KWin.readConfig("Debug", false)) === "true"

    property bool on: false
    property var groups: []         // {id, wins: [1 or 2 windows], focus}: most recent first, the staged one too
    property var staged: null       // the group on the stage; null = the desktop shows, the column goes away
    property int rev: 0             // bumped on every change of groups / staged: what the cards bind to
    property var ledger: ({})       // internalId -> {g, max}: the window as it was before the stage took it
    property var later: ({})        // off while minimized (geometry does not apply then): restored when shown
    property var hooked: ({})
    property var refitted: ({})
    property var asked: ({})        // internalId -> {key, stood, n}: what placeRest asked of a window in the column
    property var askedArea: Qt.rect(0, 0, 0, 0)
    property bool stale: false      // a new work area: the column's windows may hold an older configure (placeRest)
    property int quiet: 0           // > 0 while we minimize / place / activate ourselves
    property int seq: 0
    property var prev: null         // the group that left the stage last ...
    property real switchedAt: 0     // ... and when: a grab-back within 1 s is refused
    property real placedAt: 0
    property var curActive: null    // the active window and the one before it, followed always (quiet too):
    property var prevActive: null   // KWin hands the focus on before it tells a window was minimized
    property real actAt: 0
    property var area: Qt.rect(0, 0, 0, 0)
    property bool shown: false      // the column is up
    property int sentStage: -1      // what the shellbar was told last (-1: tell it again)
    // a flight: copies of windows flying in the overlay ({wid, icon, grp, flat, from, to, W, H}); the real
    // windows are put away under them (flyHide) and the state changes when they land (flyApply). Meanwhile the
    // column shows flyOrder, with the cards in flyHidden drawn by the copies (flyExtra: a card-to-be)
    property var flights: []
    property bool flying: false
    property var flyHide: []
    property var flyApply: null
    property var flyOrder: null
    property var flyHidden: []
    property var flyExtra: []
    // a flight interrupted by the next thing (interrupt()): where its copies are, for the next flight to take
    // them on from there ({String(wid): {r, w, flat, icon}}); only set within one turn
    property var carry: null
    property var dragGroup: null
    property point dragPos: Qt.point(0, 0)      // the finger, screen coordinates
    property point dragPress: Qt.point(0, 0)
    property point dragOrigin: Qt.point(0, 0)   // the card's top-left when it was pressed
    readonly property point ghostAt: Qt.point(dragOrigin.x + dragPos.x - dragPress.x, dragOrigin.y + dragPos.y - dragPress.y)
    readonly property var aim: (rev, dragGroup ? dropAim(dragGroup, dragPos) : null)
    property var menuGroup: null
    property var menuItems: []
    property real menuY: 0

    function log(s) { console.log("y700-stage: " + s) }
    function idOf(w) { return String(w.internalId) }
    function names(g) { return g ? g.wins.map(w => w.caption).join("+") : "-" }
    function dump(what) {
        if (debug)
            log("state " + what + " staged=" + names(staged) + " strip="
                + groups.filter(g => g !== staged).map(names).join(","))
    }
    // the app's name from "Document - App" captions, as the task cards do it (taskswitcher/ui/stack.js)
    function appName(caption) {
        const c = String(caption || "")
        const parts = c.split(/\s[—–-]\s/)
        const last = parts[parts.length - 1].trim()
        return parts.length > 1 && last.length > 0 && last.length <= 32 ? last : c
    }
    // games and streams: never resized, hidden or grouped (the same list as stack.js guarded())
    function guarded(w) {
        return /(^|\s)(steam_app_|steam_proton|gamescope|livi\b|dev\.f-io\.livi)|moonlight/i
            .test(String(w.resourceClass) + " " + String(w.desktopFileName))
    }
    function blocker(w) {   // up while it is: the column would cover it (KWin draws internal windows over all)
        const c = String(w.resourceClass)
        return !w.minimized && (w.inputMethod || c === "y700-osk" || c === "y700-control-center"
            || (c === "y700-shellbar" && w.frameGeometry.height > 200 && overStage(w)))   // the app grid
    }
    // stacked over the stage's windows: the shellbar's app grid (Top layer), not its backdrop for us (Bottom layer,
    // as big; 11-09 it counted as a blocker and hid the column the moment it came up). KWin stacks by layer
    function overStage(w) {
        const s = K.Workspace.stackingOrder, i = s.indexOf(w)
        return !staged || staged.wins.some(x => { const j = s.indexOf(x); return j >= 0 && j < i })
    }
    function homeOut() {
        const s = K.Workspace.screens
        return s.find(o => /^DSI/.test(o.name)) || s[0] || null
    }
    function calcArea() {
        const o = homeOut()
        if (!o) return Qt.rect(0, 0, 0, 0)
        const a = K.Workspace.clientArea(K.Workspace.MaximizeArea, o, K.Workspace.currentDesktop)
        return Qt.rect(a.x, a.y, a.width, a.height)
    }
    function portrait() { return area.height > area.width }
    function manageable(w) {
        const fixed = w.minSize.width > 0 && w.minSize.width === w.maxSize.width && w.minSize.height === w.maxSize.height
        return w.normalWindow && !w.transient && !w.modal && !w.skipTaskbar && !w.specialWindow && w.minimizable
            && w.resizeable && w.moveable && !fixed && !w.fullScreen && !guarded(w) && w.output === homeOut()
    }
    function groupOf(w) { return groups.find(g => g.wins.indexOf(w) >= 0) || null }
    function groupById(id) { return groups.find(g => g.id === id) || flyExtra.find(g => g.id === id) || null }
    function newGroup(w, id) { return { id: id || ++seq, wins: [w], focus: w } }
    function frame(w) { const f = w.frameGeometry; return Qt.rect(f.x, f.y, f.width, f.height) }
    function live(w) { return K.Workspace.windows.indexOf(w) >= 0 }

    // ---- geometry (screen coordinates) ----
    function stageRect() { return Qt.rect(area.x + padL, area.y + padT, area.width - padL - padR, area.height - padT - padB) }
    function midY() { return area.y + padT + (area.height - padT - padB) / 2 }   // the column is centred here
    function halfW() { return (stageRect().width - pairGap) / 2 }
    // window i of n on the stage (landscape)
    function slot(i, n) {
        const s = stageRect(), hw = Math.round(halfW())
        return n === 1 ? s : i === 0 ? Qt.rect(s.x, s.y, hw, s.height) : Qt.rect(s.x + hw + pairGap, s.y, s.width - hw - pairGap, s.height)
    }
    // a card's picture at the stage's aspect: one window 172 wide, two 83 + 6 + 83
    function cardH(n) {
        const s = stageRect()
        return n > 1 ? (cardW - pairCardGap) / 2 * s.height / halfW() : cardW * s.height / Math.max(1, s.width)
    }
    function sub(x, y, j, m) {
        const tw = (cardW - pairCardGap) / 2
        return m > 1 ? Qt.rect(x + j * (tw + pairCardGap), y, tw, cardH(2)) : Qt.rect(x, y, cardW, cardH(1))
    }
    function cardList() { return on ? groups.filter(g => g !== staged).slice(0, maxCards) : [] }
    function cardTops(order) {
        const hs = order.map(g => cardH(g.wins.length))
        let t = midY() - (hs.reduce((a, b) => a + b, 0) + cardGap * Math.max(0, hs.length - 1)) / 2
        return hs.map(h => { const r = t; t += h + cardGap; return r })
    }
    // perspective: the unit square onto a quad, as a 4 x 4 for a QML Matrix4x4 (Heckbert; the mockup's sq2quad)
    function sq2quad(p) {
        const x0 = p[0][0], y0 = p[0][1], x1 = p[1][0], y1 = p[1][1], x2 = p[2][0], y2 = p[2][1], x3 = p[3][0], y3 = p[3][1]
        const dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3, dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
        let g = 0, h = 0
        if (Math.abs(dx3) > 1e-9 || Math.abs(dy3) > 1e-9) {
            const den = dx1 * dy2 - dx2 * dy1
            g = (dx3 * dy2 - dx2 * dy3) / den
            h = (dx1 * dy3 - dx3 * dy1) / den
        }
        return { a: x1 - x0 + g * x1, b: x3 - x0 + h * x3, c: x0, d: y1 - y0 + g * y1, e: y3 - y0 + h * y3, f: y0, g: g, h: h }
    }
    function mapPt(q, u, v) { const w = q.g * u + q.h * v + 1; return [(q.a * u + q.b * v + q.c) / w, (q.d * u + q.e * v + q.f) / w] }
    function quadMatrix(p, w, h) {   // an item w x h onto the quad p
        const q = sq2quad(p)
        return Qt.matrix4x4(q.a / w, q.b / h, 0, q.c, q.d / w, q.e / h, 0, q.f, 0, 0, 1, 0, q.g / w, q.h / h, 0, 1)
    }
    // a card's trapezoid: the left edge kept, the right edge r high, towards the column's middle cy
    function trapezoid(x, y, w, h, r, cy) { return [[x, y], [x + w, cy + (y - cy) * r], [x + w, cy + (y + h - cy) * r], [x, y + h]] }
    function clamp(x) { return Math.min(1, Math.max(0, x)) }
    function lerpRect(a, b, t) {
        return Qt.rect(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.width + (b.width - a.width) * t, a.height + (b.height - a.height) * t)
    }
    // flight i at p: its matrix (overlay coordinates), radius (10 on a card, 20 on the stage), the perspective
    // of its group's bounding box (flat from window size down to a card's), where its badge goes
    function flightGeo(i, p) {
        const f = flights[i]
        if (!f) return { m: Qt.matrix4x4(), sc: 1, big: 1, rad: 0, bx: 0, by: 0, bo: 0 }
        const r = lerpRect(f.from, f.to, p)
        const R = flights.filter(x => x.grp === f.grp).map(x => lerpRect(x.from, x.to, p))
        const bx = Math.min(...R.map(q => q.x)), by = Math.min(...R.map(q => q.y))
        const bw = Math.max(...R.map(q => q.x + q.width)) - bx, bh = Math.max(...R.map(q => q.y + q.height)) - by
        const big = clamp((bw - cardW) / (halfW() - cardW))
        const pr = f.flat ? 1 : 1 - (1 - persp) * (1 - big)
        let q = [[r.x, r.y], [r.x + r.width, r.y], [r.x + r.width, r.y + r.height], [r.x, r.y + r.height]]
        if (pr < 0.9995) {
            const G = sq2quad(trapezoid(bx, by, bw, bh, pr, midY()))
            q = q.map(c => mapPt(G, (c[0] - bx) / bw, (c[1] - by) / bh))
        }
        q = q.map(c => [c[0] - area.x, c[1] - area.y])
        const sc = f.W / Math.max(1, r.width)   // the copy is drawn W x H and scaled by the matrix
        return { m: quadMatrix(q, f.W, f.H), sc: sc, big: big, rad: (rCard + (rStage - rCard) * big) * sc,
                 bx: q[3][0], by: q[3][1], bo: 1 - clamp(big * 5) }
    }

    function changed(what) {
        if (menuGroup && groups.indexOf(menuGroup) < 0) menuGroup = null
        rev++
        syncCards()
        sentStage = -1      // and again: the shellbar may have restarted since
        updateStrip()
        corners()
        dump(what)
    }
    // the card list as a ListModel moved in place, so the ListView animates the reorder
    function syncCards() {
        const want = (flying && flyOrder ? flyOrder : cardList()).map(g => g.id)
        for (let i = cardModel.count - 1; i >= 0; i--)
            if (want.indexOf(cardModel.get(i).gid) < 0) cardModel.remove(i)
        want.forEach((id, i) => {
            let j = -1
            for (let k = 0; k < cardModel.count; k++) if (cardModel.get(k).gid === id) j = k
            if (j < 0) cardModel.insert(i, { gid: id })
            else if (j !== i) cardModel.move(j, i, 1)
        })
    }
    function updateStrip() {
        const was = area
        area = calcArea()
        // the work area changed without the screen: the docked keyboard's exclusive zone came or went (11-09). KWin
        // squeezes windows that are not maximized into the smaller area and never gives the room back: lay out again
        if (on && staged && !flying && !relayout.running && !portrait() && !sameRect(was, area)) {
            place(staged)
            dump("area")
        }
        placeRest()
        const a = K.Workspace.activeWindow
        // a window over the column: the user maximized or dragged it. Not while our own placing lands (async)
        const covered = !!staged && Date.now() - placedAt > 1000
            && staged.wins.some(w => !w.minimized && w.frameGeometry.x < stageRect().x - 2)
        const why = !on ? "off" : portrait() ? "portrait" : !staged ? "desktop"
            : a && (a.fullScreen || guarded(a)) ? "fullscreen/guarded" : covered ? "covered"
            : K.Workspace.windows.some(blocker) ? "blocker" : ""
        if (shown !== (why === "")) {
            shown = why === ""
            if (on) log("strip " + (shown ? "shown" : "hidden (" + why + ")"))
        }
        // the backdrop is under every window: a keyboard or the control centre over it changes nothing
        tellShell(why === "" || why === "blocker")
    }
    // the shellbar's blurred backdrop, and its status bar see-through over it
    function tellShell(b) {
        if (sentStage === (b ? 1 : 0)) return
        sentStage = b ? 1 : 0
        shellCall.arguments = [b]
        shellCall.call()
    }
    // the windows on stage get the effect's round corners (it leaves maximized and full-screen ones square)
    function corners() {
        cornersCall.arguments = [on && staged && !portrait() ? staged.wins.map(idOf).join(" ") : ""]
        cornersCall.call()
    }

    // stage the group: its windows shown and placed first, then the old group down, so focus never wanders
    function place(g) {
        if (!g) return
        area = calcArea()
        quiet++
        g.wins.forEach((w, i) => {
            if (w.fullScreen) return
            if (portrait()) { w.setMaximize(true, true); return }   // paused: full screen, groups kept
            w.setMaximize(false, false)
            w.frameGeometry = fit(w, slot(i, g.wins.length))
        })
        quiet--
        g.wins.forEach(w => delete asked[idOf(w)])
        placedAt = Date.now()
        coverTimer.restart()
    }
    // The windows of the column stand as the stage would have them, so a card (the window's picture at the stage's
    // aspect) has no black bands. 11-10, the owner: 「键盘切出来再弹回去，它就又出现黑边了」. KWin squeezes every
    // window that is not maximized into a smaller work area (the docked keyboard, a turned screen), the minimized
    // ones too, and never gives the room back; a window that was never on the stage is still maximized (the
    // column's 220 px wider than the slot); one split off a pair keeps its half. Each showed between bands the next
    // time its card was taken. Called on every updateStrip, and at once when a minimized window's geometry changes.
    // A minimized window answers late: it commits a new size only on a frame callback, and those come only while
    // its card is taken (the live thumbnail). What it commits then may be an older request: KWin sends no new
    // configure when the size asked is the one the window still stands at (XdgSurfaceWindow::moveResizeInternal),
    // so "squeeze" and "back to full" before its first commit leave the squeeze as the last word (sb-bed 11-10: an
    // animating app at 1364x946 all through the keyboard, 1364x585 the moment the column came back). So, once in
    // each new work area (stale), a window that already stands in its slot is asked one pixel shorter and the slot
    // again: the configure that then goes out carries the size asked last (sendRoleConfigure: moveResizeGeometry),
    // the slot's, and the window stays as it is when it next draws: no squeezed frame in its card at all. And
    // whatever a window still commits that is not its slot: ask again when it has changed since it was asked; three
    // times at most for one slot in one work area (a window that will not take the size keeps its own, and nothing
    // loops).
    function near(a, b) {
        return Math.abs(a.x - b.x) < 1 && Math.abs(a.y - b.y) < 1 && Math.abs(a.width - b.width) < 1 && Math.abs(a.height - b.height) < 1
    }
    function stood(w) { const f = w.frameGeometry; return [f.x, f.y, f.width, f.height].map(Math.round).join(",") + "/" + w.maximizeMode }
    function placeRest() {
        if (!on) return
        if (!sameRect(askedArea, area)) { asked = {}; askedArea = area; stale = true }   // another work area: every window anew
        if (relayout.running || portrait()) return
        if (flying) { stripTimer.restart(); return }    // the copies in the air show the windows as they are
        const again = stale
        stale = false
        quiet++
        groups.forEach(g => {
            if (g === staged) return
            g.wins.forEach((w, i) => {
                if (!w.minimized || w.fullScreen) return
                const r = fit(w, slot(i, g.wins.length)), id = idOf(w)
                const key = [r.x, r.y, r.width, r.height].join(","), a = asked[id], was = stood(w)
                if (w.maximizeMode === 0 && near(w.frameGeometry, r)) {
                    if (!again) return
                    w.frameGeometry = Qt.rect(r.x, r.y, r.width, r.height - 1)
                    w.frameGeometry = r
                    asked[id] = { key: key, stood: was, n: 1 }
                    log("rest: " + w.resourceClass + " told again " + key)
                    return
                }
                if (a && a.key === key && (a.stood === was || a.n >= 3)) return    // no answer yet, or asked enough
                const n = a && a.key === key ? a.n + 1 : 1
                w.setMaximize(false, false)
                w.frameGeometry = r
                asked[id] = { key: key, stood: stood(w), n: n }
                log("rest: " + w.resourceClass + " #" + n + " " + was + " -> " + key)
            })
        })
        quiet--
    }
    // a window that will not go as short as its slot (11-09: Telegram, 689 at least, over the keyboard) ends on the
    // slot's bottom, where its text field is, and goes up under the status bar instead of down under the keyboard
    function fit(w, r) {
        const h = Math.max(r.height, w.minSize.height + w.frameGeometry.height - w.clientGeometry.height)
        return Qt.rect(r.x, r.y + r.height - h, r.width, h)
    }
    function sameRect(a, b) { return a.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height }
    function switchTo(g, what) {
        const old = staged
        quiet++
        g.wins.forEach(w => w.minimized = false)
        place(g)
        K.Workspace.activeWindow = g.focus && g.wins.indexOf(g.focus) >= 0 ? g.focus : g.wins[g.wins.length - 1]
        if (old && old !== g) old.wins.forEach(w => w.minimized = true)
        quiet--
        if (old !== g) { prev = old; switchedAt = Date.now() }
        staged = g
        groups = [g].concat(groups.filter(x => x !== g))
        changed(what || "switch")
    }

    function start() {
        if (on) return
        on = true
        area = calcArea()
        ledger = {}; later = {}; refitted = {}; asked = {}
        effectCall.call()   // the corners effect (kwinrc keeps it enabled; this covers a KWin that dropped it)
        // stackingOrder keeps closed windows for their close animation: after a reload our old instance's
        // internal windows too, and reading one of those (minSize) took KWin down (ts-bed 11-08)
        const ws = K.Workspace.stackingOrder.filter(w => live(w) && manageable(w)).reverse()   // top first
        ws.forEach(w => ledger[idOf(w)] = { g: frame(w), max: w.maximizeMode === 3 })
        groups = ws.map(w => newGroup(w))
        staged = null
        const act = K.Workspace.activeWindow
        const g = groups.find(x => x.wins[0] === act && !act.minimized) || groups.find(x => !x.wins[0].minimized) || null
        quiet++
        groups.forEach(x => { if (x !== g) x.wins[0].minimized = true })
        quiet--
        log("on, " + groups.length + " windows")
        if (g) switchTo(g, "on")
        else changed("on")
    }
    function restore(w, e) {
        quiet++
        if (e.max) w.setMaximize(true, true)
        else { w.setMaximize(false, false); w.frameGeometry = e.g }
        quiet--
    }
    function stop() {
        if (!on) return
        if (flying) land()
        dragGroup = null; menuGroup = null
        on = false
        let now = 0, n = 0
        for (const w of K.Workspace.windows) {
            const e = ledger[idOf(w)]
            if (!e) continue
            if (w.minimized) { later[idOf(w)] = e; n++ }
            else { restore(w, e); now++ }
        }
        ledger = {}; groups = []; staged = null; prev = null
        log("off, restored " + now + ", " + n + " when shown")
        changed("off")
    }

    function adopt(w) {
        if (!on || groupOf(w) || !live(w) || !manageable(w)) return
        retake(() => {
            ledger[idOf(w)] = { g: frame(w), max: w.maximizeMode === 3 }
            const g = newGroup(w), old = staged, fr = old ? old.wins.map(frame) : []
            groups = [g].concat(groups)
            switchTo(g, "new")
            flyOut(old, fr)
        })
    }
    function hook(w) {
        // ours (KWin internal: no app id): out of the task switcher, whose model takes every window
        if (/^y700-stage /.test(String(w.caption)) && !w.resourceClass) {
            w.skipSwitcher = true; w.skipTaskbar = true; w.skipPager = true
        }
        const id = idOf(w)
        if (hooked[id]) return
        const h = { w: w, min: () => root.onMinimized(w), max: () => root.onMaximized(w),
                    geo: () => {
                        if (!root.on) return
                        stripTimer.restart()
                        // a window of the column answered (its card is being taken): if with a stale size, the
                        // next request goes out now, so the card shows the bands for a frame or two, not 100 ms
                        if (w.minimized) Qt.callLater(root.placeRest)
                    } }
        hooked[id] = h
        w.minimizedChanged.connect(h.min)
        w.maximizedChanged.connect(h.max)
        w.frameGeometryChanged.connect(h.geo)
        w.fullScreenChanged.connect(h.geo)
    }
    // unloaded (install.sh, the next build): these connections outlive this script's objects, and every
    // minimize / maximize after it called into the dead root (TypeError ... of null, ts-bed 11-08)
    Component.onDestruction: {
        for (const id in hooked) {
            const h = hooked[id]
            h.w.minimizedChanged.disconnect(h.min)
            h.w.maximizedChanged.disconnect(h.max)
            h.w.frameGeometryChanged.disconnect(h.geo)
            h.w.fullScreenChanged.disconnect(h.geo)
        }
        // removed for good (install.sh --remove): no backdrop, no round corners left behind
        try { shellCall.arguments = [false]; shellCall.call(); cornersCall.arguments = [""]; cornersCall.call() } catch (e) {}
    }
    function onMinimized(w) {
        if (!on) {
            const e = later[idOf(w)]
            if (e && !w.minimized) { delete later[idOf(w)]; Qt.callLater(() => restore(w, e)) }
            return
        }
        if (quiet || !w.minimized || !staged || staged.wins.indexOf(w) < 0) return
        // the user minimizes the window in use (its title bar; KWin has already moved the focus on when this
        // comes). A staged window put away while its partner is in use is the task switcher's finishOpen
        // ("only the chosen app comes back"): it comes back, the pair stays
        const wasActive = curActive === w || (prevActive === w && Date.now() - actAt < 50)
        if (!wasActive) { Qt.callLater(regroup); return }
        burst.g = staged
        burst.restart()
    }
    function regroup() {
        if (!on || !staged) return
        // everything went (minimizeAll puts the partner away first, the active window last): the stage clears
        if (staged.wins.every(w => w.minimized)) { staged = null; changed("cleared"); return }
        quiet++
        staged.wins.forEach(w => w.minimized = false)
        quiet--
        dump("regroup")
    }
    // 300 ms after a staged window was minimized: all of the group down = the stage clears (home flick, show
    // desktop), the group stays whole; only some = they leave as groups of their own, the rest fills the stage
    function settle(g) {
        if (!on || g !== staged) return
        const down = g.wins.filter(w => w.minimized)
        if (!down.length) return
        if (down.length === g.wins.length) { staged = null; changed("cleared"); return }
        g.wins = g.wins.filter(w => !w.minimized)
        if (down.indexOf(g.focus) >= 0) g.focus = g.wins[0]
        const i = groups.indexOf(g)
        groups = groups.slice(0, i + 1).concat(down.map(w => newGroup(w)), groups.slice(i + 1))
        place(g)
        changed("split")
    }
    function onMaximized(w) {
        if (!on || quiet || !staged || staged.wins.indexOf(w) < 0 || portrait()) return
        // (the state comes back from the client a little later, so our own setMaximize lands here too, quiet
        // or not: in portrait that is all it can be.) Maximized by the app itself just after we placed it
        // (restoring its last state): place once more; later it is the user, and the column gives way
        // (updateStrip: covered)
        if (w.maximizeMode === 3 && Date.now() - placedAt < 2000 && !refitted[idOf(w)]) {
            refitted[idOf(w)] = true
            Qt.callLater(() => place(staged))
            dump("refit")
        }
        stripTimer.restart()
    }
    function takeActivation(w) {
        if (!on || !w || K.Workspace.activeWindow !== w) return
        if (!groupOf(w) || groupOf(w) === staged) return
        retake(() => {
            const g = groupOf(w)   // again: the flight it interrupted may have staged it
            if (!g || g === staged) return
            if (g === prev && staged && Date.now() - switchedAt < 1000) {
                quiet++
                w.minimized = true
                K.Workspace.activeWindow = staged.focus || staged.wins[0]
                quiet--
                log("grab-back refused (" + w.resourceClass + ")")
                return
            }
            const old = staged, fr = old ? old.wins.map(frame) : []
            switchTo(g, "activated")
            flyOut(old, fr)
        })
    }

    // ---- flights ----
    function flight(fl, o) {
        const c = carry
        carry = null
        if (flying && !c) land()
        let early = []   // windows to put away at once: their copies are in the air, not over them
        if (c) {
            // taken on mid-way (interrupt()): copies in this flight start from where they are now (but a drop's
            // start under the finger); the others fly on to where their groups are drawn now, a card or (o.stay)
            // the stage; a group off the column just goes. Every window with a copy stays down while it flies:
            // the interrupted flight's apply() just showed some, in this same turn, so no frame has them up
            const order = o.order || cardList(), tops = cardTops(order), hidden = (o.hidden || []).slice()
            let carried = 0
            fl.forEach(f => { const k = c[String(f.wid)]; if (k && !f.keep) f.from = k.r })
            for (const id in c) {
                const k = c[id], g = live(k.w) ? groupOf(k.w) : null
                if (!g || fl.some(f => String(f.wid) === id)) continue
                const j = g.wins.indexOf(k.w), n = g.wins.length, i = order.indexOf(g)
                const to = o.stay && g === o.stay ? slot(j, n) : i >= 0 ? sub(area.x + cardX, tops[i], j, n) : null
                if (!to) continue
                if (g !== o.stay && hidden.indexOf(g.id) < 0) hidden.push(g.id)
                fl.push({ wid: k.w.internalId, w: k.w, icon: k.icon, grp: "c" + g.id, flat: k.flat, keep: false, from: k.r, to: to })
                carried++
            }
            const hide = o.hide || []
            early = fl.filter(f => c[String(f.wid)] && live(f.w) && !f.w.minimized).map(f => f.w)
            o.hide = hide.concat(early.filter(w => hide.indexOf(w) < 0))
            o.hidden = hidden
            log("flight taken on mid-way: " + fl.length + " copies, " + carried + " carried on")
            if (!fl.length) { flights = []; land(); return }
        }
        fl.forEach(f => { const b = f.to.width >= f.from.width ? f.to : f.from; f.W = Math.max(1, b.width); f.H = Math.max(1, b.height) })
        fly.p = 0
        flights = fl
        flyHide = o.hide || []
        flyApply = o.apply || null
        flyOrder = o.order || null
        flyHidden = o.hidden || []
        flyExtra = o.extra || []
        flying = true
        syncCards()
        if (early.length) {
            quiet++
            early.forEach(w => w.minimized = true)
            quiet--
        }
        if (flyHide.length) {
            // the staged windows go down in 50 ms and the next ones come up only as the copies land: the shellbar
            // must not take that gap for the desktop (11-09: the dock slid in and out on every swap)
            holdCall.arguments = [holdMs]
            holdCall.call()
        }
        // a window still up where its copy starts: the copies' first frame over it, then it goes down (flyHold);
        // the copies already in the air just go on
        if (flyHide.some(w => early.indexOf(w) < 0)) flyHold.restart()
        else flyAnim.restart()
    }
    // the next thing while a flight is under way (a tap, a drag, a drop, a new window, one activated elsewhere):
    // its state applied now, its copies left where they are for the next flight to take on from there (carry).
    // 11-10: it used to land at once, the copies jumping to their ends (and before that the overlay took the tap)
    function interrupt() {
        if (!flying || carry) return
        const c = {}
        flights.forEach(f => c[String(f.wid)] = { r: lerpRect(f.from, f.to, fly.p), w: f.w, flat: f.flat, icon: f.icon })
        carry = c
        flyHold.stop(); flyAnim.stop()
        const apply = flyApply
        flyApply = null; flyOrder = null
        if (apply) apply()   // the windows it shows go down again in the next flight (same turn)
        flyHidden = []; flyExtra = []
    }
    function retake(fn) {
        interrupt()
        fn()
        if (!carry) return
        // nothing new flew (a tap on a card that went, the stage already had the activated one, a drag started):
        // the copies fly on to where their groups are drawn now; the staged ones come up as they land
        const st = staged
        flight([], { stay: st, order: cardList(), apply: () => {
            if (st && staged === st && groups.indexOf(st) >= 0 && st.wins.some(w => w.minimized)) switchTo(st, "landed")
        } })
    }
    function land() {
        if (!flying) return
        flyPark.restart()   // first: the overlay keeps its copies through the switch below
        flying = false
        flyHold.stop(); flyAnim.stop()
        const apply = flyApply
        flyApply = null; flyOrder = null; flyHide = []
        if (apply) apply()
        flyHidden = []; flyExtra = []
        rev++
        syncCards()
    }
    // keep: the copy starts where from says even if the window's copy was in the air (a drop: under the finger)
    function copies(ws, grp, from, to, flat, keep) {
        return ws.map((w, j) => ({ wid: w.internalId, w: w, icon: w.icon, grp: grp, flat: !!flat, keep: !!keep, from: from(w, j), to: to(w, j) }))
    }
    // g to the stage from where it is drawn now (from: its windows' rects); the staged group flies to the top card
    function swap(g, from, what, flat) {
        const old = staged && staged !== g ? staged : null
        const apply = () => {
            if (groups.indexOf(g) >= 0 && g.wins.length) switchTo(g, what)
            else if (old && groups.indexOf(old) >= 0) switchTo(old, "back")   // it closed on the way
        }
        if (reduced) { apply(); return }
        const order = (old ? [old] : []).concat(groups.filter(x => x !== old && x !== g)).slice(0, maxCards)
        let fl = []
        if (old) {
            const vis = old.wins.filter(w => !w.minimized), t = cardTops(order)[0]
            fl = copies(vis, "out", w => frame(w), w => sub(area.x + cardX, t, old.wins.indexOf(w), old.wins.length))
        }
        fl = fl.concat(copies(g.wins, "in", (w, j) => from[j], (w, j) => slot(j, g.wins.length), flat, flat))   // flat: a drop
        flight(fl, { hide: old ? old.wins.filter(w => !w.minimized) : [], apply: apply, order: order,
                     hidden: (old ? [old.id] : []).concat([g.id]) })
    }
    // the group that just left the stage (new window, activated from elsewhere) flies to its card
    function flyOut(old, fr) {
        if (reduced || !old || !shown || groups.indexOf(old) < 0) return
        const order = cardList(), i = order.indexOf(old)
        if (i < 0) return
        const t = cardTops(order)[i]
        flight(copies(old.wins, "out", (w, j) => fr[j], (w, j) => sub(area.x + cardX, t, j, old.wins.length)), { hidden: [old.id] })
    }

    // ---- the column's gestures (Card.qml); points in the strip window's coordinates ----
    function tapCard(gid, pt) {
        if (!on) return
        retake(() => {
            const g = groupById(gid)
            if (!g || groups.indexOf(g) < 0) return
            menuGroup = null
            swap(g, g.wins.map((w, j) => sub(area.x + pt.x, area.y + pt.y, j, g.wins.length)), "tap", false)
        })
    }
    function dragStart(gid, press, origin, p) {
        if (!on) return
        retake(() => {   // the drop target reads the state: a flight under way has it applied, and flies on
            const g = groupById(gid)
            if (!g || groups.indexOf(g) < 0) return
            menuGroup = null
            dragPress = Qt.point(area.x + press.x, area.y + press.y)
            dragOrigin = Qt.point(area.x + origin.x, area.y + origin.y)
            dragPos = Qt.point(area.x + p.x, area.y + p.y)
            dragGroup = g
        })
    }
    function dragMove(gid, p) { if (dragGroup) dragPos = Qt.point(area.x + p.x, area.y + p.y) }
    // where a card let go at p would land: the preview's rect and words, the windows it would push or replace
    function dropAim(g, p) {
        const s = stageRect()
        if (!g || p.x <= s.x - 8 || p.y <= area.y) return null
        const name = w => appName(w.caption)
        if (!staged) return { rect: s, dim: [], label: "打开 " + name(g.wins[0]), icons: g.wins, side: -1 }
        if (g.wins.length > 1) return { rect: s, dim: staged.wins.slice(), label: "换上这一组", icons: g.wins, side: -1 }
        const side = p.x < s.x + s.width / 2 ? 0 : 1
        if (staged.wins.length === 1)
            return { rect: slot(side, 2), dim: staged.wins.slice(), label: name(g.wins[0]) + " 放" + (side ? "右" : "左") + "边", icons: g.wins, side: side }
        return { rect: slot(side, 2), dim: [staged.wins[side]], label: "换下 " + name(staged.wins[side]), icons: g.wins, side: side }
    }
    function dragEnd(gid) {
        const g = dragGroup, p = dragPos, at = ghostAt
        dragGroup = null
        dropFade.restart()
        if (!on || !g) return
        retake(() => {   // the aim after a flight under way has its state applied (dragStart's own, a new window)
            const a = groups.indexOf(g) >= 0 ? dropAim(g, p) : null
            if (!a) return
            const from = g.wins.map((w, j) => sub(at.x, at.y, j, g.wins.length))
            if (a.side < 0) { swap(g, from, "drop", true); return }
            // one window onto the stage: the pair, on the side it was let go; a full stage gives up that side's window
            const w = g.wins[0], s = staged
            const out = s.wins.length > 1 ? s.wins[a.side] : null
            let wins = s.wins.filter(x => x !== out)
            wins = a.side === 0 ? [w].concat(wins) : wins.concat([w])
            const outG = out ? newGroup(out) : null
            const apply = () => merge(g, s, w, wins, outG)
            if (reduced) { apply(); return }
            const order = (outG ? [outG] : []).concat(groups.filter(x => x !== s && x !== g)).slice(0, maxCards)
            const vis = s.wins.filter(x => !x.minimized)
            let fl = copies([w], "in", () => from[0], () => slot(wins.indexOf(w), 2), true, true)
            fl = fl.concat(copies(vis.filter(x => x !== out), "in", x => frame(x), x => slot(wins.indexOf(x), 2), true))
            if (out) fl = fl.concat(copies([out], "out", () => frame(out), () => sub(area.x + cardX, cardTops(order)[0], 0, 1)))
            flight(fl, { hide: vis, apply: apply, order: order, hidden: [g.id].concat(outG ? [outG.id] : []), extra: outG ? [outG] : [] })
        })
    }
    function merge(g, s, w, wins, outG) {
        if (!on || groups.indexOf(s) < 0 || groups.indexOf(g) < 0 || !live(w)) {   // something closed on the way
            if (on && staged) switchTo(staged, "back")
            return
        }
        s.wins = wins.filter(live)
        s.focus = w
        groups = groups.filter(x => x !== g)
        if (outG && live(outG.wins[0])) groups = [s, outG].concat(groups.filter(x => x !== s))
        quiet++
        s.wins.forEach(x => x.minimized = false)
        place(s)
        K.Workspace.activeWindow = w
        if (outG && live(outG.wins[0])) outG.wins[0].minimized = true
        quiet--
        changed("merge")
    }
    function openMenu(gid, pt) {
        const g = groupById(gid)
        if (!on || !g || dragGroup) return
        menuItems = g.wins.length > 1 ? [["split", "拆开", "view-split-left-right"], ["sep"], ["close", "关闭", "window-close"]]
            : [["close", "关闭", "window-close"]]
        menuY = Math.max(8, Math.min(pt.y, area.height - 8 - (g.wins.length > 1 ? 112 : 60)))
        menuGroup = g
    }
    function menuDo(k) {
        const g = menuGroup
        menuGroup = null
        if (!g || groups.indexOf(g) < 0) return
        if (k === "split") {
            if (g.wins.length < 2) return
            const b = newGroup(g.wins[1]), i = groups.indexOf(g)
            g.wins = [g.wins[0]]; g.focus = g.wins[0]
            groups = groups.slice(0, i + 1).concat([b], groups.slice(i + 1))
            changed("unpair")
        } else g.wins.slice().forEach(w => w.closeWindow())
    }
    onMenuGroupChanged: {
        if (menuGroup) { menuOut.stop(); box.scale = 0.3; box.opacity = 0; menuIn.restart() }
        else if (box.opacity > 0) { menuIn.stop(); menuOut.restart() }
    }

    Component.onCompleted: {
        area = calcArea()
        K.Workspace.windows.forEach(hook)
        // KWin stacks internal windows in the order they are shown, and QML completes objects last to first:
        // left to it the strip came out on top of the overlay (the flights hidden behind it, ts-bed 11-08).
        // Shown here, after every object is complete: the overlay over the strip, the menu over both
        Qt.callLater(() => { strip.visible = true; fly.visible = true; menu.visible = true })
        log("loaded, " + (String(KWin.readConfig("Active", false)) === "true" ? "on" : "off"))
        if (String(KWin.readConfig("Active", false)) === "true") start()
        else { tellShell(false); corners() }
    }

    Connections {
        target: K.Workspace
        function onWindowAdded(w) {
            root.hook(w)
            if (root.on) Qt.callLater(() => root.adopt(w))
            stripTimer.restart()
        }
        function onWindowRemoved(w) {
            const id = root.idOf(w)
            delete root.hooked[id]; delete root.ledger[id]; delete root.later[id]; delete root.refitted[id]; delete root.asked[id]
            const g = root.groupOf(w)
            if (g) {
                g.wins = g.wins.filter(x => x !== w)
                if (g.focus === w) g.focus = g.wins[0] || null
                if (!g.wins.length) {
                    root.groups = root.groups.filter(x => x !== g)
                    if (root.staged === g) root.staged = null
                } else if (g === root.staged) root.place(g)
                root.changed("closed")
            }
            stripTimer.restart()
        }
        function onWindowActivated(w) {
            root.prevActive = root.curActive; root.curActive = w; root.actAt = Date.now()
            if (!root.on || root.quiet || !w) return
            const g = root.groupOf(w)
            if (g) g.focus = w
            if (g && g !== root.staged) Qt.callLater(() => root.takeActivation(w))
            stripTimer.restart()
        }
        function onScreensChanged() { relayout.restart() }
        function onVirtualScreenGeometryChanged() { relayout.restart() }
    }

    K.ShortcutHandler {
        name: "y700-stage-on"; text: "Y700: Stage Manager on"; sequence: ""
        onActivated: root.start()
    }
    K.ShortcutHandler {
        name: "y700-stage-off"; text: "Y700: Stage Manager off"; sequence: ""
        onActivated: root.stop()
    }
    // async, and silently nothing when the other end is not there (no shellbar in ts-bed, no effect built)
    K.DBusCall {
        id: shellCall
        service: "fyi.y700.Shellbar"; path: "/Shellbar"; dbusInterface: "fyi.y700.Shellbar"; method: "setStage"
    }
    K.DBusCall {   // flight(): ms the dock stays away although no window is up (an older shellbar: nothing)
        id: holdCall
        service: "fyi.y700.Shellbar"; path: "/Shellbar"; dbusInterface: "fyi.y700.Shellbar"; method: "holdDock"
    }
    K.DBusCall {
        id: cornersCall
        service: "org.kde.KWin"; path: "/org/y700/StageCorners"; dbusInterface: "org.y700.StageCorners"; method: "setWindows"
    }
    K.DBusCall {
        id: effectCall
        service: "org.kde.KWin"; path: "/Effects"; dbusInterface: "org.kde.kwin.Effects"; method: "loadEffect"
        arguments: ["y700_stagecorners"]
    }

    Timer { id: burst; interval: 300; property var g: null; onTriggered: root.settle(g) }
    Timer { id: stripTimer; interval: 100; onTriggered: root.updateStrip() }
    Timer { id: coverTimer; interval: 1100; onTriggered: root.updateStrip() }
    // rotation: the work area settles after the output; one layout for the lot
    Timer {
        id: relayout; interval: 300
        onTriggered: { if (root.on) { root.place(root.staged); root.updateStrip(); root.corners(); root.dump("relayout") } }
    }
    Timer {   // the overlay's first frame (copies over the windows they stand for) is up: those go down, fly
        id: flyHold; interval: 50
        onTriggered: {
            root.quiet++
            root.flyHide.forEach(w => { if (root.live(w)) w.minimized = true })
            root.quiet--
            flyAnim.restart()
        }
    }
    Timer { id: flyPark; interval: 60 }   // the landed windows draw once before the overlay goes
    Timer { id: dropFade; interval: 300 * root.k }   // the drop target fades out before the overlay goes
    NumberAnimation {
        id: flyAnim; target: fly; property: "p"; from: 0; to: 1; duration: 500 * root.k
        easing.type: Easing.BezierSpline; easing.bezierCurve: root.cMain
        onFinished: root.land()
    }
    SequentialAnimation {   // the menu from its top-left corner: 0.3 -> 1.02 -> 1
        id: menuIn
        ParallelAnimation {
            NumberAnimation { target: box; property: "scale"; to: 1.02; duration: 250 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cMenuIn }
            NumberAnimation { target: box; property: "opacity"; to: 1; duration: 250 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cStd }
        }
        NumberAnimation { target: box; property: "scale"; to: 1; duration: 150 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cStd }
    }
    ParallelAnimation {
        id: menuOut
        NumberAnimation { target: box; property: "scale"; to: 0.3; duration: 200 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cMenuOut }
        NumberAnimation { target: box; property: "opacity"; to: 0; duration: 200 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cMenuOut }
    }

    ListModel { id: cardModel }

    // the column. KWin internal windows: drawn over everything (fullscreen apps too, hence the hiding rules)
    // and parked off screen when not up (no open / close animations). Transparent: the shellbar's backdrop
    // shows through
    Window {
        id: strip
        // " on" while the stage manager is on: how y700-split (linux/split) knows to stand aside
        title: root.on ? "y700-stage strip on" : "y700-stage strip"
        transientParent: null   // declared in an Item it would get one, and never show
        flags: Qt.FramelessWindowHint | Qt.WindowDoesNotAcceptFocus | Qt.BypassWindowManagerHint
        color: "transparent"
        visible: false      // shown by Component.onCompleted, in stacking order
        x: root.shown || column.x > root.hideX + 0.5 ? root.area.x : -32000
        y: root.area.y
        width: root.padL
        height: Math.max(1, root.area.height)

        Item {
            id: column
            width: parent.width; height: parent.height
            x: root.shown ? 0 : root.hideX     // slides out to the left on the desktop, in when a group is staged
            Behavior on x { NumberAnimation { duration: 300 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cMain } }
            ListView {
                x: root.cardX; width: root.cardW
                height: contentHeight
                y: root.midY() - root.area.y - contentHeight / 2
                Behavior on y { NumberAnimation { duration: 350 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cReord } }
                interactive: false
                spacing: root.cardGap
                model: cardModel
                delegate: Card { stage: root }
                displaced: Transition { NumberAnimation { properties: "y"; duration: 350 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cReord } }
                move: Transition { NumberAnimation { properties: "y"; duration: 350 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cReord } }
                remove: Transition {   // a card leaving (its group closed, or gone to the stage): scale and opacity to 0
                    // and no more taps: it still lies under the card that comes in its place, and both TapHandlers
                    // fired (passive grabs), so a quick second tap there switched and switched back (11-10)
                    PropertyAction { property: "enabled"; value: false }
                    NumberAnimation { properties: "scale,opacity"; to: 0; duration: 400 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cStd }
                }
            }
        }
    }

    // the overlay: the drop target, flying copies, the dragged card under the finger. Taps go through it to the
    // column and the stage: outputOnly is what KWin's InternalWindow::hitTest reads (6.6); it ignores
    // Qt.WindowTransparentForInput, so until 11-10 every tap in a flight (and 0.3 s after a drop) went to the
    // overlay and nowhere: tap, tap, and only the first card came
    Window {
        id: fly
        title: "y700-stage overlay"
        transientParent: null
        flags: Qt.FramelessWindowHint | Qt.WindowDoesNotAcceptFocus | Qt.BypassWindowManagerHint | Qt.WindowTransparentForInput
        color: "transparent"
        visible: false      // shown by Component.onCompleted, in stacking order
        property bool outputOnly: true
        property real p: 0
        x: root.flying || root.dragGroup || flyPark.running || dropFade.running ? root.area.x : -32000
        y: root.area.y
        width: Math.max(1, root.area.width)
        height: Math.max(1, root.area.height)

        // the windows a drop would push or replace: 40 % black over them
        Repeater {
            model: root.on && root.staged ? (root.rev, root.staged.wins) : []
            Rectangle {
                required property var modelData
                x: modelData.frameGeometry.x - root.area.x; y: modelData.frameGeometry.y - root.area.y
                width: modelData.frameGeometry.width; height: modelData.frameGeometry.height
                radius: root.rStage
                color: "black"
                opacity: root.aim && root.aim.dim.indexOf(modelData) >= 0 ? 0.4 : 0
                visible: opacity > 0.005
                Behavior on opacity { NumberAnimation { duration: 250 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cDim } }
            }
        }
        // where it would land: a dark card with the icons and what happens
        Kirigami.ShadowedRectangle {
            id: pv
            property rect at: Qt.rect(0, 0, 0, 0)
            property var icons: []
            property string label: ""
            x: at.x - root.area.x; y: at.y - root.area.y; width: at.width; height: at.height
            Behavior on x { enabled: pv.opacity > 0.02; NumberAnimation { duration: 250 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cDim } }
            Behavior on y { enabled: pv.opacity > 0.02; NumberAnimation { duration: 250 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cDim } }
            Behavior on width { enabled: pv.opacity > 0.02; NumberAnimation { duration: 250 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cDim } }
            Behavior on height { enabled: pv.opacity > 0.02; NumberAnimation { duration: 250 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cDim } }
            opacity: root.aim ? 1 : 0
            visible: opacity > 0.005
            Behavior on opacity { NumberAnimation { duration: 250 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cDim } }
            radius: root.rStage
            color: Qt.rgba(34 / 255, 36 / 255, 42 / 255, 0.86)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.14)
            shadow.size: 30
            shadow.yOffset: 10
            shadow.color: Qt.rgba(0, 0, 0, 0.30)
            Column {
                anchors.centerIn: parent
                spacing: 12
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 14
                    Repeater {
                        model: pv.icons
                        Kirigami.Icon { required property var modelData; width: 50; height: 50; source: modelData.icon }
                    }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: pv.label
                    color: Qt.rgba(1, 1, 1, 0.6)
                    font.pixelSize: 15
                }
            }
        }
        Connections {
            target: root
            function onAimChanged() { if (root.aim) { pv.at = root.aim.rect; pv.icons = root.aim.icons; pv.label = root.aim.label } }
        }
        // flying copies: drawn W x H (the larger end, so their layers are allocated once) and taken to where
        // they are by a perspective matrix; rounded and shadowed in their own coordinates
        Repeater {
            model: root.flying || flyPark.running ? root.flights : []
            Item {
                id: fc
                required property var modelData
                required property int index
                readonly property var g: root.flightGeo(index, fly.p)
                width: modelData.W; height: modelData.H
                transform: Matrix4x4 { matrix: fc.g.m }
                Kirigami.ShadowedRectangle {
                    anchors.fill: parent
                    radius: fc.g.rad
                    color: "#111"
                    shadow.size: fc.g.big > 0.01 ? 40 * fc.g.sc : 0     // none on a card (a huge quad for nothing)
                    shadow.yOffset: 12 * fc.g.sc
                    shadow.color: Qt.rgba(0, 0, 0, 0.32 * fc.g.big)
                }
                Item {
                    anchors.fill: parent
                    layer.enabled: true
                    layer.effect: OpacityMask { maskSource: Rectangle { width: fc.width; height: fc.height; radius: fc.g.rad } }
                    K.WindowThumbnail { anchors.fill: parent; wId: fc.modelData.wid }
                }
            }
        }
        Repeater {   // their badges, flat, fading out as a copy grows past a card
            model: root.flying || flyPark.running ? root.flights : []
            Card.Badge {
                required property var modelData
                required property int index
                readonly property var g: root.flightGeo(index, fly.p)
                x: g.bx - 5; y: g.by + 5 - 30
                opacity: g.bo
                visible: opacity > 0.01
                source: modelData.icon
            }
        }
        // the dragged card: a flat copy that keeps where the finger took it
        Item {
            visible: !!root.dragGroup
            x: root.ghostAt.x - root.area.x
            y: root.ghostAt.y - root.area.y
            Repeater {
                model: root.dragGroup ? root.dragGroup.wins : []
                Item {
                    id: ghostCopy
                    required property var modelData
                    required property int index
                    readonly property rect r: root.sub(0, 0, index, root.dragGroup ? root.dragGroup.wins.length : 1)
                    x: r.x; y: r.y; width: r.width; height: r.height
                    Kirigami.ShadowedRectangle {
                        anchors.fill: parent
                        radius: root.rCard
                        color: "#111"
                        shadow.size: 34
                        shadow.yOffset: 14
                        shadow.color: Qt.rgba(0, 0, 0, 0.45)
                    }
                    Item {
                        anchors.fill: parent
                        layer.enabled: true
                        layer.effect: OpacityMask { maskSource: Rectangle { width: ghostCopy.width; height: ghostCopy.height; radius: root.rCard } }
                        K.WindowThumbnail { anchors.fill: parent; wId: ghostCopy.modelData.internalId }
                    }
                    Card.Badge { x: -5; y: ghostCopy.height + 5 - 30; source: ghostCopy.modelData.icon }
                }
            }
        }
    }

    // the long-press menu, right of its card (vivo's workbench menu); a tap anywhere else closes it
    Window {
        id: menu
        title: "y700-stage menu"
        transientParent: null
        flags: Qt.FramelessWindowHint | Qt.WindowDoesNotAcceptFocus | Qt.BypassWindowManagerHint
        color: "transparent"
        visible: false      // shown by Component.onCompleted, in stacking order
        x: root.menuGroup || menuOut.running ? root.area.x : -32000
        y: root.area.y
        width: Math.max(1, root.area.width)
        height: Math.max(1, root.area.height)

        MouseArea { anchors.fill: parent; onPressed: root.menuGroup = null }
        Kirigami.ShadowedRectangle {
            id: box
            x: root.cardX + root.cardW + 10; y: root.menuY
            width: 132; height: rows.height + 12
            radius: 18
            color: "#282828"
            shadow.size: 22
            shadow.yOffset: 6
            shadow.color: Qt.rgba(0, 0, 0, 0.39)
            transformOrigin: Item.TopLeft
            scale: 0.3; opacity: 0      // menuIn / menuOut
            visible: opacity > 0.005
            Column {
                id: rows
                y: 6; width: parent.width
                Repeater {
                    model: root.menuItems
                    Item {
                        id: row
                        required property var modelData
                        readonly property bool sep: modelData[0] === "sep"
                        width: rows.width; height: sep ? 4 : 48
                        Rectangle { visible: row.sep; anchors.fill: parent; color: Qt.rgba(1, 1, 1, 0.05) }
                        Rectangle {
                            visible: ma.pressed
                            x: 6; width: parent.width - 12; height: parent.height; radius: 12
                            color: Qt.rgba(1, 1, 1, 0.15)
                        }
                        Kirigami.Icon {
                            visible: !row.sep
                            x: 20; y: (parent.height - 16) / 2; width: 16; height: 16
                            source: row.modelData[2] || ""
                            isMask: true
                            color: Qt.rgba(1, 1, 1, 0.9)
                        }
                        Text {
                            visible: !row.sep
                            x: 44; height: parent.height
                            verticalAlignment: Text.AlignVCenter
                            text: row.modelData[1] || ""
                            color: Qt.rgba(1, 1, 1, 0.9)
                            font.pixelSize: 15
                        }
                        MouseArea { id: ma; enabled: !row.sep; anchors.fill: parent; onClicked: root.menuDo(row.modelData[0]) }
                    }
                }
            }
        }
    }
}
