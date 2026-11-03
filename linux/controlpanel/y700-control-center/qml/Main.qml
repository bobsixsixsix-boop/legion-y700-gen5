// The curtain: a full-screen frosted sheet pulled down from the top edge (owner 10-22: 「左边下拉出通知中心，右边
// 下拉出控制中心。整屏模糊背景，这样可以突出内容」, vivo OriginOS). Its lower edge follows the finger; once down
// it covers the whole screen, KWin's blur behind all of it. On it: the time and date big at the top left, and
// one half: the notification centre (NotesPane.qml, pulled from the left half) or the controls (pulled from
// the right half; two columns laid out for the right thumb, see `ctl`: the thumb column with the sliders and
// the frequent tiles, the far column with the rare toggles, the keyboard and power + Android; or a device list).
// D-Bus toggle/show open the controls, showSide("left") the notifications.
// Closes on a tap on the empty curtain, a push up on the header or the bottom handle, or an app launched from it.
// Wi-Fi / Bluetooth lists: long press on their tiles. Power menu and Android both confirm in place.
// 「后台应用」 (the apps' tray items, src/tray.h): tap opens the app, long press shows its own menu in the thumb column;
// more apps than two rows hold: the last tile opens the list of all of them there.
import QtQuick
import QtQuick.Layouts

