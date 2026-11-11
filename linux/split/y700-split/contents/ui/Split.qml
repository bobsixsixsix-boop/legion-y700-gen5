// y700-split: split screen on the normal desktop, the Stage Manager off (linux/split/README.md; the look, the
// numbers and the behaviour in design/y700-split-mockup.html, after vivo OriginOS 分屏).
// Two real windows side by side (one above the other in portrait) in KWin's own geometry - so the apps' own drag
// and drop works between them - 6 px apart, round corners 10. The gap and the corners are painted by the
// y700_stagecorners effect (setSplitWindows, setSplitChrome: under every other window, not an overlay of ours,
// which KWin would draw over the dock, banners and menus). A handle on the gap moves it (snaps 30 / 50 / 70 %; to
// an end = the other one full); a tap on it opens 「对调应用」/「退出分屏」. Ways in: a title bar dragged to the left
// or right edge (top or bottom in portrait), and the shortcut y700-split (the control centre's 「分屏」 tile, the
// task cards' ▾ 「分屏」): the active app to the left half. The other half shows 「选择另一个应用」 (the open
// windows and the dock's apps) until one is chosen. While the Stage Manager is on this script stands aside (a
// group of two on its stage is split already). Own code; numbers from the vivo ROM (names and numbers only).
import QtQuick
import Qt5Compat.GraphicalEffects
import org.kde.kwin as K
import org.kde.kirigami as Kirigami

