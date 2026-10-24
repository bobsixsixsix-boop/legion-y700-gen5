// The key grid and its touch state machine, ported from the design mockup (pointer handlers on
// #keys). One MultiPointTouchArea covers the grid; each finger is tracked by its point id and
// hit-tested against the key faces, so two-thumb rollover, flicks, long presses, the space-bar
// cursor, hold-to-talk, delete repeat + "slide here to clear" and pinch all live in one place.
// All timing runs off one 16 ms ticker that only ticks while a finger is down.
//
// The area never types by itself: it calls the controller `kb` (Keyboard.qml).
import QtQuick
import "Layouts.js" as L

Item {
    id: area
    required property var kb            // controller
    property real u: 1                  // design px -> logical px
    property real fs: 1
    property var rowsInfo: L.rows(kb.mode, kb.layout, kb.zh, kb.portrait, kb.ja)
    property real keyTop: 0             // y of the key grid inside this item
    property real keyH: 296 * u
    property bool blocked: false        // a panel covers the keys

    // ---- tunables (design px, vivo values) ----
    readonly property int tAlts: 400
    readonly property int tSpace: 250
    readonly property int tDelete: 400
    readonly property int tEnter: 200
    readonly property int tLang: 400
    readonly property real flickDy: 24 * u
    // one update moving a contact this far (~0.65 key row) is not a finger sliding but the panel carrying
    // a contact over from the lifting finger to the next one (see move())
    readonly property real jumpDist: 48 * u
    readonly property real cursorDx: 27 * u
    readonly property real cursorStep: 14 * u

    readonly property real sx: width / rowsInfo.cw
    readonly property real sy: keyH / rowsInfo.ch

    function keyRect(d) {
        var R = rowsInfo
        var top = keyTop + R.ry[d.r] * sy
        var h = (d.rs ? R.ry[d.r + d.rs - 1] + R.kh - R.ry[d.r] : R.kh) * sy
        return Qt.rect(d.x * sx, top, d.w * sx, h)
    }

    Repeater {
        id: rep
        model: area.rowsInfo.defs
        delegate: Key {
            required property var modelData
            readonly property rect geo: area.keyRect(modelData)
            def: modelData
            x: geo.x; y: geo.y; width: geo.width; height: geo.height
            u: area.u; fs: area.fs; zh: area.kb.zh; lang: area.kb.lang; shift: area.kb.shift
            opacity: area.cursorMode && modelData.t !== "space" ? 0.22 : 1
            cursorTint: area.cursorMode && modelData.t === "space"     // the space bar turns into a blue cursor strip
            Behavior on opacity { NumberAnimation { duration: 150 } }
        }
    }

    function keyAt(x, y) {
        for (var i = 0; i < rep.count; i++) {
            var it = rep.itemAt(i)
            if (it && x >= it.x && x < it.x + it.width && y >= it.y && y < it.y + it.height) return it
        }
        return null
    }
    function keyByName(k) {
        for (var i = 0; i < rep.count; i++) { var it = rep.itemAt(i); if (it && it.def.k === k) return it }
        return null
    }
    function sideOf(it) { return kb.sideAt(it) }      // screen halves, also right for the floating keyboard
    // a Key can be destroyed under a resting finger (layout/IM/orientation change): touch it only while alive
    function alive(k) { try { return !!k && k.def !== undefined } catch (e) { return false } }
    function release(k) { if (alive(k)) { k.down = false; kb.unglow(k) } }

    // ---- pointer bookkeeping ----
    property var ptr: ({})              // pointId -> state
    property int ptrCount: 0
    property bool cursorMode: false
    property real rolloverAt: 0
    property var pinch: null

    function now() { return Date.now() }

    function begin(tp) {
        if (blocked) return
        for (var id in ptr) if (ptr[id].mode === "ptt" || ptr[id].mode === "cursor") return   // keys inert while talking/steering
        var it = keyAt(tp.x, tp.y)
        if (!it) return
        var d = it.def
        var st = { id: tp.pointId, key: it, d: d, x0: tp.x, y0: tp.y, px: tp.x, py: tp.y, t0: now(), mode: "down",
                   fired: false, done: false, cancelled: false, flick: false, alts: false, rep: false, hot: false, moved: false }
        commitPending(st)
        ptr[tp.pointId] = st; ptrCount++
        pinch = null; if (ptrCount === 2) pinchCheck()
        it.down = true
        kb.glowAt(it, tp.x - it.x, tp.y - it.y)
        var side = sideOf(it)
        kb.click(d.t === "space" ? "space" : d.t === "del" ? "del" : d.t === "enter" ? "enter" : "char")
        kb.haptic(side, "key")
        if (d.t === "char") kb.showBubble(st.id, it, kb.capOf(d.k), "")
        else if (d.t === "del") kb.doDelete()
        else if (d.t === "shift") kb.shiftDown()          // on press: hold shift + letters types upper case
        else if (d.t === "list") {
            st.lv = findList(it); st.cy0 = st.lv ? st.lv.contentY : 0; st.scroll = false
            st.li = listIndexAt(it, tp.y - it.y); setListHot(it, st.li)
        }
        ticker.start()
    }

    function move(tp) {
        var st = ptr[tp.pointId]; if (!st || st.cancelled) return
        // Fast typing: a contact that "teleports" to another key in ONE update is two fingers, not a
        // slide. Read as a slide it was an upward flick on n (typed n's hint ';' instead of "nj"/"nu",
        // owner 2026-10-15: "打字快一点会误触一个分号"), or the second letter was lost. Reproduced with
        // the virtual finger (tests/vtouch.py: down n, move j, up -> ';'). A real flick moves a few px
        // per update. Lift the first finger as a plain tap, then press where the contact landed.
        if (st.mode === "down" && !st.fired && !st.alts && !st.rep && Math.hypot(tp.x - st.px, tp.y - st.py) >= jumpDist) {
            var to = keyAt(tp.x, tp.y)
            if (to !== st.key) {
                st.flick = false; st.slide = false
                end({ pointId: tp.pointId, x: st.px, y: st.py }, false)
                if (to) begin(tp)
                return
            }
        }
        var dx = tp.x - st.x0, dy = tp.y - st.y0, d = st.d
        st.px = tp.x; st.py = tp.y
        if (ptrCount === 2) { pinchCheck(); if (st.cancelled) return }
        if (!st.moved && Math.hypot(dx, dy) > 16 * u) st.moved = true      // the mockup's long-press tolerance
        if (d.t === "char") {
            if (st.done) return
            if (st.alts) { kb.altsPick(tp.x, false); return }
            var hint = L.hints(kb.zh)[d.k], halfW = st.key.width / 2
            if (kb.flickEnabled && hint && !st.flick && dy <= -flickDy && Math.abs(dx) <= halfW) {
                st.flick = true; kb.showBubble(st.id, st.key, hint, kb.capOf(d.k)); kb.haptic(sideOf(st.key), "light")
            } else if (st.flick && (dy > -flickDy * 0.58 || Math.abs(dx) > halfW)) {
                st.flick = false; kb.showBubble(st.id, st.key, kb.capOf(d.k), "")
            }
        } else if (d.t === "space") {
            if (st.mode === "ptt") kb.pttMove(tp.x, tp.y, st.y0, st.x0)
            else if (st.mode === "cursor") cursorMove(st, tp.x)
            else if (kb.cursorSwipe && Math.abs(dx) >= cursorDx) {
                st.mode = "cursor"; st.fired = true; st.cx = tp.x; st.ct = now(); cursorMode = true
                kb.cursorHint(true, st.key.x > area.width / 2 ? "R" : "L")
            }
        } else if (d.t === "del") {
            // sliding up from the key is the clear gesture even before the 400 ms repeat has started: the
            // pill shows at once, and once the finger has gone up the repeat stops, so nothing more is
            // deleted while aiming (the owner found the gesture unreliable: too early = nothing happened)
            if (dy <= -flickDy && !st.slide) { st.slide = true; if (!st.rep) { st.fired = true; startRepeat(st) } }
            if (st.rep) {
                var hot = kb.clearPillHit(tp.x, tp.y)
                if (hot !== st.hot) { st.hot = hot; kb.clearPillHot(hot); if (hot) kb.haptic("B", "medium") }
            }
        } else if (d.t === "list" && st.lv) {
            // the number pad's symbol column scrolls under a vertical drag; a still finger picks
            if (!st.scroll && Math.abs(dy) > 8 * u) { st.scroll = true; st.li = -1; setListHot(st.key, -1) }
            if (st.scroll) {
                var lv = st.lv, lo = lv.originY - lv.topMargin
                var hi = Math.max(lo, lv.originY + lv.contentHeight + lv.bottomMargin - lv.height)
                lv.contentY = Math.max(lo, Math.min(hi, st.cy0 - dy))
            } else {
                var li = listIndexAt(st.key, tp.y - st.key.y); if (li !== st.li) { st.li = li; setListHot(st.key, li) }
            }
        }
    }

    function end(tp, cancel) {
        var st = ptr[tp.pointId]; if (!st) return
        delete ptr[tp.pointId]; ptrCount--
        if (ptrCount < 2) pinch = null
        if (ptrCount <= 0) { ptrCount = 0; ticker.stop() }
        if (st.cancelled) return
        var d = st.d
        release(st.key)
        if (cancel) { abortKey(st); return }
        switch (d.t) {
        case "char":
            if (!st.done) finishChar(st)
            else { kb.hideBubble(st.id); if (st.alts) kb.closeAlts() }
            break
        case "punct": kb.typePunct(d.ch); break
        case "digit": kb.typeText(d.ch); break
        case "list": if (alive(st.key)) setListHot(st.key, -1); if (!st.scroll && st.li >= 0) kb.typeText(L.NUM_LIST[st.li]); break
        case "space":
            if (st.mode === "ptt") kb.pttEnd(false)
            else if (st.mode === "cursor") { cursorMode = false; kb.cursorHint(false) }
            else kb.doSpace()
            break
        case "del": if (st.rep && st.hot) kb.clearAll(); stopRepeat(st); break
        case "enter": kb.enterHint(null); kb.doEnter(st.newline === true); break
        case "sep": kb.doSeparator(); break
        // letters still held when shift lifts were pressed with it: type them in the current case first
        // (two thumbs letting go together, shift a few ms earlier: HELLO, not HELLo)
        case "shift": commitPending(null); kb.shiftUp(); break
        case "lang": if (!st.held) kb.toggleLang(); break
        case "sym": kb.openPanel("sym"); break
        case "num": kb.setLayout("num"); break
        case "back": kb.setLayout("main"); break
        }
    }

    // a second finger lands: the first key types right away (two-thumb rollover)
    function commitPending(except) {
        // a shift landing within 100 ms of a letter (two thumbs, meant as shift+letter): the letter stays
        // pending and is typed in upper case when its finger lifts. Only while shift is off: with shift
        // already once/locked the letter is committed first, so that second shift press is a plain tap
        // (toggle / unlock) and never reads as a double tap (review: "AB" followed by a stuck caps lock)
        var grace = except && except.d.t === "shift" && kb.shift === 0 ? 100 : 0
        for (var id in ptr) {
            var st = ptr[id]
            if (st === except || st.d.t !== "char" || st.done || st.alts) continue
            if (grace && except.t0 - st.t0 <= grace) continue
            st.done = true; finishChar(st); rolloverAt = now()
        }
    }
    // shift changed (press, lock, IM change): letters already held show their new case in the bubble
    Connections {
        target: area.kb
        function onShiftChanged() {
            for (var id in area.ptr) {
                var st = area.ptr[id]
                if (st.d.t === "char" && !st.done && !st.cancelled && !st.alts && !st.flick && area.alive(st.key))
                    area.kb.showBubble(st.id, st.key, area.kb.capOf(st.d.k), "")
            }
        }
    }
    function finishChar(st) {
        var d = st.d, hint = L.hints(kb.zh)[d.k]
        if (st.alts) { var v = kb.altsValue(); kb.closeAlts(); kb.typeAlternate(v) }
        else if (st.flick && hint) kb.typeText(hint)
        else kb.typeLetter(d.k)
        kb.hideBubble(st.id)
    }
    function abortKey(st) {
        if (st.d.t === "shift" && !st.cancelled) kb.shiftUp()     // the finger count must not stay high
        st.done = st.cancelled = true
        stopRepeat(st)
        if (st.alts) kb.closeAlts()
        kb.enterHint(null)
        if (st.mode === "ptt") kb.pttEnd(true, true)
        if (st.mode === "cursor") { cursorMode = false; kb.cursorHint(false) }
        release(st.key); kb.hideBubble(st.id)
    }
    // the key faces are rebuilt (layout, zh/en, rotation): drop the fingers that still point at old
    // faces; hold-to-talk keeps going, it does not need its key
    onRowsInfoChanged: {
        for (var id in ptr) {
            var st = ptr[id]
            if (st.mode === "ptt") continue
            abortKey(st); delete ptr[id]; ptrCount--
        }
        pinch = null
        if (ptrCount <= 0) { ptrCount = 0; ticker.stop() }
    }
    function abortAll() {
        for (var id in ptr) abortKey(ptr[id])
        ptr = ({}); ptrCount = 0; pinch = null; ticker.stop()
    }

    // two fingers on letters: pinch in → floating keyboard, spread → standard (≥ 43 px, ratio .98 / 1.02)
    function pinchCheck() {
        var a = []; for (var id in ptr) a.push(ptr[id])
        if (a.length !== 2 || kb.layout !== "main") { pinch = null; return }
        for (var i = 0; i < 2; i++) if (a[i].d.t !== "char" || a[i].mode !== "down" || a[i].rep || a[i].alts) { pinch = null; return }   // letters only: a held shift is not a pinch
        var dd = Math.hypot(a[0].px - a[1].px, a[0].py - a[1].py)
        if (!pinch) { pinch = { d0: dd }; return }
        var r = dd / pinch.d0
        if (Math.abs(dd - pinch.d0) >= 43 * u && (r < 0.98 || r > 1.02)) {
            var to = r < 1 ? "float" : "dock"
            if (to === kb.mode || (to === "dock" && kb.mode === "split")) return
            if (now() - rolloverAt < 400) kb.doDelete()   // the first finger's letter went in by rollover: take it back
            for (i = 0; i < 2; i++) abortKey(a[i])
            ptr = ({}); ptrCount = 0; pinch = null; ticker.stop()
            kb.haptic("B", "medium"); kb.setMode(to)
        }
    }

    function cursorMove(st, x) {
        var steps = Math.trunc((x - st.cx) / cursorStep)
        if (!steps) return
        var t = now(), fast = Math.abs(steps * cursorStep) / Math.max(1, t - st.ct) > 0.4 * u   // ≥ 80 px in 200 ms: 2 per step
        st.cx += steps * cursorStep; st.ct = t
        kb.cursorSteps(steps * (fast ? 2 : 1))
        kb.haptic(sideOf(st.key), "light")
    }

    function startRepeat(st) {
        st.rep = true; st.repStart = now(); st.nextRep = st.repStart + 50
        kb.haptic("B", "heavy")
        kb.showClearPill(st.key)
    }
    function stopRepeat(st) { if (!st.rep) return; st.rep = false; kb.hideClearPill() }

    function listIndexAt(it, y) {
        var lv = findList(it)
        if (!lv) return -1
        var idx = lv.indexAt(10, y + lv.contentY - lv.originY)
        return idx
    }
    function findList(it) {
        function walk(o) { if (!o) return null; if (o.objectName === "numList") return o; for (var i = 0; i < o.children.length; i++) { var r = walk(o.children[i]); if (r) return r } return null }
        return walk(it)
    }
    function setListHot(it, i) { var lv = findList(it); if (lv) lv.hotIndex = i }

    Timer {
        id: ticker
        interval: 16; repeat: true
        onTriggered: {
            var t = area.now()
            for (var id in area.ptr) {
                var st = area.ptr[id]
                if (st.cancelled) continue
                var el = t - st.t0, d = st.d
                if (!st.fired) {
                    // one alternates strip at a time, owned by the finger that opened it
                    if (d.t === "char" && !st.done && !st.flick && !st.moved && el >= area.tAlts && kb.alts.length === 0) {
                        st.fired = true; st.alts = true; kb.hideBubble(st.id)
                        kb.openAlts(st.key, d.k, st.px); kb.haptic(area.sideOf(st.key), "heavy"); kb.click("enter")
                    } else if (d.t === "space" && st.mode === "down" && el >= area.tSpace) {
                        st.fired = true; st.mode = "ptt"; kb.pttStart(st.x0)
                    } else if (d.t === "del" && el >= area.tDelete) {
                        st.fired = true; area.startRepeat(st)
                    } else if (d.t === "enter" && kb.layout !== "num" && el >= area.tEnter) {   // the mockup's sendLike()
                        st.fired = true; st.newline = true; kb.enterHint(st.key); kb.haptic(area.sideOf(st.key), "heavy")
                    } else if (d.t === "lang" && el >= area.tLang) {
                        st.fired = true; st.held = true; kb.haptic(area.sideOf(st.key), "heavy"); kb.openPanel("layout")
                    }
                }
                if (st.rep && t >= st.nextRep) {
                    if (!st.hot && !st.slide) { kb.doDelete(); kb.click("del"); kb.haptic(area.sideOf(st.key), "key") }
                    st.nextRep += (t - st.repStart > 2000 ? 30 : 50)
                    if (st.nextRep < t) st.nextRep = t + 30
                }
            }
        }
    }

    MultiPointTouchArea {
        anchors.fill: parent
        enabled: !area.blocked
        mouseEnabled: true
        maximumTouchPoints: 4
        onPressed: (pts) => { for (var i = 0; i < pts.length; i++) area.begin(pts[i]) }
        onUpdated: (pts) => { for (var i = 0; i < pts.length; i++) area.move(pts[i]) }
        onReleased: (pts) => { for (var i = 0; i < pts.length; i++) area.end(pts[i], false) }
        onCanceled: (pts) => { for (var i = 0; i < pts.length; i++) area.end(pts[i], true) }
    }
}
