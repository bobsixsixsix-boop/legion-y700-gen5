// The keyboard: state, preferences, geometry, glass, top band, key grid, overlays and panels.
// It is the controller the touch logic (KeyArea.qml) calls. Everything it sends to the focused
// app goes through `osk` (C++), which speaks fcitx5's DBus virtual keyboard protocol.
import QtQuick
import "."
import QtQuick.Effects
import QtCore
import "Layouts.js" as L

Item {
    id: kb

    // ---------------- preferences (persisted) ----------------
    Settings {
        id: prefs
        category: "keyboard"
        property string skin: "glass-dark"
        property string mode: "dock"
        property real hadj: 1
        property int vol: 5
        property int vib: 3
        property string sound: "std"
        property bool soundOn: true
        property bool bubble: true
        property bool flick: true
        property bool cursorSwipe: true
        property bool tapGlow: true
        property real floatX: 1060
        property real floatY: 260
        property var pinned: []
        property bool symLock: false
    }
    Component.onCompleted: { Theme.skin = prefs.skin; pushPrefs(); symPageForLang(); if (osk.previewState !== "") previewLater.start() }
    // y700-osk --preview=<state>: put the keyboard into one state for a screenshot
    Timer {
        id: previewLater
        interval: 400
        onTriggered: {
            var s = osk.previewState
            if (["toolbox", "feedback", "clip", "edit", "emoji", "sym", "cands", "layout", "voice"].indexOf(s) >= 0) kb.panel = s
            else if (s === "split" || s === "float") kb.mode = s
            else if (s === "dock") kb.mode = "dock"
            else if (s === "num") kb.layout = "num"
            else if (s === "light") Theme.skin = "glass-light"
            else if (s === "ptt") kb.talking = true
            else if (s === "ptt-ja" || s === "ptt-en" || s === "ptt-cancel") { kb.pttX0 = kb.bodyItem.width / 2; kb.talking = true; kb.pttTarget = s.slice(4) }
            else if (s === "alts") { var k = keys.keyByName("a"); if (k) kb.openAlts(k, "a", k.x + k.width / 2) }
            else if (s === "bubble") { var b = keys.keyByName("g"); if (b) { b.down = true; kb.showBubble(1, b, "G", "") } }
        }
    }
    function pushPrefs() {
        osk.setVolume(prefs.soundOn ? prefs.vol : 0)
        osk.setSoundStyle(prefs.sound === "soft" ? 1 : prefs.sound === "mech" ? 2 : 0)
    }

    // ---------------- state ----------------
    property alias mode: prefs.mode
    property alias flickEnabled: prefs.flick
    property alias cursorSwipe: prefs.cursorSwipe
    readonly property bool zh: osk.zh          // a composing layout: Chinese (rime) or Japanese romaji (mozc)
    readonly property string lang: osk.lang    // zh | en | ja
    readonly property bool ja: lang === "ja"
    property int shift: 0                      // English: 0 off, 1 once, 2 caps lock
    property int shiftHeld: 0                  // shift fingers down right now: letters are upper case while held
    property bool shiftUsed: false             // a letter was typed since the last shift press
    property bool shiftWasOnce: false          // shift was already "once" when pressed: that release turns it off
    property real shiftTapT: 0                 // time of the last shift press (a second press within 400 ms locks)
    onZhChanged: { shift = 0; shiftHeld = 0; shiftUsed = false; symPageForLang() }   // the IM changed under us: no shift key in Chinese
    property string layout: "main"             // main | num
    property string panel: ""                  // "" | toolbox | feedback | clip | edit | emoji | sym | cands | layout | voice
    property bool talking: false
    readonly property bool composing: osk.preedit !== "" || osk.candidates.length > 0
    // 全部候选 closes by itself once the pinyin is used up (the mockup's renderCompose)
    onComposingChanged: if (!composing && panel === "cands") candsAutoClose.restart()
    Timer { id: candsAutoClose; interval: 30; onTriggered: if (!kb.composing && kb.panel === "cands") kb.closePanel() }
    // panel state that outlives the panels: pinned symbols, last categories
    property int symCat: 0
    property alias symLock: prefs.symLock      // 锁定: picking a symbol keeps the panel open (vivo remembers it)
    property int emoCat: 0
    property int clipCat: 0
    property bool adjusting: false
    property real pullY: 0                     // band pulled down: the keyboard follows the finger
    readonly property bool splitGlassNow: body.splitGlass
    readonly property real splitHalfW: body.half

    // ---------------- geometry (design px x u) ----------------
    property real screenW: 1600
    readonly property bool portrait: screenW < osk.screenHeight
    // design px = logical px on this screen in both orientations (the short side is 1003)
    readonly property real u: Math.max(0.8, Math.min(1.25, Math.min(screenW, osk.screenHeight) / 1003))
    readonly property var m: L.metrics(mode, prefs.hadj, portrait)
    readonly property real bandH: m.band * u
    readonly property real keyH: m.keyH * u
    readonly property real botH: m.bot * u
    readonly property real kbH: bandH + keyH + botH
    readonly property real kbW: mode === "float" ? m.W * u : screenW
    readonly property real fpad: mode === "float" ? 28 * u : 0      // room for the floating keyboard's shadow
    implicitWidth: kbW + 2 * fpad
    implicitHeight: kbH + 2 * fpad

    // the keyboard rectangle inside the window
    Item {
        id: body
        x: kb.fpad; y: kb.fpad
        width: kb.kbW; height: kb.kbH
        transform: Translate { y: kb.pullY }

        // ---- glass ----
        readonly property bool splitGlass: kb.mode === "split" && kb.layout === "main" && kb.panel === "" && !kb.talking
        readonly property real half: L.splitHalf(kb.portrait) * width
        RectangularShadow {
            visible: kb.mode === "float"
            anchors.fill: glassFull
            radius: 20 * kb.u; blur: 40 * kb.u; offset.y: 12 * kb.u; spread: 0
            color: Qt.rgba(0, 0, 0, 0.45)
        }
        Rectangle {
            id: glassFull
            visible: !body.splitGlass
            anchors.fill: parent
            color: Theme.mat
            topLeftRadius: 20 * kb.u; topRightRadius: 20 * kb.u
            bottomLeftRadius: kb.mode === "float" ? 20 * kb.u : 0; bottomRightRadius: bottomLeftRadius
            border.width: kb.mode === "float" ? 1 : 0; border.color: Theme.hair
            Rectangle { visible: kb.mode !== "float"; x: 20 * kb.u; width: parent.width - 40 * kb.u; height: 1; color: Theme.hair }
        }
        Item {
            visible: body.splitGlass
            anchors.fill: parent
            Rectangle { width: parent.width; height: kb.bandH; color: Theme.mat; topLeftRadius: 20 * kb.u; topRightRadius: 20 * kb.u
                        Rectangle { x: 20 * kb.u; width: parent.width - 40 * kb.u; height: 1; color: Theme.hair } }
            Rectangle { y: kb.bandH; width: body.half; height: parent.height - kb.bandH; color: Theme.mat; bottomRightRadius: 18 * kb.u }
            Rectangle { x: parent.width - body.half; y: kb.bandH; width: body.half; height: parent.height - kb.bandH; color: Theme.mat; bottomLeftRadius: 18 * kb.u }
        }

        // ---- top band: toolbar or composition ----
        Band {
            id: band
            kb: kb
            width: parent.width; height: kb.bandH
            opacity: kb.panel !== "" && kb.panel !== "toolbox" && kb.panel !== "layout" ? 0 : 1
            enabled: opacity === 1
        }

        // ---- keys ----
        KeyArea {
            id: keys
            kb: kb
            y: kb.bandH
            width: parent.width; height: kb.keyH
            u: kb.u; fs: kb.m.fs
            keyTop: 0; keyH: kb.keyH
            blocked: kb.panel !== "" || kb.adjusting
            opacity: kb.panel !== "" || kb.talking ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        }

        // ---- panels ----
        Panels { id: panels; kb: kb; anchors.fill: parent; z: 5 }

        // ---- overlays (keyboard coordinates; keys sit at y = bandH) ----
        Repeater {
            model: bubbleModel
            delegate: Rectangle {
                required property var model
                readonly property var modelData: model
                z: 20
                x: modelData.bx; y: modelData.by; width: modelData.bw; height: modelData.bh
                opacity: modelData.out ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: 80 } }
                radius: 10 * kb.u
                color: Theme.pop; border.width: 1; border.color: Theme.popLine
                layer.enabled: true
                layer.effect: MultiEffect { shadowEnabled: true; shadowColor: Qt.rgba(0, 0, 0, Theme.popShadow); shadowBlur: 0.4; shadowVerticalOffset: 2 }
                Text { visible: modelData.sub !== ""; anchors.horizontalCenter: parent.horizontalCenter; y: 8 * kb.u
                       text: modelData.sub; color: Theme.ink2; font.family: Theme.font; font.pixelSize: 15 * kb.u }
                Text { anchors.centerIn: parent; text: modelData.text; color: modelData.sub !== "" ? Theme.accInk : Theme.ink
                       font.family: Theme.font; font.weight: Font.Medium; font.pixelSize: 40 * kb.u * kb.m.fs }
            }
        }
        Rectangle {
            id: altsBox
            z: 21
            visible: kb.alts.length > 0
            x: kb.altsX; y: kb.altsY
            width: altsRow.width + 12 * kb.u; height: 80 * kb.u
            radius: 10 * kb.u; color: Theme.pop; border.width: 1; border.color: Theme.popLine
            Row {
                id: altsRow
                x: 6 * kb.u; y: 6 * kb.u; spacing: 4 * kb.u
                Repeater {
                    model: kb.alts
                    delegate: Rectangle {
                        required property var modelData
                        required property int index
                        width: Math.max(64 * kb.u, t.implicitWidth + 20 * kb.u); height: 68 * kb.u; radius: 6 * kb.u
                        color: index === kb.altSel ? Theme.acc : "transparent"
                        Text { id: t; anchors.centerIn: parent; text: modelData; color: index === kb.altSel ? "#ffffff" : Theme.ink
                               font.family: Theme.font; font.weight: Font.Medium; font.pixelSize: 28 * kb.u }
                    }
                }
            }
        }
        Rectangle {
            id: clearPill
            z: 21
            visible: kb.clearPillOn
            x: kb.clearPillX; y: kb.clearPillY
            width: Math.max(223 * kb.u * kb.m.fs, pillRow.width + 40 * kb.u); height: 60 * kb.u
            radius: 10 * kb.u
            color: kb.clearHot ? Theme.danger : Theme.pop; border.width: kb.clearHot ? 0 : 1; border.color: Theme.popLine
            Row {
                id: pillRow
                anchors.centerIn: parent; spacing: 8 * kb.u
                Image { anchors.verticalCenter: parent.verticalCenter; width: 22 * kb.u; height: width
                        sourceSize: Qt.size(Math.round(width * Screen.devicePixelRatio), Math.round(width * Screen.devicePixelRatio))
                        source: Theme.ic("trash", kb.clearHot ? "#ffffff" : Theme.ink, 2.4) }
                Text { anchors.verticalCenter: parent.verticalCenter; text: kb.clearHot ? "松手清空" : "滑至此处清空"
                       color: kb.clearHot ? "#ffffff" : Theme.ink; font.family: Theme.font; font.pixelSize: 19 * kb.u }
            }
        }
        Rectangle {
            id: enterTip
            z: 21
            visible: kb.enterTipKey !== null
            height: 52 * kb.u; width: enterText.implicitWidth + 40 * kb.u; radius: height / 2
            color: "#404040"; border.width: 1; border.color: Qt.rgba(1, 1, 1, .12)
            x: kb.enterTipKey ? Math.min(body.width - width - 8 * kb.u, kb.enterTipKey.x + kb.enterTipKey.width / 2 - width / 2) : 0
            y: kb.enterTipKey ? kb.bandH + kb.enterTipKey.y - 60 * kb.u : 0
            Text { id: enterText; anchors.centerIn: parent; text: "松手换行"; color: "#ffffff"; font.family: Theme.font; font.weight: Font.DemiBold; font.pixelSize: 18 * kb.u }
        }
        Row {
            id: cursorTip
            z: 19
            visible: kb.cursorTipSide !== ""
            y: kb.bandH + 10 * kb.u; height: kb.keyH * 0.45
            x: kb.mode === "split" ? (kb.cursorTipSide === "R" ? body.width - body.half + (body.half - width) / 2 : (body.half - width) / 2) : (body.width - width) / 2
            spacing: (kb.mode === "split" ? 12 : 22) * kb.u
            // arrows nudge outwards and back (the mockup's 900 ms "nudge")
            property real nudge: 0
            SequentialAnimation on nudge {
                running: cursorTip.visible; loops: Animation.Infinite
                NumberAnimation { from: 0; to: 1; duration: 450; easing.type: Easing.InOutSine }
                NumberAnimation { from: 1; to: 0; duration: 450; easing.type: Easing.InOutSine }
            }
            Image { anchors.verticalCenter: parent.verticalCenter; width: 30 * kb.u; height: width; sourceSize: Qt.size(64, 64); source: Theme.ic("arrow_left", Theme.accInk, 2.2)
                    opacity: 1 - 0.45 * cursorTip.nudge; transform: Translate { x: -6 * kb.u * cursorTip.nudge } }
            Text { anchors.verticalCenter: parent.verticalCenter; text: "左右滑动移动光标"; color: Theme.ink; font.family: Theme.font; font.pixelSize: (kb.mode === "split" ? 16 : 18) * kb.u }
            Image { anchors.verticalCenter: parent.verticalCenter; width: 30 * kb.u; height: width; sourceSize: Qt.size(64, 64); source: Theme.ic("arrow_right", Theme.accInk, 2.2)
                    opacity: 1 - 0.45 * cursorTip.nudge; transform: Translate { x: 6 * kb.u * cursorTip.nudge } }
        }

        // hold-to-talk sheet over the key area
        Rectangle {
            id: ptt
            z: 18
            visible: kb.talking
            x: 12.5 * kb.u; width: parent.width - 25 * kb.u
            y: kb.bandH + 5.33 * kb.u; height: kb.keyH - 5.33 * kb.u
            radius: 18 * kb.u; color: Theme.sheet; border.width: 1; border.color: Theme.popLine
            Column {
                anchors.horizontalCenter: parent.horizontalCenter
                y: 16 * kb.u; spacing: 10 * kb.u
                // Slide targets as one segmented control (the control centre's 性能档 style), always
                // centred in the sheet: 译成日语 | 取消 | 译成英语. A highlight thumb slides to the
                // segment under the finger: accent for the translations, red for cancel.
                Rectangle {
                    id: seg
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: kb.pttSegW * 3 + 10 * kb.u; height: 60 * kb.u
                    radius: 16 * kb.u; color: Theme.card
                    readonly property var order: ["ja", "cancel", "en"]
                    readonly property int hot: order.indexOf(kb.pttTarget)
                    Rectangle {
                        id: thumb
                        y: 5 * kb.u; width: kb.pttSegW; height: parent.height - 10 * kb.u; radius: 12 * kb.u
                        property int at: seg.hot < 0 ? 1 : seg.hot
                        x: 5 * kb.u + at * kb.pttSegW
                        opacity: seg.hot < 0 ? 0 : 1
                        color: kb.pttTarget === "cancel" ? Theme.danger : Theme.acc
                        Behavior on x { enabled: thumb.opacity > 0; NumberAnimation { duration: 180; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] } }
                        Behavior on opacity { NumberAnimation { duration: 120 } }
                        Behavior on color { ColorAnimation { duration: 120 } }
                    }
                    Row {
                        x: 5 * kb.u; y: 5 * kb.u
                        Repeater {
                            model: ["译成日语", "取消", "译成英语"]
                            delegate: Item {
                                required property string modelData
                                required property int index
                                width: kb.pttSegW; height: seg.height - 10 * kb.u
                                Text {
                                    anchors.centerIn: parent
                                    text: modelData
                                    color: seg.hot === index ? "#ffffff" : Theme.ink
                                    Behavior on color { ColorAnimation { duration: 120 } }
                                    font.family: Theme.font; font.weight: seg.hot === index ? Font.DemiBold : Font.Medium
                                    font.pixelSize: 17 * kb.u
                                }
                            }
                        }
                    }
                }
                Text { anchors.horizontalCenter: parent.horizontalCenter
                       text: kb.pttTarget === "ja" ? "松手翻译成日语" : kb.pttTarget === "en" ? "松手翻译成英语" : kb.pttTarget === "cancel" ? "松手取消输入" : "我在听，请说"
                       color: kb.pttCancel ? Theme.ink3 : kb.pttTarget !== "" ? Theme.accInk : Theme.ink
                       font.family: Theme.font; font.weight: Font.Medium; font.pixelSize: 20 * kb.u }
                Wave { anchors.horizontalCenter: parent.horizontalCenter; u: kb.u; bars: 31; live: kb.talking && !kb.pttCancel; level: osk.voice.level }
                Text { anchors.horizontalCenter: parent.horizontalCenter; text: "手指上滑到目标再松手"
                       color: Theme.ink3; font.family: Theme.font; font.pixelSize: 15 * kb.u }
            }
        }

        // height adjust overlay
        Adjust { id: adjust; kb: kb; anchors.fill: parent; z: 30 }

        // floating keyboard drag bar (bottom, like iPad)
        Item {
            id: dragBar
            visible: kb.mode === "float"
            anchors.bottom: parent.bottom; width: parent.width; height: 30 * kb.u
            z: 6
            Rectangle { anchors.centerIn: parent; width: 48 * kb.u; height: 5 * kb.u; radius: height / 2; color: Theme.ink2 }
            DragHandler {
                id: drag
                target: null
                // Work in screen coordinates: the window itself moves under the finger, so
                // window-relative translation would only follow at half speed. Screen position of
                // the finger = scene position + window origin (floatX - fpad, floatY - fpad).
                property real gx: 0; property real gy: 0      // finger offset inside the keyboard at grab
                onActiveChanged: {
                    if (active) {
                        gx = centroid.scenePressPosition.x - kb.fpad; gy = centroid.scenePressPosition.y - kb.fpad
                        kb.haptic("B", "medium"); return
                    }
                    // dropped within 24 px of the bottom edge: back to the docked keyboard
                    if (prefs.floatY + kb.kbH > osk.screenHeight - 24 * kb.u) {
                        prefs.floatX = Math.max(0, kb.screenW - kb.m.W * kb.u - 60 * kb.u); prefs.floatY = 260 * kb.u
                        kb.setMode("dock")
                    }
                }
                onCentroidChanged: {
                    if (!active) return
                    var fx = centroid.scenePosition.x + prefs.floatX - kb.fpad, fy = centroid.scenePosition.y + prefs.floatY - kb.fpad
                    prefs.floatX = Math.max(0, Math.min(kb.screenW - kb.kbW, fx - gx))
                    prefs.floatY = Math.max(0, Math.min(osk.screenHeight - kb.kbH, fy - gy))
                }
            }
        }

        // toast (centred in the band)
        Rectangle {
            id: toastBox
            z: 40
            property string text: ""
            property string action: ""
            property var fn: null
            anchors.horizontalCenter: parent.horizontalCenter
            y: (kb.bandH - height) / 2
            height: 48 * kb.u; width: Math.min(600 * kb.u, tRow.width + (action !== "" ? 28 : 40) * kb.u)
            radius: 14 * kb.u; color: Qt.rgba(28 / 255, 31 / 255, 38 / 255, .96); border.width: 1; border.color: Qt.rgba(1, 1, 1, .10)
            opacity: 0; scale: 0.95; visible: opacity > 0
            states: State { name: "on"; PropertyChanges { toastBox.opacity: 1; toastBox.scale: 1 } }
            transitions: Transition { NumberAnimation { properties: "opacity,scale"; duration: 180; easing.type: Easing.OutCubic } }
            Row {
                id: tRow
                anchors.centerIn: parent; spacing: 10 * kb.u
                Text { anchors.verticalCenter: parent.verticalCenter; text: toastBox.text; color: "#ffffff"; font.family: Theme.font; font.weight: Font.DemiBold; font.pixelSize: 16 * kb.u }
                Rectangle {
                    visible: toastBox.action !== ""
                    anchors.verticalCenter: parent.verticalCenter
                    height: 34 * kb.u; width: aText.implicitWidth + 28 * kb.u; radius: height / 2; color: Qt.rgba(1, 1, 1, .14)
                    Text { id: aText; anchors.centerIn: parent; text: toastBox.action; color: "#8fb0ff"; font.family: Theme.font; font.pixelSize: 15 * kb.u }
                    TapHandler { gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: { if (toastBox.fn) toastBox.fn(); toastBox.state = "" } }
                }
            }
            Timer { id: toastTimer; onTriggered: toastBox.state = "" }
        }
    }

    // ---------------- feedback ----------------
    function click(kind) {
        if (!prefs.soundOn) return
        osk.click(kind === "space" ? 1 : kind === "del" ? 2 : kind === "enter" ? 3 : kind === "tool" ? 4 : kind === "expand" ? 5 : 0)
    }
    // vivo-like levels anchored on the control centre's tick (0x5000 / 18 ms)
    readonly property var vibLevels: [[0, 0], [8, 0x4000], [12, 0x4000], [16, 0x5000], [16, 0x8000], [20, 0xA000]]
    function haptic(side, kind) {
        if (!prefs.vib) return
        var ms, mag
        if (kind === "key") { ms = vibLevels[prefs.vib][0]; mag = vibLevels[prefs.vib][1] }
        else if (kind === "light") { ms = 8; mag = 0x4000 }
        else if (kind === "medium") { ms = 20; mag = 0x8000; side = "B" }
        else { ms = 24; mag = 0xB000; side = "B" }
        osk.haptic(side, ms, mag)
    }
    function toast(text, action, ms, fn) {
        toastBox.text = text; toastBox.action = action || ""; toastBox.fn = fn || null
        toastBox.state = "on"; toastTimer.interval = ms || 1400; toastTimer.restart()
    }

    // ---------------- tap light ("点触光感") ----------------
    function glowAt(key, x, y) {
        if (!prefs.tapGlow || Theme.tap.a === 0 || !key || !key.glowLayer) return
        unglowNow(key)
        glowSpot.createObject(key.glowLayer, { cx: x, cy: y })
    }
    function unglow(key) { if (!key || !key.glowLayer) return; var l = key.glowLayer; for (var i = 0; i < l.children.length; i++) l.children[i].fade() }
    function unglowNow(key) { if (!key || !key.glowLayer) return; var l = key.glowLayer; for (var i = l.children.length - 1; i >= 0; i--) l.children[i].destroy() }
    // which motor: by the item's half of the SCREEN (the floating keyboard is not the whole screen)
    function sideAt(it) {
        var x = it.mapToItem(null, it.width / 2, 0).x + (mode === "float" ? prefs.floatX - fpad : 0)
        return x < screenW / 2 ? "L" : "R"
    }
    Component {
        id: glowSpot
        Item {
            id: spot
            property real cx; property real cy
            x: cx - width / 2; y: cy - height / 2
            width: 160 * kb.u; height: width
            Rectangle { anchors.fill: parent; radius: width / 2; color: Theme.tap; layer.enabled: true
                        layer.effect: MultiEffect { blurEnabled: true; blur: 1.0; blurMax: 48 } }
            function fade() { fadeOut.start() }
            NumberAnimation { id: fadeOut; target: spot; property: "opacity"; to: 0; duration: 220; onFinished: spot.destroy() }
        }
    }

    // ---------------- bubbles, alternates, clear pill, enter tip, cursor tip ----------------
    // Bubbles: one live bubble per finger (pid); on release it is unbound from the finger (pid -1),
    // lingers 70 ms, fades 80 ms and goes. Touch ids get reused, so nothing is looked up by id
    // after release (the design's .bub.out).
    ListModel { id: bubbleModel }
    function capOf(k) { return (zh || shift > 0) ? k.toUpperCase() : k }
    function showBubble(id, key, text, sub) {
        if (!prefs.bubble) return
        var fs = m.fs, bw = Math.min(80 * u * fs, key.width + 18 * u), bh = 96 * u * fs
        var b = { pid: id, out: false, until: 0, bx: key.x + key.width / 2 - bw / 2, by: bandH + key.y + 24 * u * fs - bh, bw: bw, bh: bh, text: text, sub: sub }
        for (var i = 0; i < bubbleModel.count; i++) if (bubbleModel.get(i).pid === id) { bubbleModel.set(i, b); return }
        bubbleModel.append(b)
    }
    function hideBubble(id) {
        var t = Date.now()
        for (var i = 0; i < bubbleModel.count; i++) if (bubbleModel.get(i).pid === id) { bubbleModel.setProperty(i, "pid", -1); bubbleModel.setProperty(i, "until", t + 70) }
        bubbleGc.start()
    }
    Timer {
        id: bubbleGc; interval: 16; repeat: true
        onTriggered: {
            var t = Date.now(), pending = false
            for (var i = bubbleModel.count - 1; i >= 0; i--) {
                var o = bubbleModel.get(i)
                if (o.pid !== -1) continue
                if (!o.out && t >= o.until) { bubbleModel.setProperty(i, "out", true); bubbleModel.setProperty(i, "until", t + 90) }
                else if (o.out && t >= o.until) { bubbleModel.remove(i); continue }
                pending = true
            }
            if (!pending) stop()
        }
    }

    property var alts: []
    property int altSel: 0
    property real altsX: 0
    property real altsY: 0
    property var altsKey: null
    function openAlts(key, k, fingerX) {
        alts = L.alternates(k, zh); altsKey = key
        var w = 0; for (var i = 0; i < alts.length; i++) w += Math.max(64 * u, 28 * u * alts[i].length * 0.6 + 20 * u)
        w += 4 * u * (alts.length - 1) + 12 * u
        altsX = Math.max(8 * u, Math.min(body.width - w - 8 * u, key.x + key.width / 2 - w / 2))
        altsY = Math.max(2 * u, bandH + key.y + 24 * u * m.fs - 80 * u)
        altSel = 0; altsPick(fingerX, true)
    }
    function altsPick(fx, silent) {
        var best = altSel, bd = 1e9, x = altsX + 6 * u
        for (var i = 0; i < alts.length; i++) {
            var w = Math.max(64 * u, 28 * u * alts[i].length * 0.6 + 20 * u), c = x + w / 2, d = Math.abs(c - fx)
            if (d < bd) { bd = d; best = i }
            x += w + 4 * u
        }
        if (best !== altSel && !silent) { haptic(altsKey ? sideAt(altsKey) : "L", "light"); click("enter") }
        altSel = best
    }
    function altsValue() { return alts[altSel] }
    function closeAlts() { alts = []; altsKey = null }

    property bool clearPillOn: false
    property bool clearHot: false
    property real clearPillX: 0
    property real clearPillY: 0
    function showClearPill(key) {
        var w = Math.max(223 * u * m.fs, 200 * u)
        clearPillX = key.x + key.width - w; clearPillY = bandH + key.y - 8 * u - 60 * u
        clearHot = false; clearPillOn = true
    }
    function hideClearPill() { clearPillOn = false; clearHot = false }
    function clearPillHit(x, y) {   // x, y in KeyArea coordinates: within the pill's columns, at or above it (overshoot counts)
        return x >= clearPillX - 10 * u && x <= clearPillX + clearPill.width + 10 * u && y + bandH <= clearPillY + 60 * u + 14 * u
    }
    function clearPillHot(h) { clearHot = h }

    property var enterTipKey: null
    function enterHint(key) { enterTipKey = key }
    property string cursorTipSide: ""
    function cursorHint(on, side) { cursorTipSide = on ? (side || "L") : "" }

    // ---------------- typing ----------------
    // Everything that goes to the app passes through sent(): while a shift finger is down, any output
    // uses the shift up (release then turns it off, like a physical keyboard). The typed log exists
    // only in --preview for the debug hook: a live keyboard must not keep a keystroke log that any
    // process on the session bus could read back (passwords).
    property string typedLog: ""
    function sent(s) {
        if (shiftHeld > 0) shiftUsed = true
        if (osk.previewState !== "") typedLog = (typedLog + s).slice(-200)
    }
    // shift "once" is used up by a letter (or a long-press alternate, as in the mockup); a held shift
    // lasts until the finger lifts (sent() marks it used)
    function consumeShift() { if (shift === 1 && shiftHeld === 0) shift = 0 }
    function typeLetter(k) {
        if (zh) { osk.key(k); sent(k); return }
        var ch = shift > 0 ? k.toUpperCase() : k
        osk.key(ch); sent(ch)
        consumeShift()
    }
    function typeAlternate(v) {
        if (zh && /^[a-z]$/.test(v)) { osk.key(v); sent(v); return }
        typeText(v)
        if (!zh) consumeShift()
    }
    // any literal text: commits the current composition first so the order stays right
    function typeText(s) {
        if (composing) osk.selectCandidate(0)
        osk.commit(s); sent(s)
    }
    function typePunct(ch) {
        // rime turns , . into ，。 and commits the first candidate before them
        // mozc: , . - become 、。ー the same way
        var sym = ch === "，" || ch === "," || ch === "、" ? "comma" : ch === "。" || ch === "." ? "period" : ch === "@" ? "at" : ch === "ー" ? "minus" : ""
        if (sym !== "") { osk.key(sym); sent(ch) } else typeText(ch)
    }
    function doDelete() { osk.key("BackSpace"); sent("<del>") }
    function doSpace() { osk.key("space"); sent("<sp>") }
    function doEnter(newline) {
        sent("<ret>")
        if (composing) { osk.key("Return"); return }       // rime: commit the raw letters
        if (newline) osk.keyCombo("Return", ["Shift"])      // chat apps: Shift+Enter = new line
        else osk.key("Return")
    }
    function doSeparator() { if (composing) osk.key("apostrophe") }
    // Shift behaves like a physical shift key plus the touch-keyboard taps, and it acts on PRESS so
    // the key faces and the bubble of a letter already held change case at once:
    //   hold shift + letters      every letter upper case; lifting shift turns it off
    //   tap shift (nothing typed) once: the next letter is upper case
    //   tap, tap within 400 ms    caps lock; any press while locked unlocks
    //   tap while already "once"  off
    function shiftDown() {
        var t = Date.now()
        shiftHeld++
        shiftWasOnce = false
        if (shift === 2) shift = 0
        else if (shift === 1 && !shiftUsed && t - shiftTapT < 400) shift = 2
        else if (shift === 1) shiftWasOnce = true
        else shift = 1
        shiftTapT = t; shiftUsed = false
    }
    function shiftUp() {
        shiftHeld = Math.max(0, shiftHeld - 1)
        if (shiftHeld > 0 || shift !== 1) return
        if (shiftUsed || shiftWasOnce) shift = 0
        else shiftTapT = Date.now()           // a tap: the 400 ms double-tap window runs from this release
    }
    // 中 → 英 → 日 (romaji) → 中
    function toggleLang() { setLang(lang === "zh" ? "en" : lang === "en" ? "ja" : "zh") }
    function setLang(l) {
        if (l === lang) return
        shift = 0; shiftHeld = 0; shiftUsed = false
        osk.setLang(l)
        toast(l === "zh" ? "中文" : l === "en" ? "English" : "日本語（ローマ字）", "", 900)
    }
    function setLayout(l) { if (l === layout) return; layout = l }
    function cursorSteps(n) {
        if (composing) { band.scrollCandidates(n * 40 * u); return }
        var name = n < 0 ? "Left" : "Right"
        for (var i = 0; i < Math.abs(n); i++) osk.key(name)
    }
    property bool undoArmed: false
    function clearAll() {
        sent("<clr>")
        if (composing) { osk.key("Escape"); return }
        osk.clearAll()          // Ctrl+A then BackSpace, both real keys on one ordered path
        undoArmed = true
        toast("已清空", "撤销", 5000, function () { osk.keyCombo("z", ["Control"]); kb.undoArmed = false })
    }

    // ---------------- hold space to talk ----------------
    // Slide up from the space bar to choose what happens on release: straight up = cancel,
    // up-left = translate to Japanese, up-right = translate to English (the owner's request).
    // Only above the 80 px line counts; left/right is the finger's offset from where it went down.
    property string pttTarget: ""              // "" | cancel | ja | en
    readonly property bool pttCancel: pttTarget === "cancel"
    property real pttX0: 0
    property real pttT0: 0
    property string pttPending: ""             // what the last release asked for (toast wording)
    // one segment of the slide-target control; also the left/right step of the gesture
    readonly property real pttSegW: Math.min(170 * u, (body.width - 25 * u - 48 * u - 10 * u) / 3)
    readonly property real pttSpread: pttSegW
    function pttStart(x0) {
        if (composing) osk.selectCandidate(0)
        talking = true; pttTarget = ""; pttT0 = Date.now(); pttX0 = x0 !== undefined ? x0 : body.width / 2
        haptic("B", "medium")
        osk.voice.start()
    }
    function pttMove(x, y, y0, x0) {
        var t = ""
        if (y < y0 - 80 * u) {
            var dx = x - (x0 !== undefined ? x0 : pttX0)
            t = dx < -pttSpread / 2 ? "ja" : dx > pttSpread / 2 ? "en" : "cancel"
        }
        if (t !== pttTarget) { pttTarget = t; haptic(sideAt(keys), "light") }
    }
    function pttEnd(cancel, quiet) {
        talking = false
        var t = pttTarget; pttTarget = ""
        if (quiet || cancel || t === "cancel") { osk.voice.cancel(); if (!quiet) toast("已取消语音输入", "", 1400); return }
        pttPending = t
        osk.voice.finish(t === "ja" || t === "en" ? t : "")
    }
    Connections {
        target: osk.voice
        function onRecognised(text) { if (kb.panel === "voice") panels.voiceText(text); else osk.commit(text) }
        function onFailed(msg) {
            if (msg === "short") kb.toast("说话时间太短，请重新尝试", "", 1600)
            else kb.toast(msg, "", 2200)
            if (kb.panel === "voice") panels.voiceFailed(msg)
        }
        function onStateChanged() {
            if (osk.voice.state !== 2 || kb.panel === "voice") return
            kb.toast(kb.pttPending === "ja" ? "翻译成日语…" : kb.pttPending === "en" ? "翻译成英语…" : "识别中…", "", 1200)
        }
    }

    // ---------------- panels, modes ----------------
    function openPanel(id) {
        if (panel === id) { closePanel(); return }
        if (composing && id !== "cands") osk.selectCandidate(0)
        panel = id
    }
    // a symbol from the panel; 锁定 keeps the panel open for the next one
    function pickSymbol(s) { typeText(s); if (!symLock) closePanel() }
    function setSymLock(on) { symLock = on }       // the button and the title note show the state; no toast
    // the symbol panel's language page follows the IM (中文 ↔ 英文) when the IM changes; a page the owner
    // picked by hand stays until then, and the other pages are never touched
    function symPageForLang() { if (symCat <= 1) symCat = zh ? 0 : 1 }
    function closePanel() { if (panel === "voice") osk.voice.cancel(); panel = "" }
    function setMode(mm) {
        if (mm === mode) return
        adjust.cancel()
        if (layout === "num" && mm !== "dock") layout = "main"
        mode = mm
        toast(mm === "split" ? "已启用分离式布局" : mm === "float" ? "按住底部横条可拖动键盘" : "已恢复标准键盘", "", 1300)
    }
    function setSkin(s) { prefs.skin = s; Theme.skin = s }
    function hideKeyboard() {
        if (panel !== "") closePanel()
        adjust.cancel()
        keys.abortAll()
        osk.hideKeyboard()
    }
    function startAdjust() { closePanel(); adjust.start() }
    DebugHook { kb: kb }                // test hook, see DebugHook.qml
    property alias prefs: prefs
    property alias keysArea: keys
    property alias bodyItem: body
    property alias panelsItem: panels
}