Item {
    id: root

    // ---- numbers (the mockup's table: vivo's unless it says otherwise) ----
    readonly property int gap: 6
    readonly property int rHalf: 10
    readonly property int rFloat: 16    // the card under the finger (vivo 电脑模式小窗)
    readonly property int rThumb: 13    // a thumbnail in the picker, the drop hint
    readonly property int pvIn: 10
    readonly property int edge: 36
    readonly property int slop: 8
    readonly property var snaps: [0, 0.3, 0.5, 0.7, 1]
    readonly property real dimMax: 0.6
    readonly property real dimDrag: 0.4
    // curves (vivo, [x1, y1, x2, y2, 1, 1]): into split screen, swap, snap, standard, the dim layer, press down /
    // up, the menu in / out, the toast
    readonly property var cEnter: [0.37, 0.75, 0.48, 1, 1, 1]
    readonly property var cSwap: [0.45, 0.85, 0.28, 1, 1, 1]
    readonly property var cSnap: [0.28, 0.4, 0.2, 1, 1, 1]
    readonly property var cStd: [0.33, 0, 0.67, 1, 1, 1]
    readonly property var cDim: [0.28, 0.4, 0.2, 1, 1, 1]
    readonly property var cDown: [0.25, 0.45, 0.30, 1, 1, 1]
    readonly property var cUp: [0.25, 0.45, 0.35, 1, 1, 1]
    readonly property var cMenuIn: [0.37, 0.75, 0.46, 1, 1, 1]
    readonly property var cMenuOut: [0.3, 0, 0.5, 1, 1, 1]
    readonly property var cToast: [0.23, 1, 0.32, 1, 1, 1]
    readonly property bool reduced: Kirigami.Units.longDuration < 1
    // every duration follows the system's animation speed (as y700-stage: Kirigami's longDuration, 200 ms at 1x);
    // DebugSpeed (ts-bed): a fixed factor
    readonly property real k: Number(KWin.readConfig("DebugSpeed", 0)) || Kirigami.Units.longDuration / 200
    // Debug=true (ts-bed only): one "state" line per change, with window captions, which may be private
    readonly property bool debug: String(KWin.readConfig("Debug", false)) === "true"

    // ---- state ----
    property string mode: "off"     // "off" | "pick" (one app on its half, the picker on the other) | "split"
    property var pair: []           // split: [left / top, right / bottom]
    property real ratio: 0.5        // the first one's share of the length
    property var pickWin: null      // pick: the app on its half ...
    property int pickSide: 0        // ... which half
    property bool stageOn: false    // the Stage Manager is on (its strip's caption says so): hands off
    property var ledger: ({})       // internalId -> {g, max}: the window as it was before split screen took it
    property var later: ({})        // left split screen minimized: put back as it was when shown
    property var hooked: ({})
    property var hidden: ({})       // internalId -> {w, o}: made see-through by a flight (put back on unload)
    property var refitted: ({})
    property int quiet: 0           // > 0 while we minimize / place / activate ourselves
    property real placedAt: 0
    property var area: Qt.rect(0, 0, 0, 0)
    property int rev: 0
    property var curActive: null    // the active window and the one before it, followed always (quiet too):
    property var prevActive: null   // KWin hands the focus on before it tells a window was minimized
    property real actAt: 0
    property string sentIds: "-"
    property string sentChrome: "-"
    property real tileAsked: 0      // the shortcut came with no app up: the next one activated within 1 s
    // a title bar drag: {w, kind: "card" (maximized, or one of ours: a card under the finger) | "free", from:
    // "full" | "split" | "pick", f0, p, zone, ...}; the copy that follows the finger is `card`
    property var drag: null
    property string dragKind: ""
    property bool cardUp: false
    // the handle held: {p0, r0, r, moved, len}; divMoved: the windows went under still copies
    property var div: null
    property bool divOn: false
    property bool divMoved: false
    property real divR: 0.5         // where the overlay draws the handle (the drag, a snap, a swap)
    property bool ovHandle: false
    property real pill: 0
    property int guideSide: 0
    property bool guideOn: false
    // flights: copies of windows moving in the overlay, the real windows put away under them (see fly())
    property var fl: null
    property bool flying: false
    property real flyP: 0
    property real parkK: 1          // the copies fade out over the windows shown again (finish)
    property real ovBgK: 0          // the overlay's #242424 ground under the copies
    property bool gripShown: false
    property bool barShown: false
    property bool blocked: false    // a keyboard, the control centre or the app grid is up: the picker waits
    // the picker
    property var opened: []
    property var dockApps: []
    property var others: []
    property string wallUrl: ""
    property real pkO: 0
    property int pkRev: 0
    property var pending: null      // an app launched from it: {id, at}
    property rect splashFrom: Qt.rect(0, 0, 0, 0)
    property string splashIcon: ""
    property real splashP: 0
    property real splashO: 0
    // drop hint, dim layer, menu, toast
    property bool pvOn: false
    property rect pvRect: Qt.rect(0, 0, 0, 0)
    property string pvLabel: ""
    property var pvIcon: ""
    property real dimK: 0
    property bool menuOpen: false
    property var menuItems: []
    property rect menuBox: Qt.rect(0, 0, 150, 112)
    property point menuOrigin: Qt.point(0, 56)
    property string toastText: ""
    property bool toastShown: false

    function log(s) { console.log("y700-split: " + s) }
    function idOf(w) { return String(w.internalId) }
    function name(w) { return w ? String(w.caption) : "-" }
    function dump(what) {
        if (debug)
            log("state " + what + " mode=" + mode + " pair=" + pair.map(name).join("+") + " pick=" + name(pickWin)
                + "/" + pickSide + " r=" + ratio.toFixed(2))
    }
    // the app's name from "Document - App" captions (as y700-stage and the task cards)
    function appName(caption) {
        const c = String(caption || "")
        const parts = c.split(/\s[—–-]\s/)
        const last = parts[parts.length - 1].trim()
        return parts.length > 1 && last.length > 0 && last.length <= 32 ? last : c
    }
    // games and streams: never resized (the same list as y700-stage and the task cards)
    function guarded(w) {
        return /(^|\s)(steam_app_|steam_proton|gamescope|livi\b|dev\.f-io\.livi)|moonlight/i
            .test(String(w.resourceClass) + " " + String(w.desktopFileName))
    }
    function ours(w) { return /^y700-split /.test(String(w.caption)) && !w.resourceClass }
    function shellPart(w) { return /^y700-(control-center|osk|shellbar)$/.test(String(w.resourceClass)) }
    function blocker(w) {
        const c = String(w.resourceClass)
        return !w.minimized && !w.deleted && (w.inputMethod || c === "y700-osk" || c === "y700-control-center"
            || (c === "y700-shellbar" && w.frameGeometry.height > 200))   // the app grid (the stage's backdrop: stage on)
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
    function manageable(w) {
        const fixed = w.minSize.width > 0 && w.minSize.width === w.maxSize.width && w.minSize.height === w.maxSize.height
        return !w.deleted && w.normalWindow && !w.transient && !w.modal && !w.skipTaskbar && !w.specialWindow
            && w.minimizable && w.resizeable && w.moveable && !fixed && !w.fullScreen && !guarded(w) && !shellPart(w)
            && w.output === homeOut()
    }
    function frame(w) { const f = w.frameGeometry; return Qt.rect(f.x, f.y, f.width, f.height) }
    function live(w) { return !!w && K.Workspace.windows.indexOf(w) >= 0 }
    function clamp(x, a, b) { return Math.min(b === undefined ? 1 : b, Math.max(a === undefined ? 0 : a, x)) }
    function lerpRect(a, b, t) {
        return Qt.rect(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.width + (b.width - a.width) * t, a.height + (b.height - a.height) * t)
    }
    function inset(r, d) { return Qt.rect(r.x + d, r.y + d, r.width - 2 * d, r.height - 2 * d) }
    function inside(p, r) { return p.x >= r.x && p.x < r.x + r.width && p.y >= r.y && p.y < r.y + r.height }
    function meets(a, b) { return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height }
    function sameRect(a, b) { return a.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height }
    function near(a, b) {
        return Math.abs(a.x - b.x) < 2 && Math.abs(a.y - b.y) < 2 && Math.abs(a.width - b.width) < 2 && Math.abs(a.height - b.height) < 2
    }

    // ---- geometry (screen coordinates): the work area cut in two along its length, 6 apart ----
    function land() { return area.width >= area.height }
    function len() { return (land() ? area.width : area.height) - gap }
    function halves(r) {
        const L = len(), a = Math.round(L * r)
        return land() ? [Qt.rect(area.x, area.y, a, area.height), Qt.rect(area.x + a + gap, area.y, L - a, area.height)]
                      : [Qt.rect(area.x, area.y, area.width, a), Qt.rect(area.x, area.y + a + gap, area.width, L - a)]
    }
    function gapAt(r) {
        const h = halves(r)[0]
        return land() ? Qt.rect(h.x + h.width, area.y, gap, area.height) : Qt.rect(area.x, h.y + h.height, area.width, gap)
    }
    function gripRect(r) {   // the handle's touch target (vivo 48 x 80) and its pill (20 x 90): 48 x 90
        const g = gapAt(r), L = land(), w = L ? 48 : 90, h = L ? 90 : 48
        return Qt.rect(Math.round(g.x + g.width / 2 - w / 2), Math.round(g.y + g.height / 2 - h / 2), w, h)
    }
    // the narrowest frame the window takes (its client's minimum and the decoration)
    function minLen(w) {
        const f = w.frameGeometry, c = w.clientGeometry
        return land() ? w.minSize.width + f.width - c.width : w.minSize.height + f.height - c.height
    }
    function fitsAt(w, i, r) { const h = halves(r)[i]; return minLen(w) <= (land() ? h.width : h.height) + 1 }
    // the snap a handle let go at r goes to: the nearest of 30 / 50 / 70 % both windows fit at, or an end
    function nearestFit(r) {
        const ok = snaps.filter(t => t === 0 || t === 1 || (fitsAt(pair[0], 0, t) && fitsAt(pair[1], 1, t)))
        return ok.reduce((a, b) => Math.abs(b - r) < Math.abs(a - r) ? b : a)
    }
    // a window that will not go as short as its half (a docked keyboard's work area) ends on the half's bottom, where
    // its text field is, and goes up under the status bar instead (as y700-stage fit())
    function fitH(w, r) {
        const h = Math.max(r.height, w.minSize.height + w.frameGeometry.height - w.clientGeometry.height)
        return Qt.rect(r.x, r.y + r.height - h, r.width, h)
    }

    function changed(what) {
        rev++
        sync()
        gripTimer.restart()
        dump(what)
    }
    // the effect: round corners on the windows split screen holds, and its ground (the gap, around the corners)
    function chromeOn() {
        if (stageOn || divMoved || (fl && fl.o.bg !== "none")) return false
        if (mode === "split") return pair.some(w => live(w) && !w.minimized)
        return mode === "pick" && live(pickWin) && !pickWin.minimized
    }
    function sync() {
        const ids = stageOn ? "" : mode === "split" ? pair.filter(live).map(idOf).join(" ") : mode === "pick" && live(pickWin) ? idOf(pickWin) : ""
        if (ids !== sentIds) { sentIds = ids; cornersCall.arguments = [ids]; cornersCall.call() }
        const c = chromeOn() ? [area.x, area.y, area.width, area.height].map(Math.round).join(" ") : ""
        if (c !== sentChrome) { sentChrome = c; chromeCall.arguments = [c]; chromeCall.call() }
    }

    function place() {
        area = calcArea()
        quiet++
        if (mode === "split") { const H = halves(ratio); pair.forEach((w, i) => put(w, H[i])) }
        else if (mode === "pick" && pickWin) put(pickWin, halves(0.5)[pickSide])
        quiet--
        placedAt = Date.now()
    }
    function put(w, r) {
        if (!live(w) || w.fullScreen) return
        w.setMaximize(false, false)
        w.frameGeometry = fitH(w, r)
    }
    function restore(w, e) {
        if (!live(w)) return
        quiet++
        if (!e || e.max) w.setMaximize(true, true)
        else { w.setMaximize(false, false); w.frameGeometry = e.g }
        quiet--
    }
    function hide(w) {
        if (!live(w)) return
        const id = idOf(w)
        if (!hidden[id]) hidden[id] = { w: w, o: w.opacity > 0.01 ? w.opacity : 1 }
        w.opacity = 0
    }
    function show(w) {
        if (!w) return
        const id = idOf(w), h = hidden[id]
        if (!h) return
        delete hidden[id]
        if (live(w)) w.opacity = h.o
    }

    // ---- into and out of split screen ----
    // the shortcut (control centre tile, task cards' ▾): the active app to the left half, the picker on the right
    function tile() {
        if (stageOn) { toast("台前调度开着，把卡片拖到舞台上就能并排"); return }
        if (fl) finish()
        const a = K.Workspace.activeWindow
        if (mode === "pick" || (mode === "split" && a && pair.indexOf(a) >= 0 && !a.minimized)) { toast("已经在分屏里了"); return }
        if (!a || a.minimized || !manageable(a)) {
            // the curtain or the cards are still on their way out: the app they leave to comes up in a moment
            if (!tileAsked) { tileAsked = Date.now(); tileWait.restart() }
            return
        }
        tileAsked = 0
        tileWait.stop()
        if (mode === "split") dropPair()   // an older pair under this app: back as they were
        enterPick(a, 0, false, null)
    }
    function enterPick(w, side, fromCard, e0) {
        const H = halves(0.5)
        if (minLen(w) > (land() ? H[side].width : H[side].height) + 1) { toast("这个应用不支持分屏"); return false }
        ledger[idOf(w)] = e0 || { g: frame(w), max: w.maximizeMode === 3 }
        const from = fromCard ? card.r : frame(w)
        mode = "pick"; pickWin = w; pickSide = side; ratio = 0.5; pair = []
        refitted = {}
        loadPicker()
        fly([{ c: fromCard ? card : copyA, w: w, from: from, to: H[side], r0: fromCard ? card.rad : (w.maximizeMode === 3 ? 0 : rHalf),
               r1: rHalf, live: !!fromCard, cover: !!fromCard, fresh: !fromCard, sh1: 0 }],
            { dur: 300, curve: cEnter, bg: fromCard ? "fade" : "jump", hold: !fromCard,
              apply: () => { quiet++; w.minimized = false; place(); K.Workspace.activeWindow = w; quiet-- } })
        pkIn.restart()
        changed("pick")
        return true
    }
    // the other half's app: from a thumbnail of the picker (from: its rect on screen), or activated elsewhere / just
    // launched (from null: it is placed under the picker, which goes once it has drawn at its new size)
    function choose(w2, from) {
        if (mode !== "pick" || !live(pickWin) || !live(w2) || w2 === pickWin || !manageable(w2)) return
        const side = 1 - pickSide, H = halves(0.5)
        if (minLen(w2) > (land() ? H[side].width : H[side].height) + 1) { toast("这个应用不支持分屏"); return }
        if (fl) finish()
        ledger[idOf(w2)] = { g: frame(w2), max: w2.maximizeMode === 3 }
        pair = side === 0 ? [w2, pickWin] : [pickWin, w2]
        mode = "split"
        pending = null; launchT.stop()
        const apply = () => { quiet++; w2.minimized = false; place(); K.Workspace.activeWindow = w2; quiet-- }
        fly([from ? { c: cP, w: w2, from: from, to: H[side], r0: rThumb, r1: rHalf, live: true, cover: true }
                  : { c: null, w: w2, to: H[side] }],
            { dur: from ? 300 : 0, curve: cEnter, bg: "none", hold: !!from, wait: from ? 400 : 700, apply: apply,
              done: () => pkOut.restart() })
        changed("choose")
    }
    function launch(a, r) {
        if (mode !== "pick") return
        pending = { id: String(a.id), at: Date.now() }
        splashFrom = r; splashIcon = String(a.icon || ""); splashO = 1
        splashAnim.restart()
        launchCall.arguments = [String(a.id)]
        launchCall.call()
        launchT.restart()
        log("launch " + a.id)
    }
    // a tap on the picker's blank: the app back to full screen
    function cancelPick(fromCard) {
        if (mode !== "pick" || !live(pickWin)) return
        const w = pickWin, e = ledger[idOf(w)]
        if (fl) finish()
        mode = "off"; pickWin = null; pending = null; launchT.stop(); ledger = {}
        pkOut.restart()
        fly([{ c: fromCard ? card : copyA, w: w, from: fromCard ? card.r : frame(w), to: e && !e.max ? e.g : area,
               r0: fromCard ? card.rad : rHalf, r1: 0, live: !!fromCard, cover: !!fromCard, fresh: !fromCard, sh1: 0 }],
            { dur: 300, curve: cEnter, bg: "jump", hold: !fromCard, apply: () => { restore(w, e); K.Workspace.activeWindow = w } })
        changed("cancel")
    }
    // the app on its half minimized or closed: nothing to pick for
    function leavePick(why) {
        const w = pickWin, e = w ? ledger[idOf(w)] : null
        mode = "off"; pickWin = null; pending = null; launchT.stop(); ledger = {}
        pkOut.restart()
        if (live(w)) { if (w.minimized) later[idOf(w)] = e || { max: true }; else restore(w, e) }
        changed("pick " + why)
    }
    // split screen ends with w full. how: "menu" (退出分屏), "title" (its title bar dragged to the top), "dismiss"
    // (the handle to an end: the other one put away, still open), "closed" (the other one closed), "maximized"
    // (the user maximized w: nothing to fly)
    function leaveTo(w, how) {
        const i = pair.indexOf(w)
        if (mode !== "split" || i < 0) return
        if (fl) finish()
        const o0 = pair[1 - i], o = how === "closed" || !live(o0) ? null : o0
        const ew = ledger[idOf(w)] || null, eo = o ? (ledger[idOf(o)] || null) : null
        const full = ew && !ew.max ? ew.g : area
        mode = "off"; pair = []; ledger = {}
        const apply = () => {
            quiet++
            if (o) {
                if (how === "dismiss" || o.minimized) { if (!o.minimized) o.minimized = true; later[idOf(o)] = eo || { max: true } }
                else restore(o, eo)
            }
            restore(w, ew)
            K.Workspace.activeWindow = w
            quiet--
        }
        if (how === "maximized") { apply(); changed("exit " + how); return }
        let items
        if (how === "dismiss") {   // the copies are up already (the handle's): the squeezed one slides off its edge
            const cw = i === 0 ? copyA : copyB, co = i === 0 ? copyB : copyA, R = co.r
            const off = land() ? Qt.rect(i === 0 ? area.x + area.width : area.x, R.y, 0, R.height)
                               : Qt.rect(R.x, i === 0 ? area.y + area.height : area.y, R.width, 0)
            items = [{ c: cw, w: w, from: cw.r, to: full, r0: rHalf, r1: 0, fresh: false, dim1: 0 }]
            if (o) items.push({ c: co, w: o, from: co.r, to: off, r0: rHalf, r1: rHalf, fresh: false, dim1: 0, wait: false })
        } else {
            items = [how === "title" ? { c: card, w: w, from: card.r, to: full, r0: card.rad, r1: 0, live: true, cover: true, fresh: false, sh1: 0 }
                                     : { c: copyA, w: w, from: frame(w), to: full, r0: rHalf, r1: 0 }]
            if (o) items.push({ c: copyB, w: o, from: frame(o), to: frame(o), r0: rHalf, r1: rHalf, fade1: 0, wait: false })
        }
        fly(items, { dur: how === "dismiss" ? 350 : 300, curve: how === "dismiss" ? cSnap : cEnter, bg: "jump",
                     hold: how !== "dismiss", apply: apply })
        changed("exit " + how)
    }
    // no flight: the pair (or the picked one) back as they were - the shortcut over another app, the stage manager
    // coming on (hands off: the stage takes the windows as they stand), unload
    function dropPair(keep) {
        if (fl) finish()
        const ws = mode === "split" ? pair.slice() : mode === "pick" && pickWin ? [pickWin] : []
        const led = ledger
        mode = "off"; pair = []; pickWin = null; pending = null; ledger = {}
        if (pkO > 0) pkOut.restart()
        if (!keep) ws.forEach(w => { if (!live(w)) return; if (w.minimized) later[idOf(w)] = led[idOf(w)] || { max: true }; else restore(w, led[idOf(w)]) })
        changed("dropped")
    }
    function swapPair(byCard) {
        if (mode !== "split") return
        if (fl) finish()
        const H = halves(ratio), a = pair[0], b = pair[1]
        pair = [b, a]
        let items
        if (byCard) {
            const w = drag0 ? drag0.w : a, o = w === a ? b : a
            const to = w === a ? H[1] : H[0], toO = w === a ? H[0] : H[1]
            items = [{ c: card, w: w, from: card.r, to: to, r0: card.rad, r1: rHalf, live: true, cover: true, fresh: false, sh1: 0 },
                     { c: copyB, w: o, from: frame(o), to: toO, r0: rHalf, r1: rHalf }]
        } else items = [{ c: copyA, w: a, from: H[0], to: H[1], r0: rHalf, r1: rHalf }, { c: copyB, w: b, from: H[1], to: H[0], r0: rHalf, r1: rHalf }]
        fly(items, { dur: 500, curve: cSwap, bg: "jump", hold: true, apply: () => place(), handle: !byCard })
        changed("swap")
    }
    // a member came up (the dock, the task cards, a tap): the other one with it, right under it
    function bringPartner(w) {
        if (mode !== "split" || pair.indexOf(w) < 0 || !live(w) || w.minimized) return
        const o = pair[1 - pair.indexOf(w)]
        if (!live(o)) return
        quiet++
        if (o.minimized) o.minimized = false
        if (covered(o, w)) {
            if (typeof K.Workspace.raiseWindow === "function") { K.Workspace.raiseWindow(o); K.Workspace.raiseWindow(w) }
            else { K.Workspace.activeWindow = o; K.Workspace.activeWindow = w }
        }
        quiet--
        dump("together")
        gripTimer.restart()
    }
    function covered(o, w) {   // another app over o
        const s = K.Workspace.stackingOrder, i = s.indexOf(o)
        return s.some((x, j) => j > i && x !== w && !x.deleted && !ours(x) && !x.minimized && x.normalWindow && meets(frame(x), frame(o)))
    }
    // 300 ms after a member that was not in use went down: both down = the desktop (minimizeAll puts the other one
    // away first, the active one last); one = the task cards' finishOpen ("only the chosen app comes back"): back up
    function settle() {
        if (mode !== "split") return
        const down = pair.filter(w => live(w) && w.minimized)
        if (!down.length || down.length === pair.length) { dump("parked"); return }
        quiet++
        down.forEach(w => w.minimized = false)
        quiet--
        dump("regroup")
    }

    // ---- flights ----
    // fly(items, o): the copies from where they are to where they go, the real windows put away under them and
    // shown again once they have drawn at their new size. item: {c (a Copy, or null: only hidden), w, from, to, r0,
    // r1 (radius), cover (the picture scaled to cover the box, else a veil where it grows past it), fresh (false: the
    // copy is up already - the card, the handle's), dim1, fade1, sh1, wait (false: not waited for)}. o: {dur, curve, bg
    // ("jump" | "fade" | "none": the #242424 ground), hold (50 ms of copies over the windows first), apply (the
    // windows' new state, called as the copies take over), done, handle, r0, r1 (the handle's ratio), wait (ms)}
    function fly(items, o) {
        if (fl) finish()
        unpark()
        items.forEach(x => {
            const c = x.c
            if (!c) return
            if (x.fresh !== false) { c.w = x.w; c.live = true; c.veilSet(0); c.dim = 0; c.shadowK = 0 }
            c.cover = !!x.cover
            c.r = x.from; c.rad = x.r0; c.fade = 1
            x.dimS = c.dim; x.shS = c.shadowK
        })
        fl = { items: items, o: o, went: false, t0: 0 }
        flying = true
        ovHandle = !!o.handle
        if (o.handle) divR = o.r0 !== undefined ? o.r0 : ratio
        if (o.bg === "jump") { bgIn.stop(); ovBgK = 1 }
        else if (o.bg === "fade") bgIn.restart()
        flyP = 0
        sync()
        gripTimer.restart()
        if (o.hold === false) go(); else holdT.restart()
    }
    function go() {
        const f = fl
        if (!f || f.went) return
        f.went = true
        // every copy still before its window goes: KWin draws a thumbnail with its window's opacity, so a live copy
        // of a window put away is empty (ts-bed 11-10: the card black)
        f.items.forEach(x => {
            if (x.c) {
                if (x.c.live) x.c.freeze()
                const n = x.c.nat
                if (!x.c.cover && (x.to.width > n.width + 2 || x.to.height > n.height + 2)) x.c.veilTo(1)   // growing past its picture
            }
            hide(x.w)
        })
        if (f.o.apply) f.o.apply()
        if (!f.o.dur) { flyP = 1; f.t0 = Date.now(); waitT.restart(); return }   // nothing to fly: wait for the commit
        flyAnim.duration = Math.max(0, f.o.dur * k)
        flyAnim.easing.bezierCurve = f.o.curve || cEnter
        flyAnim.restart()
    }
    onFlyPChanged: {
        const f = fl
        if (!f) return
        const p = flyP
        f.items.forEach(x => {
            const c = x.c
            if (!c) return
            c.r = lerpRect(x.from, x.to, p)
            c.rad = x.r0 + (x.r1 - x.r0) * p
            if (x.dim1 !== undefined) c.dim = x.dimS + (x.dim1 - x.dimS) * p
            if (x.fade1 !== undefined) c.fade = 1 + (x.fade1 - 1) * p
            if (x.sh1 !== undefined) c.shadowK = x.shS + (x.sh1 - x.shS) * p
        })
        if (f.o.handle && f.o.r0 !== undefined) divR = f.o.r0 + (f.o.r1 - f.o.r0) * p
    }
    function settled() {
        return fl.items.every(x => x.wait === false || !live(x.w) || x.w.minimized || near(frame(x.w), x.to) || near(frame(x.w), fitH(x.w, x.to)))
    }
    function finish() {
        const f = fl
        if (!f) return
        holdT.stop(); flyAnim.stop(); waitT.stop()
        if (!f.went) { f.went = true; f.items.forEach(x => hide(x.w)); if (f.o.apply) f.o.apply() }
        flyP = 1
        fl = null
        flying = false
        ovHandle = false
        f.items.forEach(x => show(x.w))
        if (f.o.done) f.o.done()
        sync()
        gripTimer.restart()
        parkAnim.restart()   // the copies fade over the windows shown again ...
        parkT.restart()      // ... then go
    }
    function unpark() { parkT.stop(); parkAnim.stop(); parkK = 1 }
    function park() {
        if (fl) return
        ;[copyA, copyB, cP].forEach(c => { c.w = null; c.live = false; c.dim = 0; c.fade = 1 })
        if (!cardUp) { card.w = null; card.live = false }
        bgIn.stop(); ovBgK = 0
        parkK = 1
        if (mode !== "pick") splashO = 0
    }

    // ---- a title bar dragged (KWin moves the window; we draw the card and decide where it lands) ----
    property var drag0: null   // the drag just let go, for swapPair
    function titleStart(w) {
        if (stageOn || drag || divOn || !live(w) || w.resize) return
        let kind, from
        if (mode === "off") { if (!manageable(w)) return; kind = w.maximizeMode === 3 ? "card" : "free"; from = "full" }
        else if (mode === "split" && pair.indexOf(w) >= 0) { kind = "card"; from = "split" }
        else if (mode === "pick" && w === pickWin) { kind = "card"; from = "pick" }
        else return
        if (fl) finish()
        closeMenu()
        const f0 = frame(w)
        drag = { w: w, kind: kind, from: from, f0: f0, max: w.maximizeMode === 3, e0: { g: f0, max: w.maximizeMode === 3 },
                 p: null, touched: false, armed: false, zone: null, me: mode === "split" ? pair.indexOf(w) : pickSide,
                 s: Math.min(0.5, 560 / Math.max(1, f0.width), 480 / Math.max(1, f0.height)), u: 0, v: 0,
                 r0: from === "full" ? 0 : rHalf, base: null, ax: 0.5, ay: 0.05 }
        dragKind = kind
        touchCall.call()
        pollT.start()
        gripTimer.restart()
        log("title drag: " + kind + " from " + from)
    }
    // the finger (the effect's touchPoint(), "x y"; "" = no finger down: a mouse, or lifted)
    function gotTouch(s) {
        const d = drag
        if (!d) return
        let p = null
        if (s) {
            const q = String(s).split(" ")
            if (q.length >= 2 && !isNaN(Number(q[0]))) { p = Qt.point(Number(q[0]), Number(q[1])); d.touched = true }
        }
        if (!p && !d.touched) { const c = K.Workspace.cursorPos; p = Qt.point(c.x, c.y) }
        if (!p) return
        d.p = p
        if (d.kind === "card" && !d.base) {
            // the card: a live copy where the window is now (KWin may have taken it out of maximized already),
            // which shrinks under the finger; the window goes once the card has drawn (hideT)
            const b = frame(d.w)
            d.base = b
            d.ax = clamp((p.x - b.x) / Math.max(1, b.width)); d.ay = clamp((p.y - b.y) / Math.max(1, b.height))
            unpark()
            card.w = d.w; card.live = true; card.cover = true; card.fade = 1; card.dim = 0; card.veilSet(0); card.shadowK = 1
            card.r = b; card.rad = d.r0
            cardUp = true
            dimTo(dimDrag)
            hideT.restart()
        }
        aimZone()
    }
    // the card's size: spring k 900, damping ratio 1.5 (vivo's drag scale), from where it started to s of the frame
    function springStep(dt) {
        const d = drag
        if (!d || !d.base) return
        let t = Math.min(dt, 0.05)
        if (reduced) { d.u = 1; d.v = 0; t = 0 }
        while (t > 0) {
            const h = Math.min(t, 1 / 480)
            d.v += (-900 * (d.u - 1) - 90 * d.v) * h
            d.u += d.v * h
            t -= h
        }
        const w = d.base.width + (d.f0.width * d.s - d.base.width) * d.u, h = d.base.height + (d.f0.height * d.s - d.base.height) * d.u
        card.r = Qt.rect(d.p.x - d.ax * w, d.p.y - d.ay * h, w, h)
        card.rad = d.r0 + (rFloat - d.r0) * clamp(d.u)
    }
    function zoneAt(p) {
        const d = drag
        if (d.from === "full") {
            if (land()) {
                if (p.x <= area.x + edge) return { k: "split", side: 0 }
                if (p.x >= area.x + area.width - edge) return { k: "split", side: 1 }
            } else {
                if (p.y <= area.y + edge) return { k: "split", side: 0 }
                if (p.y >= area.y + area.height - edge) return { k: "split", side: 1 }
            }
            return null
        }
        if (land() && p.y <= area.y + edge) return { k: "full" }
        if (d.from === "pick") return null
        return inside(p, halves(ratio)[1 - d.me]) ? { k: "swap" } : null
    }
    function aimZone() {
        const d = drag
        let z = zoneAt(d.p)
        if (!z) d.armed = true   // the title bar starts inside the top zone: a zone counts once the finger has left them all
        if (!d.armed) z = null
        d.zone = z
        let r = null, label = ""
        if (z && z.k === "split") { r = halves(0.5)[z.side]; label = "松手进入分屏" }
        else if (z && z.k === "swap") { r = halves(ratio)[1 - d.me]; label = "松手对调" }
        else if (z) { r = area; label = "松手进入全屏" }
        if (!r) { pvOn = false; return }
        pvRect = inset(r, pvIn); pvLabel = label; pvIcon = d.w.icon
        pvOn = true
    }
    function titleEnd(w) {
        const d = drag
        if (!d || d.w !== w) return
        drag = null; dragKind = ""; drag0 = d
        pollT.stop(); hideT.stop()
        pvOn = false
        dimTo(0)
        ovLinger.restart()
        const z = d.zone
        log("title drag let go: " + (z ? z.k + (z.side !== undefined ? " " + z.side : "") : "nowhere"))
        if (d.kind === "free") {
            if (z && z.k === "split") enterPick(w, z.side, false, d.e0)
            gripTimer.restart()
            return
        }
        cardUp = false   // the card flies on as a flight's copy
        if (!d.base) {   // let go before the first point came: nothing was drawn
            if (d.from === "full") { quiet++; w.setMaximize(true, true); quiet-- } else place()
            show(w)
            gripTimer.restart()
            return
        }
        if (stageOn) { flyBack(d); return }
        if (z && z.k === "split") { if (!enterPick(w, z.side, true, d.e0)) flyBack(d) }
        else if (z && z.k === "swap") swapPair(true)
        else if (z && z.k === "full") { if (d.from === "pick") cancelPick(true); else leaveTo(w, "title") }
        else flyBack(d)
    }
    function flyBack(d) {
        const w = d.w
        const to = d.from === "full" ? (d.max ? area : d.f0) : mode === "split" && pair.indexOf(w) >= 0 ? halves(ratio)[pair.indexOf(w)]
                 : mode === "pick" && w === pickWin ? halves(0.5)[pickSide] : d.f0
        fly([{ c: card, w: w, from: card.r, to: to, r0: card.rad, r1: d.from === "full" ? 0 : rHalf, live: true, cover: true, fresh: false, sh1: 0 }],
            { dur: 350, curve: cSnap, bg: "none", hold: false,
              apply: () => { quiet++; if (d.from === "full") { if (d.max) w.setMaximize(true, true); else w.frameGeometry = d.f0 } else place(); quiet-- } })
        dump("back")
    }

    // ---- the handle on the gap (points in screen coordinates) ----
    function divPress(p) {
        if (mode !== "split" || fl || drag || stageOn || pair.length !== 2) return
        closeMenu()
        unpark()
        div = { p0: p, r0: ratio, r: ratio, moved: false, len: len() }
        divOn = true; divMoved = false; divR = ratio
        pillIn.restart()
        // live copies exactly over the windows, so a drag can put the windows away under them
        const H = halves(ratio)
        ;[copyA, copyB].forEach((c, i) => { c.w = pair[i]; c.live = true; c.cover = false; c.veilSet(0); c.dim = 0; c.fade = 1; c.shadowK = 0; c.r = H[i]; c.rad = rHalf })
    }
    function divMove(p) {
        const d = div
        if (!d) return
        const dd = land() ? p.x - d.p0.x : p.y - d.p0.y
        if (!d.moved) {
            if (Math.abs(dd) <= slop) return
            d.moved = true
            divMoved = true
            // the copies stop where they are and veil over (vivo: the app's colour and icon while the gap moves);
            // the windows go under them and stay as they are until it is let go
            copyA.freeze(); copyB.freeze()
            copyA.veilTo(1); copyB.veilTo(1)
            pair.forEach(hide)
            bgIn.stop(); ovBgK = 1
            ovHandle = true
            sync()
        }
        d.r = clamp(d.r0 + dd / d.len, 0.02, 0.98)
        divR = d.r
        const H = halves(d.r)
        copyA.r = H[0]; copyB.r = H[1]
        copyA.dim = d.r < 0.3 ? dimMax * (0.3 - d.r) / 0.3 : 0
        copyB.dim = d.r > 0.7 ? dimMax * (d.r - 0.7) / 0.3 : 0
        const t = nearestFit(d.r), sv = t === 0 ? 1 : t === 1 ? 0 : -1
        if (sv >= 0) guideSide = sv
        guideOn = sv >= 0
    }
    function divRelease(cancel) {
        const d = div
        div = null; divOn = false
        pillOut.restart()
        if (!d) return
        guideOn = false
        if (!d.moved) {
            [copyA, copyB].forEach(c => { c.w = null; c.live = false })
            if (!cancel) openMenu()
            gripTimer.restart()
            return
        }
        divMoved = false
        const t = cancel ? d.r0 : nearestFit(d.r)
        if (t === 0 || t === 1) { leaveTo(pair[t === 0 ? 1 : 0], "dismiss"); return }
        ratio = t
        const H = halves(t)
        fly([{ c: copyA, w: pair[0], from: copyA.r, to: H[0], r0: rHalf, r1: rHalf, fresh: false, dim1: 0 },
             { c: copyB, w: pair[1], from: copyB.r, to: H[1], r0: rHalf, r1: rHalf, fresh: false, dim1: 0 }],
            { dur: 350, curve: cSnap, bg: "jump", hold: false, apply: () => place(), handle: true, r0: d.r, r1: t })
        changed("snap " + t)
    }

    // ---- menu, toast ----
    function openMenu() {
        if (mode !== "split") return
        menuItems = [["swap", "对调应用", "document-swap"], ["sep"], ["exit", "退出分屏", "view-fullscreen"]]
        const g = gapAt(ratio), mw = 150, mh = 6 + 48 + 4 + 48 + 6
        let x, y, ox, oy
        if (land()) {
            const cx = g.x + g.width / 2, cy = area.y + area.height / 2
            x = cx + 34; ox = 0
            if (x + mw > area.x + area.width - 12) { x = cx - 34 - mw; ox = mw }
            y = cy - mh / 2; oy = mh / 2
        } else {
            const cx = area.x + area.width / 2, cy = g.y + g.height / 2
            y = cy + 34; oy = 0
            if (y + mh > area.y + area.height - 12) { y = cy - 34 - mh; oy = mh }
            x = cx - mw / 2; ox = mw / 2
        }
        menuBox = Qt.rect(Math.round(x - area.x), Math.round(y - area.y), mw, mh)
        menuOrigin = Qt.point(ox, oy)
        menuOpen = true
    }
    function closeMenu() { menuOpen = false }
    function menuDo(k) {
        closeMenu()
        if (mode !== "split") return
        if (k === "swap") swapPair(false)
        else if (k === "exit") leaveTo(pair.indexOf(K.Workspace.activeWindow) >= 0 ? K.Workspace.activeWindow : pair[0], "menu")
    }
    onMenuOpenChanged: {
        if (menuOpen) { menuOut.stop(); box.s = 0.3; box.opacity = 0; menuIn.restart() }
        else if (box.opacity > 0) { menuIn.stop(); menuOut.restart() }
    }
    function toast(s) {
        toastText = s
        toastShown = true
        toastT.restart()
        log("toast: " + s)
    }
    function dimTo(v) { dimAnim.to = v; dimAnim.restart() }

    // ---- the picker's content ----
    function loadPicker() {
        opened = K.Workspace.stackingOrder.filter(w => live(w) && w !== pickWin && manageable(w)).reverse()   // top first
        others = []
        appsCall.call()
        wallCall.call()
        splashO = 0; splashP = 0
        pkRev++
    }
    function fillOthers() {
        const ws = opened.concat(pickWin ? [pickWin] : [])
        const cls = ws.map(w => String(w.resourceClass).toLowerCase()), dfn = ws.map(w => String(w.desktopFileName).toLowerCase())
        others = dockApps.filter(a => {
            const id = String(a.id).replace(/\.desktop$/, "").toLowerCase(), wc = String(a.wmclass || "").toLowerCase()
            return dfn.indexOf(id) < 0 && (!wc || cls.indexOf(wc) < 0) && cls.indexOf(id) < 0
        })
    }

    // ---- what is up: the handle, the picker; a new work area ----
    function updateGrip() {
        const a = calcArea()
        if (!sameRect(a, area)) { area = a; if (mode !== "off") relayout.restart() }
        blocked = K.Workspace.windows.some(blocker)
        if (divOn) return   // the handle held: it stays where the finger is
        const ok = mode === "split" && !stageOn && !fl && !drag && !relayout.running && pair.length === 2
            && pair.every(w => live(w) && !w.minimized && !w.fullScreen)
        if (!ok) { barShown = false; gripShown = false; return }
        // anything stacked over the pair where the handle is takes it away (the dock, a banner, a menu, another app):
        // KWin draws our windows over all of them
        const s = K.Workspace.stackingOrder, top = Math.max(s.indexOf(pair[0]), s.indexOf(pair[1]))
        const over = s.filter((w, i) => i > top && !w.deleted && !ours(w) && !w.minimized && w.opacity > 0.01 && !pair.includes(w))
        barShown = !over.some(w => meets(frame(w), gapAt(ratio)))
        gripShown = !over.some(w => meets(frame(w), gripRect(ratio)))
    }
    function updateStage() {
        const s = K.Workspace.windows.find(w => /^y700-stage strip/.test(String(w.caption)) && !w.resourceClass)
        const on = !!s && String(s.caption) === "y700-stage strip on"
        if (on === stageOn) return
        stageOn = on
        log("stage manager " + (on ? "on: split screen stands aside" : "off"))
        if (on) {
            if (drag) { pollT.stop(); hideT.stop(); show(drag.w); drag = null; dragKind = ""; cardUp = false; pvOn = false; dimTo(0) }
            if (divOn) divRelease(true)
            closeMenu()
            dropPair(true)
        }
        changed("stage")
    }

    // ---- KWin ----
    function hook(w) {
        if (ours(w)) { w.skipSwitcher = true; w.skipTaskbar = true; w.skipPager = true }
        const id = idOf(w)
        if (hooked[id]) return
        const h = { w: w, min: () => root.onMinimized(w), max: () => root.onMaximized(w), geo: () => gripTimer.restart(),
                    mvs: () => root.titleStart(w), mvf: () => root.titleEnd(w), cap: () => root.onCaption(w) }
        hooked[id] = h
        w.minimizedChanged.connect(h.min)
        w.maximizedChanged.connect(h.max)
        w.frameGeometryChanged.connect(h.geo)
        w.fullScreenChanged.connect(h.geo)
        w.interactiveMoveResizeStarted.connect(h.mvs)
        w.interactiveMoveResizeFinished.connect(h.mvf)
        w.captionChanged.connect(h.cap)
    }
    function unhook(h) {
        const w = h.w
        w.minimizedChanged.disconnect(h.min)
        w.maximizedChanged.disconnect(h.max)
        w.frameGeometryChanged.disconnect(h.geo)
        w.fullScreenChanged.disconnect(h.geo)
        w.interactiveMoveResizeStarted.disconnect(h.mvs)
        w.interactiveMoveResizeFinished.disconnect(h.mvf)
        w.captionChanged.disconnect(h.cap)
    }
    function onCaption(w) { if (/^y700-stage strip/.test(String(w.caption)) && !w.resourceClass) updateStage() }
    function onMinimized(w) {
        const id = idOf(w)
        if (!w.minimized && later[id] && mode === "off") { const e = later[id]; delete later[id]; Qt.callLater(() => restore(w, e)) }
        gripTimer.restart()
        if (quiet || stageOn) return
        if (mode === "pick" && w === pickWin && w.minimized) { leavePick("minimized"); return }
        if (mode !== "split" || pair.indexOf(w) < 0) return
        const o = pair[1 - pair.indexOf(w)]
        if (w.minimized) {
            // the one in use put away (its title bar, the home flick, which puts away the active window only): the
            // other one with it, and both come back together (bringPartner)
            const wasActive = curActive === w || (prevActive === w && Date.now() - actAt < 50)
            if (wasActive && live(o) && !o.minimized) { quiet++; o.minimized = true; quiet--; dump("parked") }
            else settleT.restart()
        } else if (live(o) && o.minimized) Qt.callLater(() => root.bringPartner(w))
    }
    function onMaximized(w) {
        if (quiet || stageOn || mode === "off" || w.maximizeMode !== 3) return
        if (drag && drag.w === w) return
        const member = mode === "split" ? pair.indexOf(w) >= 0 : w === pickWin
        if (!member) return
        // (our own setMaximize comes back from the client a little later, quiet or not; only maximized counts.)
        // Maximized by the app itself just after we placed it (restoring its last state): place once more; later it
        // is the user (a double tap on the title bar, its button): split screen ends with it full
        if (Date.now() - placedAt < 2000 && !refitted[idOf(w)]) {
            refitted[idOf(w)] = true
            Qt.callLater(place)
            dump("refit")
            return
        }
        if (mode === "split") leaveTo(w, "maximized")
        else { mode = "off"; pickWin = null; ledger = {}; pkOut.restart(); changed("pick maximized") }
    }

    Component.onCompleted: {
        area = calcArea()
        K.Workspace.windows.forEach(hook)
        effectCall.call()
        updateStage()
        // KWin stacks internal windows in the order they are shown (y700-stage, ts-bed 11-08): the bar and the
        // handle, the overlay over them, the picker over that, the menu and the toast on top
        Qt.callLater(() => { bar.visible = true; grip.visible = true; ov.visible = true; picker.visible = true; menuWin.visible = true; toastWin.visible = true })
        log("loaded" + (typeof K.Workspace.raiseWindow === "function" ? "" : " (no raiseWindow)"))
        sync()
    }
    // unloaded (install.sh, the next build, --remove): these connections outlive this script's objects, and a window
    // left see-through would stay so
    Component.onDestruction: {
        for (const id in hooked) unhook(hooked[id])
        for (const id in hidden) { const h = hidden[id]; try { h.w.opacity = h.o } catch (e) {} }
        try {
            const ws = mode === "split" ? pair : mode === "pick" && pickWin ? [pickWin] : []
            ws.forEach(w => { if (live(w) && !w.minimized) restore(w, ledger[idOf(w)]) })
            cornersCall.arguments = [""]; cornersCall.call(); chromeCall.arguments = [""]; chromeCall.call()
        } catch (e) {}
    }

    Connections {
        target: K.Workspace
        function onWindowAdded(w) {
            root.hook(w)
            if (/^y700-stage strip/.test(String(w.caption))) root.updateStage()
            // launched from the picker (or anything new while it is up): the other half's app
            if (root.mode === "pick" && !root.quiet) Qt.callLater(() => root.choose(w, null))
            gripTimer.restart()
        }
        function onWindowRemoved(w) {
            const id = root.idOf(w)
            const h = root.hooked[id]
            if (h) { root.unhook(h); delete root.hooked[id] }
            delete root.hidden[id]; delete root.later[id]; delete root.refitted[id]
            if (root.drag && root.drag.w === w) { pollT.stop(); root.drag = null; root.dragKind = ""; root.cardUp = false; root.pvOn = false; root.dimTo(0) }
            if (root.mode === "pick" && root.pickWin === w) root.leavePick("closed")
            else if (root.mode === "split" && root.pair.indexOf(w) >= 0) {
                const o = root.pair[1 - root.pair.indexOf(w)]
                if (root.live(o) && !o.minimized) root.leaveTo(o, "closed")
                else root.dropPair(false)
            }
            delete root.ledger[id]
            if (root.opened.indexOf(w) >= 0) root.opened = root.opened.filter(x => x !== w)
            if (/^y700-stage strip/.test(String(w.caption))) Qt.callLater(root.updateStage)
            gripTimer.restart()
        }
        function onWindowActivated(w) {
            root.prevActive = root.curActive; root.curActive = w; root.actAt = Date.now()
            gripTimer.restart()
            if (!w || root.quiet || root.stageOn) return
            if (root.tileAsked && Date.now() - root.tileAsked < 1000 && root.manageable(w)) { Qt.callLater(root.tile); return }
            if (root.mode === "pick" && w !== root.pickWin) Qt.callLater(() => root.choose(w, null))
            else if (root.mode === "split" && root.pair.indexOf(w) >= 0) Qt.callLater(() => root.bringPartner(w))
        }
        function onScreensChanged() { relayout.restart() }
        function onVirtualScreenGeometryChanged() { relayout.restart() }
    }

    K.ShortcutHandler {
        name: "y700-split"; text: "Y700: split screen (the active app to the left half)"; sequence: ""
        onActivated: root.tile()
    }
    // the effect (linux/stage/kwin-corners): async, and silently nothing when it is not there (square corners, no gap
    // colour, no finger: the card follows the cursor)
    K.DBusCall {
        id: cornersCall
        service: "org.kde.KWin"; path: "/org/y700/StageCorners"; dbusInterface: "org.y700.StageCorners"; method: "setSplitWindows"
    }
    K.DBusCall {
        id: chromeCall
        service: "org.kde.KWin"; path: "/org/y700/StageCorners"; dbusInterface: "org.y700.StageCorners"; method: "setSplitChrome"
    }
    K.DBusCall {
        id: touchCall
        service: "org.kde.KWin"; path: "/org/y700/StageCorners"; dbusInterface: "org.y700.StageCorners"; method: "touchPoint"
        onFinished: (ret) => root.gotTouch(ret && ret.length ? String(ret[0]) : "")
        onFailed: root.gotTouch("")
    }
    K.DBusCall {
        id: effectCall
        service: "org.kde.KWin"; path: "/Effects"; dbusInterface: "org.kde.kwin.Effects"; method: "loadEffect"
        arguments: ["y700_stagecorners"]
    }
    // the shellbar (linux/dock): the dock's apps, launching one, the wallpaper (none in ts-bed: no apps, a plain ground)
    K.DBusCall {
        id: appsCall
        service: "fyi.y700.Shellbar"; path: "/Shellbar"; dbusInterface: "fyi.y700.Shellbar"; method: "dockApps"
        onFinished: (ret) => { try { root.dockApps = JSON.parse(String(ret[0])) } catch (e) { root.dockApps = [] } root.fillOthers() }
    }
    K.DBusCall {
        id: launchCall
        service: "fyi.y700.Shellbar"; path: "/Shellbar"; dbusInterface: "fyi.y700.Shellbar"; method: "launchApp"
    }
    K.DBusCall {
        id: wallCall
        service: "fyi.y700.Shellbar"; path: "/Shellbar"; dbusInterface: "fyi.y700.Shellbar"; method: "wallpaperUrl"
        onFinished: (ret) => root.wallUrl = ret && ret.length ? String(ret[0]) : ""
    }

    Timer { id: gripTimer; interval: 50; onTriggered: root.updateGrip() }
    Timer { id: settleT; interval: 300; onTriggered: root.settle() }
    Timer { id: tileWait; interval: 1000; onTriggered: { if (root.tileAsked) { root.tileAsked = 0; root.toast("先打开一个应用") } } }
    Timer {   // rotation, a docked keyboard: the work area settles after the output; one layout for the lot
        id: relayout; interval: 300
        onTriggered: {
            if (root.mode === "off" || root.stageOn) return
            if (root.fl || root.drag || root.divOn) { restart(); return }
            root.place(); root.sync(); gripTimer.restart(); root.dump("relayout")
        }
    }
    Timer { id: pollT; interval: 8; repeat: true; onTriggered: touchCall.call() }   // the finger, while a title bar is dragged
    Timer {   // the card has drawn: it keeps that picture (see go()), the window goes
        id: hideT; interval: 50
        onTriggered: if (root.drag && root.cardUp) { card.freeze(); root.hide(root.drag.w) }
    }
    Timer { id: holdT; interval: 50; onTriggered: root.go() }   // the copies' first frame is up over the windows
    Timer {   // landed: the windows drew at their new size (or 400 ms went)
        id: waitT; interval: 16; repeat: true
        onTriggered: if (!root.fl || root.settled() || Date.now() - root.fl.t0 > (root.fl.o.wait || 400)) root.finish()
    }
    Timer { id: parkT; interval: 220 * root.k + 20; onTriggered: root.park() }
    Timer { id: ovLinger; interval: 300 * root.k + 20 }   // the dim layer and the drop hint fade out
    Timer {   // nothing came of a launch from the picker
        id: launchT; interval: 10000
        onTriggered: { root.pending = null; splashOut.restart() }
    }
    Timer { id: toastT; interval: 1600; onTriggered: root.toastShown = false }
    NumberAnimation {
        id: flyAnim; target: root; property: "flyP"; from: 0; to: 1
        easing.type: Easing.BezierSpline
        onFinished: { if (root.fl) { root.fl.t0 = Date.now(); waitT.restart() } }
    }
    NumberAnimation { id: parkAnim; target: root; property: "parkK"; to: 0; duration: 200 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cStd }
    NumberAnimation { id: bgIn; target: root; property: "ovBgK"; to: 1; duration: 250 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cStd }
    NumberAnimation { id: dimAnim; target: root; property: "dimK"; duration: 250 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cDim }
    NumberAnimation { id: pillIn; target: root; property: "pill"; to: 1; duration: 200 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cDown }
    NumberAnimation { id: pillOut; target: root; property: "pill"; to: 0; duration: 250 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cUp }
    NumberAnimation { id: pkIn; target: root; property: "pkO"; to: 1; duration: 250 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cStd }
    NumberAnimation {
        id: pkOut; target: root; property: "pkO"; to: 0; duration: 250 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cStd
        onStarted: pkIn.stop()
    }
    NumberAnimation { id: splashAnim; target: root; property: "splashP"; from: 0; to: 1; duration: 300 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cEnter }
    NumberAnimation { id: splashOut; target: root; property: "splashO"; to: 0; duration: 200 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cStd }
    SequentialAnimation {   // the menu from the handle: 0.3 -> 1.02 -> 1
        id: menuIn
        ParallelAnimation {
            NumberAnimation { target: box; property: "s"; to: 1.02; duration: 250 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cMenuIn }
            NumberAnimation { target: box; property: "opacity"; to: 1; duration: 250 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cStd }
        }
        NumberAnimation { target: box; property: "s"; to: 1; duration: 150 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cStd }
    }
    ParallelAnimation {
        id: menuOut
        NumberAnimation { target: box; property: "s"; to: 0.3; duration: 200 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cMenuOut }
        NumberAnimation { target: box; property: "opacity"; to: 0; duration: 200 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cMenuOut }
    }
    FrameAnimation {   // the card under the finger
        running: root.cardUp && !!root.drag
        onTriggered: root.springStep(frameTime)
    }

    // A window's copy: its live thumbnail, or (live false) the last frame of it kept, rounded; drawn at its own size
    // from the top-left (the box cuts it off) or (cover) scaled to cover the box; a veil (the picture blurred under
    // 25 % black and the app's icon) for a copy that grows past its picture; a dim layer. Still pictures as the stage's
    // cards take them (Card.qml): the thumbnail lingers a beat after the copy stops, then goes, so KWin no longer
    // renders the window for it
    component Copy: Item {
        id: cp
        property var w: null
        property var wid: null
        property point origin: Qt.point(0, 0)   // the window it is drawn in, on screen
        property rect r: Qt.rect(0, 0, 1, 1)
        property real rad: 0
        property bool live: false
        property bool cover: false
        property real veil: 0
        property real dim: 0
        property real fade: 1
        property real shadowK: 0
        property size nat: Qt.size(1, 1)
        readonly property size cur: w ? Qt.size(Math.max(1, w.frameGeometry.width), Math.max(1, w.frameGeometry.height)) : nat
        readonly property size pic: live ? cur : nat
        readonly property real coverS: Math.max(width / pic.width, height / pic.height)
        property bool linger: false
        // a new thumbnail for each window (one whose window was let go keeps a node on a texture KWin has deleted)
        onWChanged: if (w && String(w.internalId) !== String(wid)) { wid = w.internalId; thumb.sourceComponent = null; thumb.sourceComponent = thumbC }
        onLiveChanged: if (!live) { linger = true; lingerT.restart() }
        function freeze() { nat = cur; live = false }
        function veilTo(v) { veilAnim.to = v; veilAnim.restart() }
        function veilSet(v) { veilAnim.stop(); veil = v }
        Timer { id: lingerT; interval: 100; onTriggered: cp.linger = false }
        NumberAnimation { id: veilAnim; target: cp; property: "veil"; duration: 150 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cStd }
        x: r.x - origin.x; y: r.y - origin.y
        width: Math.max(1, r.width); height: Math.max(1, r.height)
        opacity: fade * root.parkK
        visible: !!w && opacity > 0.005

        Kirigami.ShadowedRectangle {
            anchors.fill: parent
            radius: cp.rad
            color: "#111"
            shadow.size: cp.shadowK > 0.01 ? 50 : 0
            shadow.yOffset: 18
            shadow.color: Qt.rgba(0, 0, 0, 0.45 * cp.shadowK)
        }
        Item {
            anchors.fill: parent
            layer.enabled: cp.visible
            layer.effect: OpacityMask { maskSource: Rectangle { width: cp.width; height: cp.height; radius: cp.rad } }
            Item {
                width: cp.pic.width; height: cp.pic.height
                transformOrigin: Item.TopLeft
                scale: cp.cover ? cp.coverS : 1
                x: cp.cover ? (cp.width - width * scale) / 2 : 0
                y: cp.cover ? (cp.height - height * scale) / 2 : 0
                Component { id: thumbC; K.WindowThumbnail { wId: cp.wid } }
                Loader {
                    id: thumb
                    anchors.fill: parent
                    active: !!cp.wid && (cp.live || cp.linger)
                }
                ShaderEffectSource { id: snap; anchors.fill: parent; sourceItem: thumb; hideSource: true; live: cp.live }
            }
            Item {
                anchors.fill: parent
                opacity: cp.veil
                visible: opacity > 0.005
                FastBlur {
                    width: cp.pic.width; height: cp.pic.height
                    transformOrigin: Item.TopLeft
                    scale: cp.coverS
                    x: (cp.width - width * scale) / 2; y: (cp.height - height * scale) / 2
                    source: snap
                    radius: 64
                    cached: !cp.live
                }
                Rectangle { anchors.fill: parent; color: "black"; opacity: 0.25 }
                Kirigami.Icon { anchors.centerIn: parent; width: 50; height: 50; source: cp.w ? cp.w.icon : "" }
            }
            Rectangle { anchors.fill: parent; color: "black"; opacity: cp.dim; visible: opacity > 0.002 }
        }
    }

    // ---- windows. KWin internal windows: drawn over everything, parked off screen when not up ----
    // the gap: touches only (the effect paints it)
    Window {
        id: bar
        title: "y700-split bar"
        transientParent: null
        flags: Qt.FramelessWindowHint | Qt.WindowDoesNotAcceptFocus | Qt.BypassWindowManagerHint
        color: "transparent"
        visible: false      // shown by Component.onCompleted, in stacking order
        readonly property rect g: root.gapAt(root.ratio)
        x: root.barShown || root.divOn ? g.x : -32000
        y: g.y
        width: Math.max(1, g.width); height: Math.max(1, g.height)
        MouseArea {
            anchors.fill: parent
            preventStealing: true
            onPressed: (m) => root.divPress(Qt.point(bar.x + m.x, bar.y + m.y))
            onPositionChanged: (m) => root.divMove(Qt.point(bar.x + m.x, bar.y + m.y))
            onReleased: root.divRelease(false)
            onCanceled: root.divRelease(true)
        }
    }
    // the handle: a white bar 4 x 40, and a pill 20 x 90 (white 12 %) behind it while it is held
    Window {
        id: grip
        title: "y700-split handle"
        transientParent: null
        flags: Qt.FramelessWindowHint | Qt.WindowDoesNotAcceptFocus | Qt.BypassWindowManagerHint
        color: "transparent"
        visible: false
        readonly property rect g: root.gripRect(root.ratio)
        x: root.gripShown || root.divOn ? g.x : -32000
        y: g.y
        width: g.width; height: g.height
        Item {
            anchors.fill: parent
            visible: !root.divMoved   // moving, the overlay draws it
            Rectangle {
                anchors.centerIn: parent
                width: root.land() ? 20 : 90; height: root.land() ? 90 : 20; radius: 10
                color: Qt.rgba(1, 1, 1, 0.12)
                opacity: root.pill
            }
            Rectangle { anchors.centerIn: parent; width: root.land() ? 4 : 40; height: root.land() ? 40 : 4; radius: 2; color: "white" }
        }
        MouseArea {
            anchors.fill: parent
            preventStealing: true
            onPressed: (m) => root.divPress(Qt.point(grip.x + m.x, grip.y + m.y))
            onPositionChanged: (m) => root.divMove(Qt.point(grip.x + m.x, grip.y + m.y))
            onReleased: root.divRelease(false)
            onCanceled: root.divRelease(true)
        }
    }

    // the overlay: the ground and the copies of a flight, the handle while it moves, the dim layer, the drop hint and
    // the card of a title bar drag, the 「松手进入全屏」 guide. Touches go through it (outputOnly: what KWin's
    // InternalWindow::hitTest reads, y700-stage README)
    Window {
        id: ov
        title: "y700-split overlay"
        transientParent: null
        flags: Qt.FramelessWindowHint | Qt.WindowDoesNotAcceptFocus | Qt.BypassWindowManagerHint | Qt.WindowTransparentForInput
        color: "transparent"
        visible: false
        property bool outputOnly: true
        readonly property bool up: root.flying || parkT.running || root.cardUp || root.dragKind !== "" || root.divOn || ovLinger.running
        x: up ? root.area.x : -32000
        y: root.area.y
        width: Math.max(1, root.area.width)
        height: Math.max(1, root.area.height)

        Rectangle { anchors.fill: parent; color: "#242424"; opacity: root.ovBgK * root.parkK; visible: opacity > 0.005 }
        Copy { id: copyA; origin: Qt.point(root.area.x, root.area.y) }
        Copy { id: copyB; origin: Qt.point(root.area.x, root.area.y) }
        Item {   // the handle at divR
            visible: root.ovHandle
            readonly property rect g: root.gripRect(root.divR)
            x: g.x - root.area.x; y: g.y - root.area.y; width: g.width; height: g.height
            Rectangle {
                anchors.centerIn: parent
                width: root.land() ? 20 : 90; height: root.land() ? 90 : 20; radius: 10
                color: Qt.rgba(1, 1, 1, 0.12)
                opacity: root.pill
            }
            Rectangle { anchors.centerIn: parent; width: root.land() ? 4 : 40; height: root.land() ? 40 : 4; radius: 2; color: "white" }
        }
        Rectangle { anchors.fill: parent; color: "black"; opacity: root.dimK; visible: opacity > 0.005 }
        // where it would land: 10 in from the half, the app's icon and what happens
        Kirigami.ShadowedRectangle {
            id: pv
            x: root.pvRect.x - root.area.x; y: root.pvRect.y - root.area.y; width: root.pvRect.width; height: root.pvRect.height
            Behavior on x { enabled: pv.opacity > 0.02; NumberAnimation { duration: 250 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cDim } }
            Behavior on y { enabled: pv.opacity > 0.02; NumberAnimation { duration: 250 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cDim } }
            Behavior on width { enabled: pv.opacity > 0.02; NumberAnimation { duration: 250 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cDim } }
            Behavior on height { enabled: pv.opacity > 0.02; NumberAnimation { duration: 250 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cDim } }
            opacity: root.pvOn ? 1 : 0
            visible: opacity > 0.005
            Behavior on opacity { NumberAnimation { duration: 250 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cDim } }
            radius: root.rThumb
            color: Qt.rgba(34 / 255, 36 / 255, 42 / 255, 0.86)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.14)
            shadow.size: 30
            shadow.yOffset: 10
            shadow.color: Qt.rgba(0, 0, 0, 0.30)
            Column {
                anchors.centerIn: parent
                spacing: 12
                Kirigami.Icon { anchors.horizontalCenter: parent.horizontalCenter; width: 50; height: 50; source: root.pvIcon || "" }
                Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.pvLabel; color: Qt.rgba(1, 1, 1, 0.6); font.pixelSize: 15 }
            }
        }
        Copy { id: card; origin: Qt.point(root.area.x, root.area.y) }
        // to an end: 「松手进入全屏」 on the half that would take the screen, 58 under its middle
        Rectangle {
            readonly property rect h: root.halves(root.divR)[root.guideSide]
            x: Math.round(h.x - root.area.x + h.width / 2 - width / 2)
            y: Math.round(h.y - root.area.y + h.height / 2 + 58 - height / 2)
            width: guideText.implicitWidth + 36; height: guideText.implicitHeight + 18
            radius: 14
            color: Qt.rgba(34 / 255, 36 / 255, 42 / 255, 0.9)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.12)
            opacity: root.guideOn ? 1 : 0
            visible: opacity > 0.005
            Behavior on opacity { NumberAnimation { duration: 250 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cStd } }
            Text { id: guideText; anchors.centerIn: parent; text: "松手进入全屏"; color: Qt.rgba(1, 1, 1, 0.9); font.pixelSize: 15 }
        }
    }

    // 「选择另一个应用」 on the other half: the wallpaper blurred under 36 % black, the open windows (still pictures, as
    // the stage's cards take them) and the dock's other apps; a tap on the blank = back to full screen
    Window {
        id: picker
        title: "y700-split picker"
        transientParent: null
        flags: Qt.FramelessWindowHint | Qt.WindowDoesNotAcceptFocus | Qt.BypassWindowManagerHint
        color: "transparent"
        visible: false
        readonly property rect pr: root.halves(0.5)[1 - root.pickSide]
        readonly property bool up: (root.mode === "pick" || root.pkO > 0.005 || !!cP.w || root.splashO > 0.005) && !root.blocked
        x: up ? pr.x : -32000
        y: pr.y
        width: Math.max(1, pr.width)
        height: Math.max(1, pr.height)
        readonly property int cols: width > 900 ? 3 : 2
        readonly property int tw: Math.floor((width - 64 - 20 * (cols - 1)) / cols)
        readonly property int th: Math.round(tw * root.area.height / Math.max(1, root.area.width))

        Item {
            id: pkBody
            anchors.fill: parent
            opacity: root.pkO
            visible: opacity > 0.005
            layer.enabled: visible
            layer.effect: OpacityMask { maskSource: Rectangle { width: pkBody.width; height: pkBody.height; radius: root.rHalf } }
            Rectangle { anchors.fill: parent; color: "#2a3346" }
            Image {
                id: wall
                anchors { fill: parent; margins: -40 }
                source: root.wallUrl
                fillMode: Image.PreserveAspectCrop
                sourceSize.width: 480
                asynchronous: true
                visible: false
            }
            FastBlur { anchors.fill: wall; source: wall; radius: 64; cached: true; visible: wall.status === Image.Ready }
            Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.36) }
            Flickable {
                anchors.fill: parent
                contentHeight: pkCol.height + 60
                interactive: contentHeight > height
                clip: true
                MouseArea { width: parent.width; height: Math.max(pkCol.height + 60, picker.height); onClicked: root.cancelPick(false) }
                Column {
                    id: pkCol
                    x: 32; y: 30; width: picker.width - 64
                    Text { text: "选择另一个应用"; color: Qt.rgba(1, 1, 1, 0.92); font.pixelSize: 22; font.weight: Font.DemiBold }
                    Text { topPadding: 2; text: "点一下，放到这半边；点空白处取消"; color: Qt.rgba(1, 1, 1, 0.6); font.pixelSize: 14 }
                    Text { visible: root.opened.length > 0; topPadding: 24; bottomPadding: 10; text: "已打开"; color: Qt.rgba(1, 1, 1, 0.55); font.pixelSize: 13 }
                    Grid {
                        visible: root.opened.length > 0
                        columns: picker.cols
                        spacing: 20
                        Repeater {
                            model: (root.pkRev, root.opened)
                            Item {
                                id: th
                                required property var modelData
                                required property int index
                                width: picker.tw; height: picker.th + 9 + 30
                                scale: thTap.pressed ? 0.97 : 1
                                Behavior on scale { NumberAnimation { duration: (thTap.pressed ? 200 : 250) * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: thTap.pressed ? root.cDown : root.cUp } }
                                property real dy: 8
                                opacity: 0
                                transform: Translate { y: th.dy }
                                Appear { item: th; index: th.index }
                                // the window as it stands in the work area, a still picture (Card.qml's way)
                                readonly property bool shooting: !shot && picker.up && root.pkO > 0.5
                                property bool shot: false
                                property bool linger: false
                                onShootingChanged: if (!shooting) { linger = true; thLinger.restart() }
                                Timer { interval: 600; running: th.shooting; onTriggered: th.shot = true }
                                Timer { id: thLinger; interval: 100; onTriggered: th.linger = false }
                                Kirigami.ShadowedRectangle {
                                    width: picker.tw; height: picker.th; radius: root.rThumb; color: "#111"
                                    shadow.size: 24; shadow.yOffset: 8; shadow.color: Qt.rgba(0, 0, 0, 0.35)
                                }
                                Item {
                                    id: thPic
                                    width: picker.tw; height: picker.th
                                    layer.enabled: true
                                    layer.effect: OpacityMask { maskSource: Rectangle { width: thPic.width; height: thPic.height; radius: root.rThumb } }
                                    readonly property real s: width / Math.max(1, root.area.width)
                                    readonly property rect f: th.modelData ? root.frame(th.modelData) : Qt.rect(0, 0, 1, 1)
                                    Item {
                                        x: (thPic.f.x - root.area.x) * thPic.s; y: (thPic.f.y - root.area.y) * thPic.s
                                        width: thPic.f.width * thPic.s; height: thPic.f.height * thPic.s
                                        Loader {
                                            id: thThumb
                                            anchors.fill: parent
                                            active: th.shooting || th.linger
                                            sourceComponent: K.WindowThumbnail { wId: th.modelData.internalId }
                                        }
                                        ShaderEffectSource { anchors.fill: parent; sourceItem: thThumb; hideSource: true; live: th.shooting }
                                    }
                                }
                                Row {
                                    y: picker.th + 9
                                    spacing: 8
                                    Kirigami.Icon { width: 30; height: 30; source: th.modelData ? th.modelData.icon : "" }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: Math.min(implicitWidth, picker.tw - 38); elide: Text.ElideRight
                                        text: th.modelData ? root.appName(th.modelData.caption) : ""
                                        color: Qt.rgba(1, 1, 1, 0.9); font.pixelSize: 15
                                    }
                                }
                                // a MouseArea, not a TapHandler: a handler's passive grab lets the press on to the
                                // blank's MouseArea under it, and both would fire
                                MouseArea {
                                    id: thTap
                                    anchors.fill: parent
                                    onClicked: {
                                        const r = thPic.mapToItem(null, 0, 0, thPic.width, thPic.height)
                                        root.choose(th.modelData, Qt.rect(picker.x + r.x, picker.y + r.y, r.width, r.height))
                                    }
                                }
                            }
                        }
                    }
                    Text { visible: root.others.length > 0; topPadding: 24; bottomPadding: 10; text: "其他应用"; color: Qt.rgba(1, 1, 1, 0.55); font.pixelSize: 13 }
                    Grid {
                        visible: root.others.length > 0
                        columns: Math.max(1, Math.floor((pkCol.width + 22) / (76 + 22)))
                        rowSpacing: 18; columnSpacing: 22
                        Repeater {
                            model: root.others
                            Item {
                                id: ap
                                required property var modelData
                                required property int index
                                width: 76; height: 60 + 8 + apName.height
                                scale: apTap.pressed ? 0.97 : 1
                                Behavior on scale { NumberAnimation { duration: (apTap.pressed ? 200 : 250) * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: apTap.pressed ? root.cDown : root.cUp } }
                                property real dy: 8
                                opacity: 0
                                transform: Translate { y: ap.dy }
                                Appear { item: ap; index: root.opened.length + ap.index }
                                Kirigami.Icon { id: apIcon; x: 8; width: 60; height: 60; source: String(ap.modelData.icon || "") }
                                Text {
                                    id: apName
                                    y: 68; width: 76; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                                    text: String(ap.modelData.name || ""); color: Qt.rgba(1, 1, 1, 0.86); font.pixelSize: 13
                                }
                                MouseArea {
                                    id: apTap
                                    anchors.fill: parent
                                    onClicked: {
                                        const r = apIcon.mapToItem(null, 0, 0, apIcon.width, apIcon.height)
                                        root.launch(ap.modelData, Qt.rect(r.x, r.y, r.width, r.height))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        // a launched app opens: its icon's tile grows over the half until the window comes (picker coordinates)
        Rectangle {
            readonly property rect at: root.lerpRect(root.splashFrom, Qt.rect(0, 0, picker.width, picker.height), root.splashP)
            x: at.x; y: at.y; width: at.width; height: at.height
            radius: 15 + (root.rHalf - 15) * root.splashP
            color: "#22242a"
            opacity: root.splashO * root.pkO
            visible: opacity > 0.005
            Kirigami.Icon { anchors.centerIn: parent; width: 60; height: 60; source: root.splashIcon }
        }
        Copy { id: cP; origin: Qt.point(picker.x, picker.y) }
    }
    // the picker's items come in 30 ms apart: up 8 and in, 250 ms
    component Appear: SequentialAnimation {
        id: appear
        required property Item item
        property int index: 0
        running: true
        PauseAnimation { duration: root.reduced ? 0 : 30 * appear.index * root.k }
        ParallelAnimation {
            NumberAnimation { target: appear.item; property: "opacity"; to: 1; duration: 250 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cStd }
            NumberAnimation { target: appear.item; property: "dy"; to: 0; duration: root.reduced ? 0 : 250 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cStd }
        }
    }

    // the handle's menu (vivo's long-press menu), from the handle; a tap anywhere else closes it
    Window {
        id: menuWin
        title: "y700-split menu"
        transientParent: null
        flags: Qt.FramelessWindowHint | Qt.WindowDoesNotAcceptFocus | Qt.BypassWindowManagerHint
        color: "transparent"
        visible: false
        x: root.menuOpen || menuOut.running ? root.area.x : -32000
        y: root.area.y
        width: Math.max(1, root.area.width)
        height: Math.max(1, root.area.height)
        MouseArea { anchors.fill: parent; onPressed: root.closeMenu() }
        Kirigami.ShadowedRectangle {
            id: box
            property real s: 0.3
            x: root.menuBox.x; y: root.menuBox.y; width: root.menuBox.width; height: root.menuBox.height
            radius: 18
            color: "#282828"
            shadow.size: 22
            shadow.yOffset: 6
            shadow.color: Qt.rgba(0, 0, 0, 0.39)
            transform: Scale { origin.x: root.menuOrigin.x; origin.y: root.menuOrigin.y; xScale: box.s; yScale: box.s }
            opacity: 0
            visible: opacity > 0.005
            Column {
                y: 6; width: parent.width
                Repeater {
                    model: root.menuItems
                    Item {
                        id: row
                        required property var modelData
                        readonly property bool sep: modelData[0] === "sep"
                        width: box.width; height: sep ? 4 : 48
                        Rectangle { visible: row.sep; anchors.fill: parent; color: Qt.rgba(1, 1, 1, 0.05) }
                        // radius 12: a square press poked 4.6 px out of the box's 18 corner at 6 px in
                        Rectangle { visible: ma.pressed; anchors.fill: parent; radius: 12; color: Qt.rgba(1, 1, 1, 0.15) }
                        Kirigami.Icon {
                            visible: !row.sep
                            x: 20; y: (parent.height - 16) / 2; width: 16; height: 16
                            source: row.modelData[2] || ""
                            isMask: true
                            color: Qt.rgba(1, 1, 1, 0.9)
                        }
                        Text {
                            visible: !row.sep
                            x: 46; height: parent.height
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

    // one line at the bottom for 1.6 s: 「已经在分屏里了」, 「这个应用不支持分屏」, ...
    Window {
        id: toastWin
        title: "y700-split toast"
        transientParent: null
        flags: Qt.FramelessWindowHint | Qt.WindowDoesNotAcceptFocus | Qt.BypassWindowManagerHint | Qt.WindowTransparentForInput
        color: "transparent"
        visible: false
        property bool outputOnly: true
        width: Math.max(1, toastLabel.implicitWidth + 36)
        height: toastLabel.implicitHeight + 20 + 8
        x: root.toastShown || toastBody.opacity > 0.005 ? Math.round(root.area.x + (root.area.width - width) / 2) : -32000
        y: Math.round(root.area.y + root.area.height - 130 - height + 8)
        Rectangle {
            id: toastBody
            width: parent.width; height: parent.height - 8
            y: root.toastShown ? 0 : 8
            Behavior on y { NumberAnimation { duration: 200 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cToast } }
            opacity: root.toastShown ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 160 * root.k; easing.type: Easing.BezierSpline; easing.bezierCurve: root.cStd } }
            radius: 14
            color: Qt.rgba(40 / 255, 40 / 255, 40 / 255, 0.94)
            Text { id: toastLabel; anchors.centerIn: parent; text: root.toastText; color: "white"; font.pixelSize: 16 }
        }
    }
}