Window {
    id: win
    visible: false
    color: "transparent"
    flags: Qt.FramelessWindowHint
    title: "y700-control-center"
    // the compositor sizes a layer-shell window anchored on all four sides (LayerShellQt sends 0x0), but only
    // when it is first shown; until then Qt's default is 500x500, and the first pull after a start computed
    // the curtain's y from that height (the sheet came down 500 px ahead of the finger, with the blur region
    // sized to match, for one frame). The screen size is the right guess, so the first configure is a no-op.
    width: Screen.width
    height: Screen.height

    readonly property bool open: backend.visible
    readonly property var st: backend.st
    readonly property var media: backend.media
    readonly property bool notes: backend.side === "left"   // the notification centre, else the controls
    readonly property int margin: width >= 1200 ? 56 : 28
    readonly property int colW: 340
    readonly property color accent: "#2e6bf6"
    readonly property color danger: "#ff3b30"
    property string page: ""              // "" | "wifi" | "bt" | "tray" (a tray item's menu) | "trayall" (every app)
    property bool confirmAndroid: false
    property bool powerOpen: false
    property string powerArmed: ""        // "reboot" | "poweroff" waiting for the second tap
    onOpenChanged: {
        if (!open) { confirmAndroid = false; powerOpen = false; powerArmed = "" ; page = ""; trayPending = ""; kbdPending = false }
        else now = new Date()
        if (!tracking) settle()
    }
    // leaving the menu page (back at its top, another page, the curtain closed) closes the app's menu ("closed");
    // a tray tap still on its way is forgotten with the page it was made on (its answer must not swap a page the
    // owner has moved on from, nor close the curtain behind them)
    onPageChanged: {
        if (page === "wifi") backend.scanWifi(); if (page === "bt") backend.scanBt()
        if (page !== "tray") tray.closeMenu()
        trayPending = ""
    }

    // ---------------- 「后台应用」 (src/tray.h)
    // the tray item tapped last, until its Activate answers (at most 1 s): its tile or row dims and takes no second
    // tap, and only that answer acts (a late one for a tap the owner has given up on does nothing)
    property string trayPending: ""
    property real trayPendingAt: 0
    // where the menu page goes back to: the grid, or the list of every app it was opened from
    property string trayBack: ""
    // the item of `key` as tray.items has it (the tiles and rows are made per key, see tray.keys; they read the rest
    // here, so a new icon or label changes them in place)
    function trayItem(key) {
        const l = tray.items
        for (let i = 0; i < l.length; ++i) if (l[i].key === key) return l[i]
        return { key: key, label: "这个应用", icon: "", attention: false, hasMenu: false, itemIsMenu: false, category: "" }
    }
    function trayActivate(key, c) {
        win.trayPending = key
        win.trayPendingAt = Date.now()
        tray.activate(key, Math.round(c.x), Math.round(c.y))
    }
    // a tray item's own menu: a page of the thumb column like the device lists (long press on its tile, an item
    // that is only a menu, or an Activate that the app refused)
    function openTrayMenu(key) {
        if (!win.open) return
        if (win.page !== "tray") win.trayBack = win.page === "trayall" ? "trayall" : ""
        win.page = "tray"
        tray.openMenu(key)
        if (tray.menuKey === "") win.page = win.trayBack      // the item went in the meantime
    }
    // touches swallowed for `ms` (see inputLock): a page that appears late under a finger already on its way
    function shieldInput(ms) {
        if (win.inputLock) return
        win.inputLock = true; unlock.interval = ms; unlock.restart()
    }
    Connections {
        target: tray
        // A tap on a tray tile, answered: the app is up and the curtain goes (like an app launched from it) - but
        // not for an input method or a device (Category SystemServices / Hardware: fcitx's Activate switches the
        // input method in place; its icon on the tile shows the new one). Refused (an error: no Activate, as
        // ayatana's items): its menu if it has one, as Plasma's tray does. Not answered within 1 s (busy or hung):
        // said so, and no menu swapped in under the finger a second late. The item gone: nothing to say.
        function onActivateDone(key, ok, hasMenu, reason) {
            if (!win.open || key !== win.trayPending) return
            const slow = Date.now() - win.trayPendingAt > 300
            win.trayPending = ""
            const it = win.trayItem(key)
            if (ok) {
                if (it.category !== "SystemServices" && it.category !== "Hardware") backend.hide()
                return
            }
            if (reason === "gone") return
            if (reason === "error" && hasMenu) {
                // a refusal that took long: the menu appears where the finger may already be again
                if (slow) win.shieldInput(400)
                win.openTrayMenu(key)
                return
            }
            backend.notify(reason === "timeout"
                ? "「" + it.label + "」没有响应" + (hasMenu ? "，长按可打开它的菜单" : "")
                : "「" + it.label + "」不能从这里打开")
        }
        function onWantMenu(key) {
            if (key === win.trayPending) win.trayPending = ""
            win.openTrayMenu(key)
        }
        // the app behind the open menu went away: back where the menu was opened from
        function onMenuChanged() {
            if (win.page === "tray" && tray.menuKey === "") win.page = win.trayBack === "trayall" && tray.keys.length > 0 ? "trayall" : ""
        }
        // the list of every app, and none left
        function onKeysChanged() { if (win.page === "trayall" && tray.keys.length === 0) win.page = "" }
    }
    Timer { id: disarm; interval: 6000; onTriggered: win.powerArmed = "" }
    // a display mode switch (refresh rate) makes the touch screen spit phantom touches for a moment:
    // one tap on the rate tile once turned Wi-Fi and Bluetooth off and opened two terminals. Every
    // touch on the window is swallowed for 1.5 s after such a switch.
    // The shield lasts until the mode switch has actually finished (kscreen-doctor returned) plus 0.8 s,
    // capped at 4 s if it never reports back; a fixed 1.5 s from the tap was shorter than a slow switch.
    property bool inputLock: false
    Timer { id: unlock; interval: 4000; onTriggered: win.inputLock = false }
    function lockInput() { win.inputLock = true; unlock.interval = 4000; unlock.restart() }
    // the 「键盘」 tile's ForceShow on its way (busctl gives up after 3 s): the tile dims and takes no second tap, and
    // only its yes closes the curtain; forgotten when the curtain closes (as trayPending), so a late answer never
    // closes the next opening
    property bool kbdPending: false
    Connections {
        target: backend
        function onActionFinished(name, ok) {
            if (name === "hz" && win.inputLock) { unlock.interval = 800; unlock.restart() }
            if (name === "键盘") { const asked = win.kbdPending; win.kbdPending = false; if (ok && asked && win.open) backend.hide() }
        }
    }

    function tileBg(pressed) { return Qt.rgba(1, 1, 1, pressed ? 0.20 : 0.12) }

    // the clock on the curtain (the status bar's is under it): checked every second while open, redrawn per minute
    property var now: new Date()
    Timer {
        interval: 1000; repeat: true; running: win.open
        onTriggered: { const d = new Date(); if (d.getMinutes() !== win.now.getMinutes() || d.getHours() !== win.now.getHours()) win.now = d }
    }

    // ---------------- pulling: the curtain comes down from the top and follows the finger. The finger is on
    // y700-shellbar's status bar or strip (linux/dock; before it, y700-cc-pull), which sends its y over D-Bus
    // (backend.pulled) and which half it started on (backend.side); the finger drives the curtain's lower edge,
    // and on release a downward flick or a third of the way down opens.
    // Closing: push the header or the bottom handle up (the curtain follows), or tap the empty curtain.
    property bool pulling: false           // the finger came from the top strip
    property real pullY: 0                 // its y in screen coordinates
    property real pushY: 0                 // header dragged up: <= 0
    readonly property bool tracking: pulling || pushY < 0
    readonly property real progress: Math.max(0, Math.min(1, (curtain.y + curtain.height) / Math.max(1, curtain.height)))

    // the curtain's y is set, not bound: the finger sets it while tracking, settle() animates it to the end
    // (240 ms ease-out from wherever it is, so a release continues from the finger without a jump)
    function settle() {
        settleAnim.stop()
        const to = win.open ? 0 : -curtain.height
        if (Math.abs(curtain.y - to) < 0.5) { curtain.y = to; if (!win.open) backend.hideDone(); return }
        settleAnim.from = curtain.y; settleAnim.to = to
        settleAnim.start()
    }
    NumberAnimation {
        id: settleAnim
        target: curtain; property: "y"
        duration: 240; easing.type: Easing.OutCubic
        onFinished: if (!win.open) backend.hideDone()
    }
    onPullYChanged: if (pulling) { settleAnim.stop(); curtain.y = Math.min(0, pullY - curtain.height) }
    onPushYChanged: if (pushY < 0) { settleAnim.stop(); curtain.y = pushY }

    // the curtain pushed up (header or bottom handle): 40 px or an upward flick closes, else it springs back
    function pushEnd(vy, swipedRight) {
        const up = win.pushY < -40 || (win.pushY < -12 && vy < -300)
        win.pushY = 0
        if (up || swipedRight) backend.hide(); else win.settle()
    }

    function pullEnd(vy) {
        const open = vy > 350 || (vy > -350 && win.pullY > curtain.height * 0.33)
        win.pulling = false
        if (open) { backend.haptic(); settle() } else if (win.open) backend.hide(); else settle()
    }

    Connections {
        target: backend
        function onPulled(phase, v) {
            if (phase === 0) { win.pulling = true }
            else if (phase === 1 && win.pulling) win.pullY = v
            else if (phase === 2 && win.pulling) win.pullEnd(v)
        }
    }

    // backstop: a pull given up before the curtain moved runs no animation, so nothing would unmap the
    // full-screen (invisible, input-eating) window; hideDone() does nothing while it is open
    Timer { interval: 400; running: !win.open && !win.tracking; onTriggered: backend.hideDone() }

    // is a point of the curtain on the half in use (a tap there is not "the empty curtain")
    function onPane(p) {
        const pane = win.notes ? notesPane : ctl
        const q = pane.mapFromItem(curtain, p.x, p.y)
        return q.x >= -12 && q.x <= pane.width + 12 && q.y >= -12 && q.y <= pane.height + 12
    }

    Item {
        id: curtain
        width: parent.width
        height: parent.height
        clip: true                        // the content (screen-fixed) shows only where the curtain is
        y: -10000                        // first frame: off screen whatever the height; then settle()/the finger
        Component.onCompleted: y = -height
        // a resize (rotation; or the compositor's first configure, see the Window's size): the lower edge stays
        // under the finger while pulling, else at the end it was at
        onHeightChanged: {
            if (win.pulling) y = Math.min(0, win.pullY - height)
            else if (!win.tracking && !settleAnim.running) y = win.open ? 0 : -height
        }
        // the blur goes with the curtain (straight edges: it runs off the screen on three sides)
        onYChanged: backend.setBlur(0, Math.round(y), Math.round(width), Math.round(height), 0)
        onWidthChanged: backend.setBlur(0, Math.round(y), Math.round(width), Math.round(height), 0)

        // the tint over the blur: dark enough for white text over any wallpaper or app
        Rectangle { anchors.fill: parent; color: Qt.rgba(10 / 255, 12 / 255, 16 / 255, 0.46) }
        // the lower edge while it comes down: a hairline, so it reads as a sheet over the screen
        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 1; color: Qt.rgba(1, 1, 1, 0.12)
            visible: win.progress < 0.999
        }

        // a tap on the empty curtain closes it (TapHandlers are not exclusive: a tap on a tile also reaches
        // this one, so the position check is what keeps those from closing the curtain)
        TapHandler { onTapped: (p) => { if (!win.onPane(p.position)) backend.hide() } }

        Item {
            id: content
            // the content stays put on the screen and the curtain's lower edge uncovers it (the curtain clips),
            // fading in and settling down the last 24 px as it comes (a sheet carrying the content down showed
            // only the bottom row of tiles at first, the wrong end)
            x: 0; y: -curtain.y
            width: parent.width; height: parent.height
            opacity: Math.max(0, Math.min(1, (win.progress - 0.1) / 0.6))
            transform: Translate { y: -24 * (1 - win.progress) }

            // ---------------- header: the time and date, the battery; push it up to close
            Item {
                id: header
                x: win.margin; y: 26
                width: parent.width - 2 * win.margin; height: 100
                DragHandler {
                    target: null
                    onActiveTranslationChanged: if (active) win.pushY = Math.min(0, activeTranslation.y)
                    onActiveChanged: if (!active) win.pushEnd(centroid.velocity.y, false)
                }
                Text {
                    id: clock
                    text: Qt.formatTime(win.now, "HH:mm")
                    color: "white"; font.pixelSize: 64; font.weight: Font.Light
                    font.features: { "tnum": 1 }
                }
                Text {
                    anchors { left: clock.left; leftMargin: 2; top: clock.bottom; topMargin: -2 }
                    text: win.now.toLocaleDateString(Qt.locale("zh_CN"), "M月d日 dddd")
                    color: Qt.rgba(1, 1, 1, 0.72); font.pixelSize: 17
                }
                // the battery pill opens the battery page (10-30, as on the phones): y700-battery (linux/power/battery)
                // starts it, the curtain closes as for 「系统网络设置」. The pill is 32 high: the handler reaches 12 px
                // past it. A drag that starts on it still pushes the curtain up: the header's DragHandler takes the
                // point over past its threshold, and a tap is a release within bounds only.
                Rectangle {
                    id: batPill
                    anchors { right: parent.right; verticalCenter: clock.verticalCenter }
                    height: 32; width: batRow.implicitWidth + 24; radius: 16
                    color: win.tileBg(batTap.pressed)
                    Behavior on color { ColorAnimation { duration: 150; easing.type: Easing.OutCubic } }
                    scale: batTap.pressed ? 0.96 : 1
                    Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                    TapHandler {
                        id: batTap; margin: 12; gesturePolicy: TapHandler.ReleaseWithinBounds
                        onTapped: { backend.haptic(); backend.launch("/usr/local/bin/y700-battery"); backend.hide() }
                    }
                    Row {
                        id: batRow; anchors.centerIn: parent; spacing: 6
                        Item {
                            width: 20; height: 11; anchors.verticalCenter: parent.verticalCenter
                            Rectangle { anchors.fill: parent; radius: 3; color: "transparent"; border.width: 1.5; border.color: Qt.rgba(1, 1, 1, 0.75) }
                            Rectangle {
                                x: 1.5; y: 1.5; height: 8; radius: 1
                                width: 17 * Math.max(0, Math.min(1, (st.battery || 0) / 100))
                                color: (st.battery || 0) <= 15 ? win.danger : "#34c759"
                            }
                        }
                        Text { anchors.verticalCenter: parent.verticalCenter; text: (st.charging ? "⚡" : "") + (st.battery === undefined || st.battery < 0 ? "–" : st.battery) + "%"; color: "white"; font.pixelSize: 15; font.weight: Font.DemiBold }
                        // it leads somewhere
                        Text { anchors.verticalCenter: parent.verticalCenter; text: "›"; color: Qt.rgba(1, 1, 1, 0.55); font.pixelSize: 17; font.weight: Font.DemiBold }
                    }
                }
            }

            // ---------------- left half: the notification centre
            NotesPane {
                id: notesPane
                visible: win.notes
                x: win.margin; y: header.y + header.height + 36
                width: Math.min(560, parent.width - 2 * win.margin)
                height: parent.height - y - 48
                onInvoked: backend.hide()
            }

            // ---------------- right half: the controls, two columns laid out for the right thumb (10-22; the
            // owner: 「亮度跟音量的调节应该放在右边吧？我手一下能碰得到」). Landscape, a hand on each side, the right
            // thumb rests near (1600, 500) and reaches about 5 cm = 420 px to the left and up or down; x 590-1010
            // is the band neither thumb reaches (the sliders used to sit there, in the left column).
            //   thumb column (colB, x 1204-1544): Wi-Fi | Bluetooth (the first row everyone expects), rotation lock
            //     | auto brightness, the brightness and volume pills at the resting height (centres y 420 / 494),
            //     the performance profile with refresh rate | HUD under it (the game cluster), last the four actions
            //     that close the curtain, 60 high two across: recording | screenshot, show desktop | task cards
            //     (11-01); the player under the grid only while something plays.
            //   far column (colA, x 840-1180): bypass | torch | keyboard (three across, the columns of the tray tiles
            //     under them), Tailscale, 「后台应用」 (the apps' tray items, only while there are some), blank, and on
            //     the bottom line power + Android: 9 cm from the thumb, the distance is the first confirmation (the
            //     cards are the second).
            // Rows 14 apart; tiles 100 high (163 wide two across, 104 three across), every single-line control 60 high
            // with 44 px chips, radius 18 (the pills keep their capsule). Both columns start at y 162 and end on the
            // same line (860), player or not.
            Item {
                id: ctl
                visible: !win.notes
                anchors { right: parent.right; rightMargin: win.margin }
                y: header.y + header.height + 36
                width: 2 * win.colW + 24
                height: parent.height - y - 48
                // the thumb grid's height, remembered while it is up: the far column ends on its bottom line, and
                // must not move while a device list replaces the grid
                property real gridH: 698
                readonly property int rowGap: 14
                // a tile's width three across a column: the far column's first row and the tray tiles under it share it
                readonly property real third: (win.colW - 2 * rowGap) / 3
                // what the tray section's heading and tiles may take: the far column's blank (between the toggles
                // and the power row) less what the taller confirm card grows by, so either card still opens under
                // the tiles and the bottom line stays put. While shown the section is the column's filler (the
                // spacer goes, and its second gap with it): gridH 698: 698 - 174 - 2 x 14 - 250 = 246 = the heading
                // (19), 8, two whole rows (182) and 37 spare. More apps than that: the last place opens the list of all (traySec).
                readonly property real trayRoom: gridH - colATop.implicitHeight - 2 * rowGap
                                                 - Math.max(60, powerCard.implicitHeight, androidCard.implicitHeight)

                // far column: the rare toggles on top, power + Android on the bottom line, blank between
                ColumnLayout {
                    id: colA
                    anchors { left: parent.left; top: parent.top }
                    width: win.colW
                    height: ctl.gridH
                    spacing: ctl.rowGap

                    GridLayout {
                        id: colATop
                        Layout.fillWidth: true
                        columns: 3; columnSpacing: ctl.rowGap; rowSpacing: ctl.rowGap
                        Tile {
                            Layout.fillWidth: true; Layout.preferredWidth: ctl.third
                            icon: "bypass"; title: "旁路供电"
                            active: !!st.bypass
                            onTapped: { backend.setLocal("bypass", !st.bypass); backend.act("bypass", "tb323fu-ctl bypass " + (st.bypass ? "on" : "off")) }
                        }
                        Tile {
                            Layout.fillWidth: true; Layout.preferredWidth: ctl.third
                            icon: "torch"; title: "手电筒"
                            active: !!st.torch
                            onTapped: { backend.setLocal("torch", !st.torch); backend.act("torch", "tb323fu-ctl torch " + (st.torch ? "on" : "off")) }
                        }
                        // 「键盘」 (10-30): the on-screen keyboard up by hand for Wine / Proton games, whose X11 input
                        // (XIM: the whole window is the input field) never tells fcitx5 a field was tapped, so it cannot
                        // come up by itself there. ForceShow: forced, it stays until its own close key (the gate's hides
                        // do not take it down). An action, not a toggle (never accent); the curtain goes once the
                        // keyboard said yes (win.kbdPending), a refusal or no answer within 3 s stays on screen as the
                        // toast 「键盘失败：…」 (the action's name is the toast's label: backend.cpp has none for it).
                        // fyi.fortime.Fcitx5Osk is whichever keyboard is in charge (y700-osk, or fcitx5-osk after
                        // `y700-osk-ctl off`), started by D-Bus activation if it is not running
                        Tile {
                            Layout.fillWidth: true; Layout.preferredWidth: ctl.third
                            icon: "keyboard"; title: "键盘"
                            busy: win.kbdPending
                            onTapped: {
                                win.kbdPending = true
                                backend.act("键盘", "busctl --user --timeout=3 call fyi.fortime.Fcitx5Osk /fyi/fortime/Fcitx5Osk/Controller fyi.fortime.Fcitx5Osk.Controller1 ForceShow")
                            }
                        }
                        // Tailscale: a wide tile (status is the useful part). Running -> down; Stopped -> up;
                        // NeedsLogin -> start a login and open the URL in the browser (the curtain closes for it)
                        WideTile {
                            Layout.fillWidth: true; Layout.columnSpan: 3
                            icon: "tailscale"; title: "Tailscale"
                            readonly property string s: st.ts || ""
                            active: s === "Running"
                            status: s === "Running" ? (st.tsIp ? st.tsIp + (st.tsName ? "  ·  " + st.tsName : "") : "已连接")
                                  : s === "Stopped" ? "已关闭" : s === "NeedsLogin" ? "未登录，点击在浏览器登录"
                                  : s !== "" ? s : st.tsInstalled === false ? "未安装"
                                  : st.tsInstalled ? "没回应（tailscaled 没起来？）" : "…"      // nothing queried yet
                            onTapped: {
                                if (s === "Running") { backend.setLocal("ts", "Stopped"); backend.act("ts", "tailscale down") }
                                else if (s === "Stopped") { backend.setLocal("ts", "Running"); backend.act("ts", "tailscale up --timeout=20s") }
                                else if (s === "NeedsLogin" || s === "NoState") {
                                    // `tailscale login` blocks until the browser flow finishes; the backend opens
                                    // the URL the moment it is printed and keeps the login process alive
                                    backend.hide()
                                    backend.tsLogin()
                                }
                            }
                        }
                    }

                    // 后台应用: the apps' tray items (StatusNotifierItems, src/tray.h; the Plasma tray went with the
                    // panel in phase 3), three to a row like the mockup (ctl.third = (340 - 2 x 14) / 3 = 104, the
                    // columns of the first row above). Tap = open the app,
                    // long press = its menu (a page of the thumb column). Only while some app has one. It fills the
                    // blank in place of the spacer below, the tiles at its top: as many whole rows as ctl.trayRoom
                    // holds (two on the tablet), so a confirm card grows up into the rest and never reaches them; while
                    // a card is up the section fades out all the same and takes no taps (the card is the only question
                    // then). More apps than places: the last place is 「全部 N 个」, the list of all of them in the
                    // thumb column (a third row scrolling inside a two-row box showed a sliver of it, and on the
                    // tablet's touch a drag there was as often a tap).
                    Item {
                        id: traySec
                        visible: tray.keys.length > 0
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        enabled: !win.powerOpen && !win.confirmAndroid
                        opacity: enabled ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                        readonly property int rows: Math.max(1, Math.floor((ctl.trayRoom - trayHead.height - 8 + ctl.rowGap) / (84 + ctl.rowGap)))
                        readonly property int places: rows * 3
                        readonly property bool over: tray.keys.length > places
                        readonly property real tileW: ctl.third
                        Text {
                            id: trayHead
                            text: "后台应用"
                            color: Qt.rgba(1, 1, 1, 0.6); font.pixelSize: 13
                        }
                        Grid {
                            id: trayGrid
                            anchors { left: parent.left; top: trayHead.bottom; topMargin: 8 }
                            columns: 3; columnSpacing: ctl.rowGap; rowSpacing: ctl.rowGap
                            // made per key (tray.keys changes only when an app comes, goes or turns Passive): a tile
                            // outlives its icon's changes, so a press on it is never cut by a new one under the finger
                            Repeater {
                                model: traySec.over ? tray.keys.slice(0, traySec.places - 1) : tray.keys
                                TrayTile {
                                    required property string modelData
                                    readonly property var d: win.trayItem(modelData)
                                    width: traySec.tileW; height: 84
                                    label: d.label; icon: d.icon; attention: d.attention
                                    busy: win.trayPending === modelData
                                    onTapped: (c) => win.trayActivate(modelData, c)
                                    onLongPressed: win.openTrayMenu(modelData)
                                }
                            }
                            TrayTile {
                                visible: traySec.over
                                width: traySec.tileW; height: 84
                                label: "全部 " + tray.keys.length + " 个"
                                glyph: "+" + (tray.keys.length - traySec.places + 1)
                                onTapped: win.page = "trayall"
                                onLongPressed: win.page = "trayall"
                            }
                        }
                    }

                    // the blank the confirm cards grow up into (the power row's bottom line stays put); the tray
                    // section is the blank while it is shown
                    Item { visible: tray.keys.length === 0; Layout.fillWidth: true; Layout.fillHeight: true }

                    // power menu + switch to Android (each confirms in place)
                    Item {
                        Layout.fillWidth: true
                        implicitHeight: win.confirmAndroid ? androidCard.implicitHeight : win.powerOpen ? powerCard.implicitHeight : 60
                        Behavior on implicitHeight { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                        clip: true

                        RowLayout {
                            anchors { left: parent.left; right: parent.right; top: parent.top }
                            height: 60; spacing: 12
                            visible: !win.confirmAndroid && !win.powerOpen
                            Rectangle {
                                Layout.preferredWidth: 60; Layout.preferredHeight: 60; radius: 18
                                color: Qt.rgba(1, 1, 1, powerTap.pressed ? 0.14 : 0.07)
                                border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.10)
                                scale: powerTap.pressed ? 0.95 : 1
                                Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                                Image { anchors.centerIn: parent; source: "icons/power.svg"; sourceSize: Qt.size(26, 26) }
                                TapHandler { id: powerTap; gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: { backend.haptic(); win.powerOpen = true } }
                            }
                            Rectangle {
                                Layout.fillWidth: true; Layout.preferredHeight: 60; radius: 18
                                color: Qt.rgba(1, 1, 1, androidTap.pressed ? 0.14 : 0.07)
                                border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.10)
                                scale: androidTap.pressed ? 0.97 : 1
                                Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                                Row {
                                    anchors.centerIn: parent; spacing: 10
                                    Image { source: "icons/android.svg"; sourceSize: Qt.size(24, 24); anchors.verticalCenter: parent.verticalCenter }
                                    Text { text: "切换到 Android"; color: "white"; font.pixelSize: 16; font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
                                }
                                TapHandler { id: androidTap; gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: { backend.haptic(); win.confirmAndroid = true } }
                            }
                        }

                        // power card: screen off / lock (a full row each) / reboot | power off (those two ask twice). No suspend:
                        // suspend.target is masked (README 续航「永不休眠」), the button could only fail (10-31 audit C3)
                        Rectangle {
                            id: powerCard
                            anchors { left: parent.left; right: parent.right; top: parent.top }
                            visible: win.powerOpen
                            implicitHeight: powerCol.implicitHeight + 32
                            radius: 18
                            color: Qt.rgba(1, 1, 1, 0.14)
                            border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.14)
                            ColumnLayout {
                                id: powerCol
                                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 16 }
                                spacing: 10
                                RowLayout {
                                    Layout.fillWidth: true
                                    Text { text: "电源"; color: "white"; font.pixelSize: 17; font.weight: Font.Bold }
                                    Item { Layout.fillWidth: true }
                                    Rectangle {
                                        Layout.preferredWidth: 64; Layout.preferredHeight: 32; radius: 12
                                        color: win.tileBg(pcTap.pressed)
                                        Text { anchors.centerIn: parent; text: "取消"; color: "white"; font.pixelSize: 13; font.weight: Font.DemiBold }
                                        TapHandler { id: pcTap; gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: { backend.haptic(); win.powerOpen = false; win.powerArmed = "" } }
                                    }
                                }
                                GridLayout {
                                    Layout.fillWidth: true
                                    columns: 2; columnSpacing: 10; rowSpacing: 10
                                    Repeater {
                                        model: [
                                            // powerdevil's own "Turn Off Screen" action (the same one the power key runs);
                                            // the short sleep lets the curtain go up first
                                            { k: "screenoff", t: "息屏", i: "screenoff", wide: true, confirm: false,
                                              cmd: "sleep 0.4; busctl --user call org.kde.kglobalaccel /component/org_kde_powerdevil org.kde.kglobalaccel.Component invokeShortcut s 'Turn Off Screen'" },
                                            { k: "lock", t: "锁屏", i: "lock", wide: true, cmd: "loginctl lock-session", confirm: false },
                                            { k: "reboot", t: "重启", i: "restart", cmd: "systemctl reboot", confirm: true },
                                            { k: "poweroff", t: "关机", i: "poweroff", cmd: "systemctl poweroff", confirm: true }
                                        ]
                                        Rectangle {
                                            required property var modelData
                                            readonly property bool armed: win.powerArmed === modelData.k
                                            Layout.fillWidth: true; Layout.preferredHeight: 52; radius: 14
                                            Layout.columnSpan: modelData.wide ? 2 : 1
                                            color: armed ? win.danger : win.tileBg(pTap.pressed)
                                            Behavior on color { ColorAnimation { duration: 150 } }
                                            scale: pTap.pressed ? 0.96 : 1
                                            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                                            Row {
                                                anchors.centerIn: parent; spacing: 8
                                                Image { source: "icons/" + parent.parent.modelData.i + ".svg"; sourceSize: Qt.size(22, 22); anchors.verticalCenter: parent.verticalCenter }
                                                Text { text: parent.parent.armed ? "再点一次" : parent.parent.modelData.t; color: "white"; font.pixelSize: 15; font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
                                            }
                                            TapHandler {
                                                id: pTap; gesturePolicy: TapHandler.ReleaseWithinBounds
                                                onTapped: {
                                                    backend.haptic()
                                                    const d = parent.modelData
                                                    if (d.confirm && win.powerArmed !== d.k) { win.powerArmed = d.k; disarm.restart(); return }
                                                    win.powerArmed = ""; win.powerOpen = false
                                                    backend.act("power", d.cmd)
                                                    backend.hide()
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Android card
                        Rectangle {
                            id: androidCard
                            anchors { left: parent.left; right: parent.right; top: parent.top }
                            visible: win.confirmAndroid
                            implicitHeight: cardCol.implicitHeight + 34
                            radius: 18
                            color: Qt.rgba(1, 1, 1, 0.14)
                            border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.14)
                            ColumnLayout {
                                id: cardCol
                                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 18 }
                                spacing: 12
                                Text { text: "重启到 Android？"; color: "white"; font.pixelSize: 17; font.weight: Font.Bold }
                                Text {
                                    Layout.fillWidth: true; wrapMode: Text.Wrap
                                    text: "没保存的东西会丢。切换大约 40 秒，回来点桌面上的“切换到 Linux”。"
                                    color: Qt.rgba(1, 1, 1, 0.75); font.pixelSize: 13; lineHeight: 1.3
                                }
                                RowLayout {
                                    Layout.fillWidth: true; spacing: 10
                                    Rectangle {
                                        Layout.fillWidth: true; Layout.preferredHeight: 44; radius: 14
                                        color: Qt.rgba(1, 1, 1, cancelTap.pressed ? 0.22 : 0.14)
                                        scale: cancelTap.pressed ? 0.97 : 1
                                        Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                                        Text { anchors.centerIn: parent; text: "取消"; color: "white"; font.pixelSize: 15; font.weight: Font.DemiBold }
                                        TapHandler { id: cancelTap; gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: { backend.haptic(); win.confirmAndroid = false } }
                                    }
                                    Rectangle {
                                        Layout.fillWidth: true; Layout.preferredHeight: 44; radius: 14
                                        color: win.danger
                                        opacity: backend.busy === "android" ? 0.5 : 1
                                        scale: goTap.pressed ? 0.97 : 1
                                        Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                                        Text { anchors.centerIn: parent; text: backend.busy === "android" ? "正在切换…" : "重启切换"; color: "white"; font.pixelSize: 15; font.weight: Font.DemiBold }
                                        // one submission only: the handler is off while the switch runs (the backend drops repeats too)
                                        TapHandler { id: goTap; enabled: backend.busy !== "android"; gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: { backend.haptic(); backend.act("android", "tb323fu-ctl android --yes") } }
                                    }
                                }
                            }
                        }
                    }
                }

                // thumb column: the grid (tiles, sliders, performance), the player under it; or a device list
                // (Wi-Fi / Bluetooth: long press on their tiles; the grid and the player give way to it)
                ColumnLayout {
                    id: colB
                    anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
                    width: win.colW
                    spacing: ctl.rowGap

                    RowLayout {
                        visible: win.page !== ""
                        Layout.fillWidth: true
                        spacing: 10
                        Rectangle {
                            Layout.preferredWidth: 36; Layout.preferredHeight: 36; radius: 18
                            color: win.tileBg(backTap.pressed)
                            scale: backTap.pressed ? 0.96 : 1
                            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                            Image { anchors.centerIn: parent; source: "icons/back.svg"; sourceSize: Qt.size(22, 22) }
                            // in a tray menu's submenu: one level up; at its top: where it was opened from (the grid, or the
                            // list of every app); on the other lists: the grid again
                            TapHandler {
                                id: backTap; gesturePolicy: TapHandler.ReleaseWithinBounds
                                onTapped: {
                                    backend.haptic()
                                    if (win.page === "tray" && tray.menuBack()) return
                                    win.page = win.page === "tray" ? win.trayBack : ""
                                }
                            }
                        }
                        Text {
                            Layout.fillWidth: true; elide: Text.ElideRight
                            text: win.page === "wifi" ? "Wi‑Fi" : win.page === "bt" ? "蓝牙" : win.page === "trayall" ? "后台应用" : tray.menuTitle
                            color: "white"; font.pixelSize: 20; font.weight: Font.Bold
                        }
                    }

                    // the thumb grid: 2 x 100 tiles / pills / performance / 2 x 100 tiles / 2 x 2 actions of 60 (698 high)
                    GridLayout {
                        id: gridB
                        Layout.fillWidth: true
                        visible: win.page === ""
                        columns: 2; columnSpacing: ctl.rowGap; rowSpacing: ctl.rowGap
                        onImplicitHeightChanged: if (visible && implicitHeight > 0) ctl.gridH = implicitHeight
                        Component.onCompleted: if (implicitHeight > 0) ctl.gridH = implicitHeight

                        // row 1, y 162: the connections
                        Tile {
                            Layout.fillWidth: true
                            icon: "wifi"; title: st.wifi && st.ssid ? st.ssid : "Wi‑Fi"
                            active: !!st.wifi
                            onTapped: { backend.setLocal("wifi", !st.wifi); backend.act("wifi", "nmcli radio wifi " + (st.wifi ? "on" : "off")) }
                            onLongPressed: win.page = "wifi"
                        }
                        Tile {
                            Layout.fillWidth: true
                            icon: "bluetooth"; title: "蓝牙"
                            active: !!st.bt
                            // timeout: bluetoothctl waits for ever when bluetoothd is gone (backend.cpp STATUS_CMD)
                            onTapped: { backend.setLocal("bt", !st.bt); backend.act("bt", "timeout 10 bluetoothctl power " + (st.bt ? "on" : "off")) }
                            onLongPressed: win.page = "bt"
                        }
                        // row 2, y 276: the display pair (auto brightness right over the brightness pill)
                        Tile {
                            Layout.fillWidth: true
                            icon: st.rotLocked ? "rotate-locked" : "rotate"; title: "旋转锁定"
                            active: !!st.rotLocked
                            onTapped: { backend.setLocal("rotLocked", !st.rotLocked); backend.act("rot", "/usr/local/bin/y700-autorotate " + (st.rotLocked ? "never" : "tablet")) }
                        }
                        Tile {
                            Layout.fillWidth: true
                            // replaced the terminal tile (owner, 2026-10-15). On: the service follows the light
                            // and learns from the brightness pill; off: the brightness stays where it is
                            icon: "brightness-auto"; title: "自动亮度"
                            active: !!st.autobright
                            onTapped: { backend.setLocal("autobright", !st.autobright); backend.act("autobright", "/usr/local/bin/y700-autobright-ctl " + (st.autobright ? "on" : "off")) }
                        }
                        // rows 3-4, y 390 / 464: brightness and volume, at the thumb's resting height
                        Pill {
                            Layout.fillWidth: true; Layout.columnSpan: 2; Layout.preferredHeight: 60
                            icon: "brightness"
                            value: backend.brightness
                            onMoved: (v) => backend.setBrightness(v)
                        }
                        Pill {
                            Layout.fillWidth: true; Layout.columnSpan: 2; Layout.preferredHeight: 60
                            icon: st.muted ? "volume-muted" : "volume"
                            value: st.volume || 0
                            onMoved: (v) => backend.setVolume(v)
                        }
                        // row 5, y 538: performance profile: power-saver | balanced | performance
                        Rectangle {
                            Layout.fillWidth: true; Layout.columnSpan: 2; Layout.preferredHeight: 60; radius: 18
                            color: Qt.rgba(1, 1, 1, 0.12)
                            readonly property var names: ["power-saver", "balanced", "performance"]
                            readonly property var labels: ["省电", "均衡", "性能"]
                            readonly property int cur: names.indexOf(st.profile || "balanced")
                            Row {
                                anchors { fill: parent; margins: 4 }
                                spacing: 4
                                Repeater {
                                    model: 3
                                    Rectangle {
                                        required property int index
                                        width: (parent.width - 8) / 3; height: parent.height; radius: 14
                                        color: index === parent.parent.cur ? win.accent : "transparent"
                                        Behavior on color { ColorAnimation { duration: 150 } }
                                        scale: segTap.pressed ? 0.96 : 1
                                        Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                                        Text {
                                            anchors.centerIn: parent
                                            text: parent.parent.parent.labels[parent.index]
                                            color: parent.index === parent.parent.parent.cur ? "white" : Qt.rgba(1, 1, 1, 0.7)
                                            font.pixelSize: 16; font.weight: Font.DemiBold
                                        }
                                        TapHandler {
                                            id: segTap; gesturePolicy: TapHandler.ReleaseWithinBounds
                                            onTapped: { backend.haptic(); backend.setLocal("profile", parent.parent.parent.names[parent.index]); backend.act("profile", "tb323fu-ctl gpu profile " + parent.parent.parent.names[parent.index]) }
                                        }
                                    }
                                }
                            }
                        }
                        // row 6, y 612: the rest of the game cluster
                        Tile {
                            Layout.fillWidth: true
                            // the chip shows the configured rate; a tap cycles 60 -> 90 -> 120 -> 164 (panel max)
                            glyph: st.hz ? String(st.hz) : "–"; title: "刷新率"
                            onTapped: {
                                const steps = [60, 90, 120, 164]
                                // a rate outside the cycle (y700-refresh-auto lowered the panel to 30 Hz for a video)
                                // counts as 120, the usual base: the next tap goes to 164, not to 60 (2026-10-16)
                                const i = steps.indexOf(Number(st.hz)), cur = i < 0 ? steps.indexOf(120) : i
                                const next = steps[(cur + 1) % steps.length]
                                backend.setLocal("hz", next)
                                // the helper's refresh policy can only float BELOW the KDE mode's rate, so the
                                // tile switches the KDE mode itself (kscreen-doctor) and leaves the helper on auto
                                // (idle drops to 60/30 still apply); MaxHz in the status follows the mode
                                // `&&`: a failed mode switch must not be hidden by the helper call succeeding after it
                                backend.act("hz", "kscreen-doctor output.DSI-1.mode.1904x3040@" + next + " >/dev/null && tb323fu-ctl refresh auto")
                                win.lockInput()
                            }
                        }
                        Tile {
                            Layout.fillWidth: true
                            // three steps: off -> full (everything) -> mini (FPS + watts) -> off
                            icon: "speedometer"
                            title: st.hud === "full" ? "浮层·全部" : st.hud === "mini" ? "浮层·帧数功耗" : "性能浮层"
                            active: st.hud === "full" || st.hud === "mini"
                            // the target step is passed explicitly (not "next"): three fast taps must end in the
                            // state of the last tap, and a queued "next" after a running "next" would not
                            onTapped: {
                                const next = st.hud === "full" ? "mini" : st.hud === "mini" ? "off" : "full"
                                backend.setLocal("hud", next)
                                backend.act("hud", "$HOME/.local/bin/y700-hud-toggle " + next)
                            }
                        }
                        // rows 7-8, y 726 / 800: four actions that close the curtain, 60 high (11-01: show desktop and
                        // the task cards came; a third row of 100 would not fit over the player, so capture shrank)
                        WideTile {
                            Layout.fillWidth: true; toggle: false
                            icon: "record"; title: st.recording ? "录屏中" : "录屏"
                            active: !!st.recording
                            // while recording the tile stops it (backend.stopRecording = a click on Spectacle's tray
                            // icon; there is no tray since the dock). st.recording follows Spectacle's own signals
                            onTapped: { if (st.recording) backend.stopRecording(); else backend.startRecording(); backend.hide() }
                        }
                        WideTile {
                            Layout.fillWidth: true; toggle: false
                            icon: "screenshot"; title: "截图"
                            // Spectacle's activate() while it is recording finishes the recording instead of
                            // taking a screenshot (SpectacleCore.cpp, 6.6.6): the tile is off during a recording
                            opacity: st.recording ? 0.4 : 1
                            onTapped: {
                                if (st.recording) { backend.notify("录屏中：截图会结束录制，先在 Spectacle 里停止录屏"); return }
                                backend.hide(); backend.launch("sleep 0.6; spectacle -b -f")
                            }
                        }
                        // every window minimized (kwin-script: y700-edge's "y700-show-desktop", 11-01), so the shellbar
                        // shows its desktop as after the home flick: dock up, see-through status bar. One way: the dock or
                        // the cards bring an app back. No wait: the windows may go while the curtain still covers them
                        WideTile {
                            Layout.fillWidth: true; toggle: false
                            icon: "desktop"; title: "显示桌面"
                            onTapped: { backend.hide(); backend.launch("busctl --user call org.kde.kglobalaccel /component/kwin org.kde.kglobalaccel.Component invokeShortcut s y700-show-desktop") }
                        }
                        // the task cards (linux/gesture/taskswitcher), the same shortcut as the G9 home key's double tap.
                        // 0.3 s: the curtain's 240 ms slide-out first (the cards take the docks over the app as they open)
                        WideTile {
                            Layout.fillWidth: true; toggle: false
                            icon: "tasks"; title: "多任务"
                            onTapped: { backend.hide(); backend.launch("sleep 0.3; busctl --user call org.kde.kglobalaccel /component/kwin org.kde.kglobalaccel.Component invokeShortcut s 'y700-taskswitcher'") }
                        }
                    }

                    // now playing (MPRIS), only while some player has something: under the grid (y 874), pushing
                    // nothing above it (the layout skips it while hidden)
                    Rectangle {
                        visible: win.page === "" && !!media.service
                        Layout.fillWidth: true; Layout.preferredHeight: 60; radius: 18
                        color: Qt.rgba(1, 1, 1, 0.12)
                        RowLayout {
                            anchors { fill: parent; leftMargin: 16; rightMargin: 8 }
                            spacing: 8
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 1
                                Text { Layout.fillWidth: true; elide: Text.ElideRight; text: media.title || media.identity || ""; color: "white"; font.pixelSize: 15; font.weight: Font.DemiBold }
                                Text { Layout.fillWidth: true; elide: Text.ElideRight; text: media.artist ? media.artist + " · " + media.identity : (media.identity || ""); color: Qt.rgba(1, 1, 1, 0.6); font.pixelSize: 12 }
                            }
                            Repeater {
                                model: [{ i: "prev", m: "Previous" }, { i: media.status === "Playing" ? "pause" : "play", m: "PlayPause" }, { i: "next", m: "Next" }]
                                Rectangle {
                                    required property var modelData
                                    Layout.preferredWidth: 44; Layout.preferredHeight: 44; radius: 22
                                    color: modelData.m === "PlayPause" ? win.accent : win.tileBg(mTap.pressed)
                                    scale: mTap.pressed ? 0.94 : 1
                                    Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                                    Image { anchors.centerIn: parent; source: "icons/" + parent.modelData.i + ".svg"; sourceSize: Qt.size(22, 22) }
                                    TapHandler { id: mTap; gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: { backend.haptic(); backend.mediaControl(parent.modelData.m) } }
                                }
                            }
                        }
                    }

                    Flickable {
                        id: listFlick
                        visible: win.page === "wifi" || win.page === "bt"
                        Layout.fillWidth: true; Layout.fillHeight: true
                        contentHeight: listCol.implicitHeight
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        flickableDirection: Flickable.VerticalFlick
                        // ======== device lists (Wi-Fi / Bluetooth)
                        ColumnLayout {
                            id: listCol
                            width: listFlick.width
                            spacing: 8
                            readonly property var rows: win.page === "wifi" ? backend.wifiList : win.page === "bt" ? backend.btList : []
                            Text {
                                visible: listCol.rows.length === 0
                                Layout.fillWidth: true; Layout.topMargin: 20
                                horizontalAlignment: Text.AlignHCenter
                                text: win.page === "wifi" ? (backend.scanning ? "正在扫描…" : st.wifi ? "没有找到网络" : "Wi‑Fi 已关闭") : "没有已配对的设备"
                                color: Qt.rgba(1, 1, 1, 0.6); font.pixelSize: 14
                            }
                            Repeater {
                                model: listCol.rows
                                Rectangle {
                                    required property var modelData
                                    Layout.fillWidth: true; Layout.preferredHeight: 56; radius: 14
                                    readonly property bool on: win.page === "wifi" ? !!modelData.inUse : !!modelData.connected
                                    color: on ? win.accent : win.tileBg(rowTap.pressed)
                                    Behavior on color { ColorAnimation { duration: 150 } }
                                    RowLayout {
                                        anchors { fill: parent; leftMargin: 16; rightMargin: 14 }
                                        spacing: 8
                                        Text {
                                            Layout.fillWidth: true; elide: Text.ElideRight
                                            text: win.page === "wifi" ? parent.parent.modelData.ssid : parent.parent.modelData.name
                                            color: "white"; font.pixelSize: 15; font.weight: Font.DemiBold
                                        }
                                        Text {
                                            text: win.page === "wifi"
                                                  ? (parent.parent.modelData.signal + "%" + (parent.parent.modelData.secured ? " 🔒" : "") + (parent.parent.modelData.known ? "" : " · 新"))
                                                  : (parent.parent.on ? "已连接" : "")
                                            color: Qt.rgba(1, 1, 1, 0.75); font.pixelSize: 12
                                        }
                                    }
                                    TapHandler {
                                        id: rowTap; gesturePolicy: TapHandler.ReleaseWithinBounds
                                        onTapped: {
                                            backend.haptic()
                                            if (win.page === "wifi") { if (!parent.modelData.inUse) backend.wifiConnect(parent.modelData.ssid, parent.modelData.uuid || "", parent.modelData.secured) }
                                            else backend.btToggle(parent.modelData.mac, parent.modelData.connected)
                                        }
                                    }
                                }
                            }
                            Rectangle {
                                Layout.fillWidth: true; Layout.preferredHeight: 48; Layout.topMargin: 6; radius: 14
                                color: win.tileBg(moreTap.pressed)
                                border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.10)
                                Text { anchors.centerIn: parent; text: win.page === "wifi" ? "系统网络设置（连新网络、输密码）" : "系统蓝牙设置（配对新设备）"; color: "white"; font.pixelSize: 14; font.weight: Font.DemiBold }
                                TapHandler { id: moreTap; gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: { backend.haptic(); backend.launch(win.page === "wifi" ? "systemsettings kcm_networkmanagement" : "systemsettings kcm_bluetooth"); backend.hide() } }
                            }
                        }
                    }

                    // ======== every tray item (the 「全部 N 个」 tile: more apps than the far column's two rows hold),
                    // a row each in the watcher's order: tap = open the app, long press = its menu, as on the tiles
                    Flickable {
                        id: allFlick
                        visible: win.page === "trayall"
                        Layout.fillWidth: true; Layout.fillHeight: true
                        contentHeight: allCol.implicitHeight
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        flickableDirection: Flickable.VerticalFlick
                        ColumnLayout {
                            id: allCol
                            width: allFlick.width
                            spacing: 8
                            Repeater {
                                // per key, as the tiles (tray.keys): a row outlives its icon's changes
                                model: win.page === "trayall" ? tray.keys : []
                                Rectangle {
                                    id: arow
                                    required property string modelData
                                    readonly property var d: win.trayItem(modelData)
                                    readonly property bool busy: win.trayPending === modelData
                                    Layout.fillWidth: true; Layout.preferredHeight: 56
                                    radius: 14
                                    color: win.tileBg(allTap.pressed)
                                    Behavior on color { ColorAnimation { duration: 150 } }
                                    scale: allTap.pressed ? 0.97 : 1
                                    Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                                    opacity: busy ? 0.5 : 1
                                    Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                                    RowLayout {
                                        anchors { fill: parent; leftMargin: 16; rightMargin: 14 }
                                        spacing: 10
                                        Item {
                                            Layout.preferredWidth: 22; Layout.preferredHeight: 22
                                            Image {
                                                id: aimg
                                                anchors.fill: parent
                                                source: arow.d.icon
                                                sourceSize: Qt.size(22, 22)
                                                fillMode: Image.PreserveAspectFit
                                                asynchronous: false; cache: false       // as TrayTile's
                                                visible: aimg.status === Image.Ready
                                            }
                                            Rectangle {
                                                anchors.fill: parent; radius: 11
                                                visible: aimg.status === Image.Null || aimg.status === Image.Error
                                                color: Qt.rgba(1, 1, 1, 0.14)
                                                Text {
                                                    anchors.centerIn: parent
                                                    text: arow.d.label === "" ? "?" : String.fromCodePoint(arow.d.label.codePointAt(0)).toUpperCase()
                                                    color: "white"; font.pixelSize: 12; font.weight: Font.DemiBold
                                                }
                                            }
                                        }
                                        Text {
                                            Layout.fillWidth: true; elide: Text.ElideRight
                                            text: arow.d.label
                                            color: "white"; font.pixelSize: 15; font.weight: Font.DemiBold
                                        }
                                        Rectangle {
                                            visible: arow.d.attention
                                            Layout.preferredWidth: 8; Layout.preferredHeight: 8; radius: 4
                                            color: win.accent
                                        }
                                    }
                                    TapHandler {
                                        id: allTap
                                        enabled: !arow.busy
                                        gesturePolicy: TapHandler.ReleaseWithinBounds
                                        onTapped: { backend.haptic(); win.trayActivate(arow.modelData, arow.mapToItem(null, arow.width / 2, arow.height / 2)) }
                                        onLongPressed: { backend.haptic(); win.openTrayMenu(arow.modelData) }
                                    }
                                }
                            }
                        }
                    }

                    // ======== a tray item's own menu (com.canonical.dbusmenu, src/tray.h), one level at a time like
                    // the device lists: a submenu opens in place (back goes up a level), checked radio / checkmark
                    // entries are filled like a connected device and every toggle shows its mark (a ring, a box), an
                    // entry runs and the curtain goes
                    Flickable {
                        id: menuFlick
                        visible: win.page === "tray"
                        Layout.fillWidth: true; Layout.fillHeight: true
                        contentHeight: menuCol.implicitHeight
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        flickableDirection: Flickable.VerticalFlick
                        // 「正在读取…」 only once a read has taken 200 ms: they take a few, no flash on every open
                        Timer { id: menuSlow; interval: 200; running: tray.menuLoading }
                        // another menu or level starts at its top
                        readonly property string level: tray.menuKey + "\n" + tray.menuDepth + "\n" + tray.menuTitle
                        onLevelChanged: contentY = 0
                        ColumnLayout {
                            id: menuCol
                            width: menuFlick.width
                            spacing: 8
                            // a level where some entry has an icon keeps the icon's column on every row, so the
                            // labels start on one line (fcitx: icons on its input methods only)
                            readonly property bool icons: tray.menu.some(r => !r.separator && r.icon !== "")
                            Text {
                                visible: tray.menu.length === 0 && !menuSlow.running
                                Layout.fillWidth: true; Layout.topMargin: 20
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.Wrap
                                // not answering is not "no menu": the owner should not give up on an app that is busy
                                text: tray.menuLoading ? "正在读取…" : tray.menuFailed ? "「" + tray.menuTitle + "」没有响应" : "这个应用没有菜单"
                                color: Qt.rgba(1, 1, 1, 0.6); font.pixelSize: 14
                            }
                            Repeater {
                                model: tray.menu
                                Item {
                                    id: mrow
                                    required property var modelData
                                    readonly property bool on: modelData.toggle !== "" && modelData.checked
                                    // its submenu is being read (AboutToShow, GetLayout): dimmed, no second tap
                                    readonly property bool pending: tray.menuPending === modelData.id
                                    Layout.fillWidth: true
                                    // a separator: a hairline with a little room (4 + the column's 8 on each side)
                                    Layout.preferredHeight: modelData.separator ? 1 : 56
                                    Layout.topMargin: modelData.separator ? 4 : 0
                                    Layout.bottomMargin: modelData.separator ? 4 : 0
                                    Rectangle {
                                        visible: mrow.modelData.separator
                                        anchors.fill: parent
                                        color: Qt.rgba(1, 1, 1, 0.10)
                                    }
                                    Rectangle {
                                        visible: !mrow.modelData.separator
                                        anchors.fill: parent; radius: 14
                                        color: mrow.on ? win.accent : win.tileBg(menuTap.pressed)
                                        Behavior on color { ColorAnimation { duration: 150 } }
                                        scale: menuTap.pressed ? 0.97 : 1
                                        Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                                        opacity: mrow.pending ? 0.5 : 1
                                        Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                                        RowLayout {
                                            anchors { fill: parent; leftMargin: 16; rightMargin: 14 }
                                            spacing: 10
                                            Item {
                                                visible: menuCol.icons
                                                Layout.preferredWidth: 22; Layout.preferredHeight: 22
                                                Image {
                                                    anchors.fill: parent
                                                    visible: mrow.modelData.icon !== ""
                                                    source: mrow.modelData.icon
                                                    sourceSize: Qt.size(22, 22)
                                                    // rendered when the level was read (src/tray.cpp): in place at once,
                                                    // no row first drawn without it
                                                    asynchronous: false
                                                    opacity: mrow.modelData.enabled ? 1 : 0.45
                                                }
                                            }
                                            Text {
                                                Layout.fillWidth: true; elide: Text.ElideRight
                                                text: mrow.modelData.label
                                                color: "white"; font.pixelSize: 15; font.weight: Font.DemiBold
                                                opacity: mrow.modelData.enabled ? 1 : 0.45
                                            }
                                            // a toggle's mark, on or off (the fill alone said only which one is on:
                                            // an unchecked checkmark entry looked like a plain action)
                                            Item {
                                                visible: mrow.modelData.toggle !== ""
                                                Layout.preferredWidth: 18; Layout.preferredHeight: 18
                                                opacity: mrow.modelData.enabled ? 1 : 0.45
                                                Rectangle {     // radio: a ring, a dot in it when chosen
                                                    visible: mrow.modelData.toggle === "radio"
                                                    anchors.fill: parent; radius: 9
                                                    color: "transparent"
                                                    border.width: 2; border.color: Qt.rgba(1, 1, 1, mrow.on ? 1 : 0.45)
                                                    Rectangle {
                                                        visible: mrow.on
                                                        anchors.centerIn: parent
                                                        width: 8; height: 8; radius: 4
                                                        color: "white"
                                                    }
                                                }
                                                Rectangle {     // checkmark: a box, ticked when on
                                                    visible: mrow.modelData.toggle === "checkmark"
                                                    anchors.fill: parent; radius: 5
                                                    color: "transparent"
                                                    border.width: 2; border.color: Qt.rgba(1, 1, 1, mrow.on ? 1 : 0.45)
                                                    Image {
                                                        visible: mrow.on
                                                        anchors.centerIn: parent
                                                        source: "icons/check.svg"; sourceSize: Qt.size(14, 14)
                                                    }
                                                }
                                            }
                                            Image {
                                                visible: mrow.modelData.submenu
                                                source: "icons/back.svg"; sourceSize: Qt.size(18, 18)
                                                rotation: 180; opacity: 0.6
                                            }
                                        }
                                        // a disabled entry (an app's status lines) is information: no press
                                        TapHandler {
                                            id: menuTap
                                            enabled: mrow.modelData.enabled && !mrow.pending
                                            gesturePolicy: TapHandler.ReleaseWithinBounds
                                            onTapped: {
                                                backend.haptic()
                                                if (mrow.modelData.submenu) { tray.menuEnter(mrow.modelData.id); return }
                                                tray.menuClick(mrow.modelData.id)
                                                backend.hide()
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Item { visible: win.page === ""; Layout.fillHeight: true }
                }
            }
        }

        // the handle along the bottom edge: drag it up and the curtain goes with the finger
        Item {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 40
            Rectangle {
                anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 12 }
                width: 48; height: 5; radius: 2.5
                color: Qt.rgba(1, 1, 1, handleDrag.active ? 0.6 : 0.32)
                Behavior on color { ColorAnimation { duration: 150 } }
            }
            DragHandler {
                id: handleDrag
                target: null
                xAxis.enabled: false
                onActiveTranslationChanged: if (active) win.pushY = Math.min(0, activeTranslation.y)
                onActiveChanged: if (!active) win.pushEnd(centroid.velocity.y, false)
            }
        }
    }

    // toast: why an action failed (backend.toast, 3.5 s). Low on the curtain, in the middle.
    Rectangle {
        id: toast
        readonly property bool shown: backend.toast !== ""
        anchors { horizontalCenter: curtain.horizontalCenter; bottom: curtain.bottom; bottomMargin: 56 }
        width: Math.min(440, curtain.width - 2 * win.margin); height: toastText.implicitHeight + 24; radius: 14
        color: Qt.rgba(0.11, 0.12, 0.15, 0.96)
        border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.10)
        opacity: shown ? 1 : 0; scale: shown ? 1 : 0.95
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Text {
            id: toastText
            anchors { left: parent.left; right: parent.right; margins: 16; verticalCenter: parent.verticalCenter }
            text: backend.toast; wrapMode: Text.Wrap
            color: "white"; font.pixelSize: 14; font.weight: Font.DemiBold
        }
    }

    // input shield (see inputLock)
    MouseArea {
        anchors.fill: parent
        z: 1000
        enabled: win.inputLock
        visible: enabled
        onPressed: (m) => { m.accepted = true }
    }
}
