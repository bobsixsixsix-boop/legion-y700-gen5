// The keyboard's panels (cover the band + key area). Layout values follow the design mockup:
// insets 12.5, bottom rows one key row high (66.67) sitting 16 px off the edge.
import QtQuick
import "."
import "Layouts.js" as L

Item {
    id: pp
    required property var kb
    readonly property real u: kb.u
    readonly property bool fl: kb.mode === "float"
    readonly property real inset: 12.5 * u
    readonly property real gap: 12.5 * u
    readonly property real rowH: 66.67 * u
    readonly property real bottomPad: (fl ? 30 : 16) * u        // float: stay clear of the drag bar
    readonly property real topY: kb.bandH

    // voice panel hooks (called by Keyboard.qml)
    function voiceText(t) { if (loader.item && loader.item.recognised) loader.item.recognised(t) }
    function voiceFailed(m) { if (loader.item && loader.item.failed) loader.item.failed(m) }

    Loader {
        id: loader
        anchors.fill: parent
        active: kb.panel !== ""
        opacity: status === Loader.Ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        sourceComponent: ({ toolbox: toolbox, feedback: feedback, clip: clip, edit: edit, emoji: emoji,
                            sym: sym, cands: cands, layout: layoutPicker, voice: voice })[kb.panel] || null
    }

    function symPage() { return symCats[kb.symCat][1] }       // the debug hook picks symbols by index
    function fire(name) { kb.click(name) }
    function side(it) { return kb.sideAt(it) }
    function icon(name, col, size) { return Theme.ic(name, col, 2) }

    // ======================= 工具箱 =======================
    Component {
        id: toolbox
        Item {
            id: tbRoot
            readonly property var tiles: [
                { id: "clip", ic: "clipboard", t: "剪贴板" }, { id: "edit", ic: "cursor_edit", t: "文本编辑" },
                { id: "phrase", ic: "phrase", t: "常用语" }, { id: "adjust", ic: "height_adjust", t: "键盘调节" },
                { id: "feedback", ic: "haptic", t: "按键反馈" }, { id: "float", ic: "float", t: "悬浮键盘", tog: true },
                { id: "split", ic: "split", t: "分离键盘", tog: true }, { id: "night", ic: "theme", t: "夜间模式", tog: true },
                { id: "flick", ic: "arrow_up", t: "上滑输入", tog: true }, { id: "bubble", ic: "bubble", t: "按键气泡", tog: true },
                { id: "swipe", ic: "space_swipe", t: "滑动光标", tog: true }, { id: "glow", ic: "glow", t: "点触光感", tog: true },
                { id: "trad", ic: "trad", t: "繁体输入" }, { id: "settings", ic: "settings", t: "更多设置" } ]
            function isOn(id) {
                switch (id) {
                case "float": return kb.mode === "float"
                case "split": return kb.mode === "split"
                case "night": return Theme.skin.endsWith("dark")
                case "flick": return kb.prefs.flick
                case "bubble": return kb.prefs.bubble
                case "swipe": return kb.prefs.cursorSwipe
                case "glow": return kb.prefs.tapGlow
                }
                return false
            }
            function act(id) {
                switch (id) {
                case "clip": case "edit": case "feedback": kb.openPanel(id); break
                case "adjust": kb.startAdjust(); break
                // toggles never close the toolbox (the owner's rule for the control centre)
                case "float": kb.setMode(kb.mode === "float" ? "dock" : "float"); break
                case "split": kb.setMode(kb.mode === "split" ? "dock" : "split"); break
                case "night": {
                    var s = Theme.skin.endsWith("dark") ? Theme.skin.replace("dark", "light") : Theme.skin.replace("light", "dark")
                    kb.setSkin(s); kb.toast(s.endsWith("dark") ? "已开启夜间模式" : "已关闭夜间模式", "", 1200); break
                }
                case "flick": kb.prefs.flick = !kb.prefs.flick; kb.toast(kb.prefs.flick ? "上滑输入已开启" : "上滑输入已关闭", "", 1200); break
                case "bubble": kb.prefs.bubble = !kb.prefs.bubble; kb.toast(kb.prefs.bubble ? "按键气泡已开启" : "按键气泡已关闭", "", 1200); break
                case "swipe": kb.prefs.cursorSwipe = !kb.prefs.cursorSwipe; kb.toast(kb.prefs.cursorSwipe ? "滑动光标已开启" : "滑动光标已关闭", "", 1200); break
                case "glow": kb.prefs.tapGlow = !kb.prefs.tapGlow; kb.toast(kb.prefs.tapGlow ? "点触光感已开启" : "点触光感已关闭", "", 1200); break
                case "phrase": kb.toast("常用语还没有做", "", 1400); break
                case "trad": kb.toast("繁体输入还没有做", "", 1400); break
                case "settings": osk.openSettings(); break
                }
            }
            GridView {
                id: grid
                x: pp.inset; y: pp.topY + 5.33 * pp.u
                width: parent.width - 2 * pp.inset + pp.gap; height: parent.height - y - pp.bottomPad
                readonly property int cols: pp.fl ? 4 : 7
                cellWidth: width / cols
                cellHeight: pp.fl ? 96 * pp.u + pp.gap : (height + pp.gap) / 2
                interactive: pp.fl
                clip: true
                model: parent.tiles
                delegate: Item {
                    required property var modelData
                    width: grid.cellWidth; height: grid.cellHeight
                    PBtn {
                        id: tb
                        u: pp.u
                        anchors.fill: parent; anchors.rightMargin: pp.gap; anchors.bottomMargin: pp.gap
                        radius: 18 * pp.u
                        on: modelData.tog === true && tbRoot.isOn(modelData.id)
                        Accessible.name: modelData.t
                        onTapped: tbRoot.act(modelData.id)
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: (parent.height - height - 10 * pp.u - 20 * pp.u) / 2
                            width: 48 * pp.u; height: width; radius: width / 2
                            color: tb.on ? Qt.rgba(1, 1, 1, .22) : Theme.chip
                            Image { anchors.centerIn: parent; width: 26 * pp.u; height: width
                                    sourceSize: Qt.size(Math.round(width * Screen.devicePixelRatio), Math.round(width * Screen.devicePixelRatio))
                                    source: Theme.ic(modelData.ic, tb.on ? "#ffffff" : Theme.icon, 2) }
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: (parent.height + 48 * pp.u + 10 * pp.u - 20 * pp.u) / 2
                            text: modelData.t; color: tb.on ? "#ffffff" : Theme.ink
                            font.family: Theme.font; font.weight: Font.DemiBold; font.pixelSize: (pp.fl ? 13 : 16) * pp.u
                        }
                    }
                }
            }
        }
    }

    // ======================= 按键反馈 =======================
    Component {
        id: feedback
        Item {
            PanelTitle { u: pp.u; width: parent.width; height: pp.topY; title: "按键反馈"; onBack: kb.closePanel() }
            Flickable {
                x: pp.inset; y: pp.topY + 18 * pp.u
                width: parent.width - 2 * pp.inset; height: parent.height - y - pp.bottomPad
                contentHeight: cols.height; interactive: pp.fl; clip: true
                Grid {
                    id: cols
                    width: parent.width
                    columns: pp.fl ? 1 : 2
                    columnSpacing: 28 * pp.u; rowSpacing: 12 * pp.u
                    Column {
                        width: pp.fl ? cols.width : (cols.width - 28 * pp.u) * 1.25 / 2.25
                        spacing: 10 * pp.u
                        Text { text: "音量"; color: Theme.ink3; font.family: Theme.font; font.weight: Font.DemiBold; font.pixelSize: 15 * pp.u }
                        Pill { u: pp.u; width: parent.width; max: 10; value: kb.prefs.vol; icon: kb.prefs.vol === 0 ? "volume_off" : "sound"
                               label: String(kb.prefs.vol)
                               onMoved: (v) => { kb.prefs.vol = v; kb.pushPrefs(); kb.click("char") } }
                        Item { width: 1; height: 8 * pp.u }
                        Text { text: "振动"; color: Theme.ink3; font.family: Theme.font; font.weight: Font.DemiBold; font.pixelSize: 15 * pp.u }
                        Pill { u: pp.u; width: parent.width; max: 5; value: kb.prefs.vib; icon: "haptic"
                               label: kb.prefs.vib === 0 ? "关" : kb.prefs.vib + " 档"
                               onMoved: (v) => { kb.prefs.vib = v; kb.haptic("B", "key") } }
                        Text { width: parent.width; wrapMode: Text.Wrap; color: Theme.ink3; font.family: Theme.font; font.pixelSize: 14 * pp.u; lineHeight: 1.3
                               text: "音量 0–10 档线性，和 vivo 一致；振动 0 = 关，1–5 档对应 8–20 ms 的马达脉冲，默认 3 档。系统静音时，按键音不生效。" }
                    }
                    Column {
                        width: pp.fl ? cols.width : (cols.width - 28 * pp.u) / 2.25
                        spacing: 10 * pp.u
                        Text { text: "音效"; color: Theme.ink3; font.family: Theme.font; font.weight: Font.DemiBold; font.pixelSize: 15 * pp.u }
                        Rectangle {
                            width: parent.width; height: 58 * pp.u; radius: 16 * pp.u; color: Theme.card
                            Row {
                                x: 5 * pp.u; y: 5 * pp.u; spacing: 6 * pp.u
                                Repeater {
                                    model: [["std", "标准"], ["soft", "柔和"], ["mech", "机械"]]
                                    delegate: PBtn {
                                        required property var modelData
                                        u: pp.u; quiet: true
                                        width: (parent.parent.width - 10 * pp.u - 12 * pp.u) / 3; height: 48 * pp.u
                                        on: kb.prefs.sound === modelData[0]
                                        onTapped: { kb.prefs.sound = modelData[0]; kb.pushPrefs(); kb.click("char") }
                                        Text { anchors.centerIn: parent; text: modelData[1]; color: parent.on ? "#ffffff" : Theme.ink
                                               font.family: Theme.font; font.weight: Font.DemiBold; font.pixelSize: 16 * pp.u }
                                    }
                                }
                            }
                        }
                        Item { width: 1; height: 8 * pp.u }
                        Text { text: "试一试"; color: Theme.ink3; font.family: Theme.font; font.weight: Font.DemiBold; font.pixelSize: 15 * pp.u }
                        Row {
                            spacing: pp.gap
                            Repeater {
                                model: [["char", "A"], ["space", "空格"], ["del", "删除"], ["enter", "回车"]]
                                delegate: Key {
                                    required property var modelData
                                    u: pp.u
                                    width: (parent.parent.width - 3 * pp.gap) / 4; height: pp.rowH
                                    def: ({ t: "try", fn: modelData[0] !== "char" })
                                    accent: false
                                    Text { anchors.centerIn: parent; text: modelData[1]; color: Theme.ink; font.family: Theme.font; font.weight: Font.Medium; font.pixelSize: 21 * pp.u }
                                    TapHandler {
                                        gesturePolicy: TapHandler.WithinBounds
                                        onPressedChanged: { parent.down = pressed; if (pressed) { kb.click(modelData[0]); kb.haptic(pp.side(parent), "key") } }
                                    }
                                }
                            }
                        }
                        Text { width: parent.width; wrapMode: Text.Wrap; color: Theme.ink3; font.family: Theme.font; font.pixelSize: 14 * pp.u; lineHeight: 1.3
                               text: "左半边的键震左马达，右半边震右马达；进入连删、长按字母弹出大小写和符号时，两侧一起重振。" }
                    }
                }
            }
        }
    }

    // ======================= 剪贴板 =======================
    Component {
        id: clip
        Item {
            id: cp
            readonly property int cat: kb.clipCat
            property bool armed: false
            readonly property var cats: ["最近", "网址", "电话", "邮箱", "地址"]
            readonly property var tests: [null, /https?:\/\/|www\./i, /^[+\d][\d\s\-()]{6,}$/, /^[^\s@]+@[^\s@]+\.[^\s@]+$/, /(省|市|区|县|路|街|号|楼|室)/]
            readonly property var items: {
                var pinned = kb.prefs.pinned || [], hist = osk.clipboard, out = [], seen = {}
                function add(t, pin) { if (!t || seen[t]) return; seen[t] = true; if (cat === 0 || tests[cat].test(t.trim())) out.push({ t: t, pin: pin }) }
                for (var i = 0; i < pinned.length; i++) add(pinned[i], true)
                for (i = 0; i < hist.length; i++) add(hist[i], false)
                return out
            }
            Component.onCompleted: osk.refreshClipboard()
            Timer { id: disarm; interval: 6000; onTriggered: cp.armed = false }
            PanelTitle {
                u: pp.u; width: parent.width; height: pp.topY; title: "剪贴板"; note: osk.clipboard.length + "/200"; onBack: kb.closePanel()
                PBtn {
                    u: pp.u; quiet: true; width: clr.implicitWidth + 20 * pp.u; height: 40 * pp.u
                    onTapped: {
                        // dangerous: needs a second tap within 6 s; pinned entries stay
                        if (!cp.armed) { cp.armed = true; disarm.restart(); return }
                        disarm.stop(); cp.armed = false; osk.clearClipboard()
                        kb.toast((kb.prefs.pinned || []).length ? "已清空，锁定的内容已保留" : "已清空", "", 1400)
                    }
                    Text { id: clr; anchors.centerIn: parent; text: cp.armed ? "再点一次" : "清空"; color: cp.armed ? Theme.danger : Theme.accInk
                           font.family: Theme.font; font.weight: cp.armed ? Font.DemiBold : Font.Normal; font.pixelSize: 16 * pp.u }
                }
            }
            Row {
                x: pp.inset; y: pp.topY + 12 * pp.u; spacing: 8 * pp.u
                Repeater {
                    model: cp.cats
                    delegate: PBtn {
                        required property string modelData
                        required property int index
                        u: pp.u; radius: height / 2
                        width: ct.implicitWidth + 32 * pp.u; height: 38 * pp.u
                        on: cp.cat === index
                        onTapped: kb.clipCat = index
                        Text { id: ct; anchors.centerIn: parent; text: modelData; color: parent.on ? "#ffffff" : Theme.ink; font.family: Theme.font; font.pixelSize: 15 * pp.u }
                    }
                }
            }
            GridView {
                id: cg
                x: pp.inset; y: pp.topY + 62 * pp.u
                width: parent.width - 2 * pp.inset + pp.gap; height: parent.height - y - pp.bottomPad
                cellWidth: width / (pp.fl ? 1 : 3); cellHeight: 92 * pp.u + pp.gap
                clip: true
                model: cp.items
                delegate: Item {
                    required property var modelData
                    width: cg.cellWidth; height: cg.cellHeight
                    PBtn {
                        id: card
                        u: pp.u
                        anchors.fill: parent; anchors.rightMargin: pp.gap; anchors.bottomMargin: pp.gap; radius: 18 * pp.u
                        onTapped: { kb.typeText(modelData.t); kb.toast("已粘贴", "", 1000) }
                        Text { x: 16 * pp.u; y: 14 * pp.u; width: parent.width - 64 * pp.u; height: parent.height - 28 * pp.u
                               text: modelData.t; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                               color: Theme.ink; font.family: Theme.font; font.pixelSize: 17 * pp.u; lineHeight: 1.2 }
                    }
                    // the lock pin sits on the card as a sibling, so a tap on it never also pastes
                    PBtn {
                            u: pp.u; quiet: true
                            anchors.right: card.right; anchors.top: card.top; anchors.margins: 6 * pp.u
                            width: 40 * pp.u; height: 40 * pp.u; radius: 20 * pp.u
                            onTapped: {
                                var p = (kb.prefs.pinned || []).slice(), i = p.indexOf(modelData.t)
                                if (i >= 0) p.splice(i, 1); else p.unshift(modelData.t)
                                kb.prefs.pinned = p
                                kb.toast(i >= 0 ? "已解锁" : "已锁定，清空剪贴板时会保留", "", 1200)
                            }
                            Image { anchors.centerIn: parent; width: 20 * pp.u; height: width; sourceSize: Qt.size(48, 48)
                                    source: Theme.ic("pin", modelData.pin ? Theme.accInk : Theme.ink2, 2) }
                    }
                }
                Text { visible: cg.count === 0; text: "这一类还没有内容"; color: Theme.ink3; font.family: Theme.font; font.pixelSize: 14 * pp.u; y: 8 * pp.u }
            }
        }
    }

    // ======================= 文本编辑 =======================
    Component {
        id: edit
        Item {
            id: ed
            property bool selecting: false
            function k(name) { osk.keyCombo(name, ed.selecting ? ["Shift"] : []) }
            PanelTitle { u: pp.u; width: parent.width; height: pp.topY; title: "文本编辑"; onBack: kb.closePanel() }
            Item {
                id: area
                x: pp.inset; y: pp.topY + 5.33 * pp.u
                width: parent.width - 2 * pp.inset; height: parent.height - y - pp.bottomPad
                readonly property real cw: (width - 4 * pp.gap) / 5
                // touchpad: slide = move the caret, long-press then slide = select
                Rectangle {
                    id: pad
                    width: pp.fl ? area.width : 3 * area.cw + 2 * pp.gap
                    height: pp.fl ? (area.height - pp.rowH - 2 * pp.gap) / 2 : area.height - pp.rowH - pp.gap
                    radius: 18 * pp.u; color: Theme.card
                    Text { x: 16 * pp.u; y: 12 * pp.u; text: "触控板"; color: Theme.ink3; font.family: Theme.font; font.pixelSize: 14 * pp.u }
                    Text { anchors.centerIn: parent; horizontalAlignment: Text.AlignHCenter; text: "划动手指移动光标\n长按拖动选取文本"
                           color: Theme.ink3; font.family: Theme.font; font.pixelSize: 16 * pp.u; lineHeight: 1.4 }
                    Rectangle { id: dot; width: 44 * pp.u; height: width; radius: width / 2; color: Theme.accSoft; visible: padArea.pressed
                                x: padArea.mouseX - width / 2; y: padArea.mouseY - height / 2 }
                    MouseArea {
                        id: padArea
                        anchors.fill: parent
                        property real lx: 0; property real ly: 0; property bool sel: false
                        onPressed: (e) => { lx = e.x; ly = e.y; sel = false; hold.restart() }
                        onPositionChanged: (e) => {
                            var step = 18 * pp.u
                            if (Math.abs(e.x - lx) > 6 * pp.u || Math.abs(e.y - ly) > 6 * pp.u) hold.stop()
                            while (Math.abs(e.x - lx) >= step) { var r = e.x > lx; osk.keyCombo(r ? "Right" : "Left", (sel || ed.selecting) ? ["Shift"] : []); lx += r ? step : -step; kb.haptic("B", "light") }
                            while (Math.abs(e.y - ly) >= step * 2) { var d = e.y > ly; osk.keyCombo(d ? "Down" : "Up", (sel || ed.selecting) ? ["Shift"] : []); ly += d ? step * 2 : -step * 2; kb.haptic("B", "light") }
                        }
                        onReleased: hold.stop()
                        Timer { id: hold; interval: 450; onTriggered: { padArea.sel = true; kb.haptic("B", "medium"); kb.toast("拖动选取文本", "", 900) } }
                    }
                }
                Grid {
                    id: cross
                    x: pp.fl ? 0 : pad.width + pp.gap; y: pp.fl ? pad.height + pp.gap : 0
                    width: pp.fl ? area.width : 2 * area.cw + pp.gap; height: pad.height
                    columns: 3; spacing: 10 * pp.u
                    readonly property real bw: (width - 20 * pp.u) / 3
                    readonly property real bh: (height - 20 * pp.u) / 3
                    Repeater {
                        model: [["home", "行首", "Home"], ["arrow_up", "上移", "Up"], ["end", "行尾", "End"],
                                ["arrow_left", "左移", "Left"], ["", "选择", ""], ["arrow_right", "右移", "Right"],
                                ["-", "", ""], ["arrow_down", "下移", "Down"], ["-", "", ""]]
                        delegate: Item {
                            required property var modelData
                            width: cross.bw; height: cross.bh
                            PBtn {
                                visible: modelData[0] !== "-"
                                u: pp.u; anchors.fill: parent
                                on: modelData[0] === "" && ed.selecting
                                Accessible.name: modelData[1]
                                onTapped: modelData[0] === "" ? (ed.selecting = !ed.selecting) : ed.k(modelData[2])
                                Image { visible: modelData[0] !== ""; anchors.centerIn: parent; width: 26 * pp.u; height: width
                                        sourceSize: Qt.size(Math.round(width * Screen.devicePixelRatio), Math.round(width * Screen.devicePixelRatio))
                                        source: modelData[0] !== "" && modelData[0] !== "-" ? Theme.ic(modelData[0], Theme.icon, 2) : "" }
                                Text { visible: modelData[0] === ""; anchors.centerIn: parent; text: "选择"; color: parent.on ? "#ffffff" : Theme.ink
                                       font.family: Theme.font; font.weight: Font.DemiBold; font.pixelSize: 16 * pp.u }
                            }
                        }
                    }
                }
                Row {
                    y: area.height - pp.rowH; spacing: pp.gap
                    Repeater {
                        model: [["select_all", "全选", "a", ["Control"]], ["cut", "剪切", "x", ["Control"]], ["copy", "复制", "c", ["Control"]],
                                ["paste", "粘贴", "v", ["Control"]], ["backspace", "删除", "BackSpace", []]]
                        delegate: PBtn {
                            required property var modelData
                            u: pp.u; width: (area.width - 4 * pp.gap) / 5; height: pp.rowH
                            onTapped: { osk.keyCombo(modelData[2], modelData[3]); if (modelData[2] === "c" || modelData[2] === "x") kb.toast(modelData[2] === "c" ? "已复制" : "已剪切", "", 900) }
                            Row {
                                anchors.centerIn: parent; spacing: 8 * pp.u
                                Image { anchors.verticalCenter: parent.verticalCenter; width: 24 * pp.u; height: width
                                        sourceSize: Qt.size(Math.round(width * Screen.devicePixelRatio), Math.round(width * Screen.devicePixelRatio))
                                        source: Theme.ic(modelData[0], Theme.icon, 2) }
                                Text { visible: !pp.fl; anchors.verticalCenter: parent.verticalCenter; text: modelData[1]; color: Theme.ink
                                       font.family: Theme.font; font.weight: Font.Medium; font.pixelSize: 17 * pp.u }
                            }
                        }
                    }
                }
            }
        }
    }

    // ======================= Emoji =======================
    readonly property var emo: [
        ["最近", "😂🙏👍😊❤️🤣😭😘🥰👌🎉🔥😅🤔😁👏💪🙌😎🥳😴🤗😋🌹☕🍜🚗✅"],
        ["表情与人物", "😀😃😄😁😆😅🤣😂🙂🙃😉😊😇🥰😍🤩😘😗☺️😚😙🥲😋😛😜🤪😝🤑🤗🤭🤫🤔🤐🤨😐😑😶😏😒🙄😬😮‍💨🤥😌😔😪🤤😴😷🤒🤕🤢🤮🥵🥶🥴😵🤯🤠🥳🥸😎🤓🧐😕😟🙁😮😯😲😳🥺😦😧😨😰😥😢😭😱😖😣😞😓😩😫🥱😤😡😠🤬👋🤚🖐️✋🖖👌🤌🤏✌️🤞🤟🤘🤙👈👉👆👇☝️👍👎✊👊🤛🤜👏🙌👐🤲🤝🙏💪"],
        ["动物与自然", "🐶🐱🐭🐹🐰🦊🐻🐼🐨🐯🦁🐮🐷🐸🐵🐔🐧🐦🐤🦆🦅🦉🐺🐗🐴🦄🐝🐛🦋🐌🐞🐢🐍🐙🦑🦀🐬🐳🐋🦈🌸🌹🌻🌲🍀🍁🌙⭐☀️🌈❄️"],
        ["食物与饮料", "🍏🍎🍐🍊🍋🍌🍉🍇🍓🫐🍈🍒🍑🥭🍍🥥🥝🍅🥑🍆🥔🥕🌽🌶️🥒🥬🥦🍄🥜🌰🍞🥐🥖🥨🧀🥚🍳🥞🧇🥓🥩🍗🍖🍔🍟🍕🌭🥪🌮🌯🍜🍲🍛🍣🍱🥟🍤🍙🍚🍘🍥🥮🍢🍡🍧🍨🍦🥧🧁🍰🎂🍮🍭🍬🍫🍿🍩🍪☕🍵🧋🥤🍺🍻🥂🍷"],
        ["活动", "⚽🏀🏈⚾🎾🏐🏉🎱🏓🏸🥅🏒🏑🏏⛳🏹🎣🥊🥋⛸️🎿🏂🏋️🤸⛹️🤺🏇🧘🏄🏊🚴🎮🕹️🎲🧩🎯🎳🎸🎹🎺🎻🥁🎤🎧🎬🎨"],
        ["物体", "⌚📱💻⌨️🖥️🖨️🖱️💾💿📷📸📹🎥📞☎️📺📻🎙️⏰⏳🔋🔌💡🔦🕯️💰💳💎🔧🔨⚙️🧰🔑🗝️🚪🛋️🛏️🧸🎁🎈🎀📦📮📝📚📖🔖🔗📎✂️📌📍"] ]
    Component {
        id: emoji
        Item {
            id: em
            readonly property int cat: kb.emoCat
            PanelTitle { u: pp.u; width: parent.width; height: pp.topY; title: "Emoji"; onBack: kb.closePanel() }
            GridView {
                id: eg
                x: pp.inset; y: pp.topY + 6 * pp.u
                width: parent.width - 2 * pp.inset; height: parent.height - y - pp.rowH - pp.bottomPad - 16 * pp.u
                cellWidth: width / (pp.fl ? 8 : 15); cellHeight: 60 * pp.u
                clip: true
                model: osk.graphemes(pp.emo[em.cat][1])
                delegate: Rectangle {
                    required property string modelData
                    width: eg.cellWidth; height: eg.cellHeight; radius: 12 * pp.u
                    color: et.pressed ? Theme.card : "transparent"
                    Text { anchors.centerIn: parent; text: modelData; font.family: "Noto Color Emoji"; font.pixelSize: 34 * pp.u }
                    TapHandler { id: et; gesturePolicy: TapHandler.ReleaseWithinBounds
                                 onPressedChanged: if (pressed) { kb.click("char"); kb.haptic(pp.side(parent), "key") }
                                 onTapped: kb.typeText(modelData) }
                }
            }
            CatBar {
                u: pp.u; x: pp.inset; width: parent.width - 2 * pp.inset; height: pp.rowH
                y: parent.height - pp.bottomPad - height
                names: pp.emo.map(function (e) { return e[0] }); sel: em.cat
                onPicked: (i) => kb.emoCat = i
                onBack: kb.closePanel()
                showDelete: true
                onDeleted: kb.doDelete()
            }
        }
    }

    // ======================= 符号 =======================
    readonly property var symCats: [
        ["中文", ["，", "。", "？", "！", "～", "、", "：", "#", "；", "％", "*", "——", "……", "&", "·", "$", "（", "）", "‘", "’", "“", "”", "［", "］", "『", "』", "〔", "〕", "{", "}", "【", "】", "¥", "￡", "♀", "‖", "〖", "〗", "《", "》", "「", "」", "｜", "〈", "〉"]],
        // the owner wants the physical keyboard's order: shifted number row, then the right-hand keys
        ["英文", "!@#$%^&*()-_=+[]{}\\|;:'\",.<>/?~`".split("")],     // 32: on 11 columns all three rows are in view
        ["网络", [".", ":", "/", "@", "–", "_", "http://", "https://", "www.", ".com", ".cn", ".net", ".org", "bbs.", "blog."]],
        ["数学", "+−×÷=≠≈±≤≥<>%‰√∞∑∏∫∠⊥∥∵∴°′″π∈∉⊆∪∩".split("")],
        ["序号", "①②③④⑤⑥⑦⑧⑨⑩⑴⑵⑶⑷⑸⑹⑺⑻⑼⑽ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩ㈠㈡㈢㈣㈤".split("")],
        ["箭头", "←↑→↓↖↗↘↙↔↕⇐⇒⇑⇓⇔⟵⟶➜➔↩↪⤴⤵".split("")],
        ["特殊", "★☆○●◎◇◆□■△▲※§№♪♫✓✗♀♂℃℉©®™¤〒々〆€…·–".split("")] ]
    Component {
        id: sym
        Item {
            id: sy
            readonly property int cat: kb.symCat
            readonly property bool lock: kb.symLock
            PanelTitle {
                u: pp.u; width: parent.width; height: pp.topY; title: "符号"
                note: sy.lock ? "已锁定，选完符号不返回" : "选一个符号后回到键盘"
                onBack: kb.closePanel()
            }
            readonly property real colW: (pp.fl ? 76 : 110) * pp.u
            GridView {
                id: sg
                x: pp.inset; y: pp.topY + 6 * pp.u
                width: parent.width - 2 * pp.inset - sy.colW - pp.gap + 6 * pp.u
                height: parent.height - y - pp.rowH - pp.bottomPad - 16 * pp.u
                cellWidth: width / (pp.fl ? 5 : sy.cat === 1 ? 11 : 10); cellHeight: (height + 6 * pp.u) / 3
                clip: true
                model: pp.symCats[sy.cat][1]
                delegate: Item {
                    required property string modelData
                    width: sg.cellWidth; height: sg.cellHeight
                    PBtn {
                        u: pp.u; sound: "char"; radius: 10 * pp.u
                        anchors.fill: parent; anchors.rightMargin: 6 * pp.u; anchors.bottomMargin: 6 * pp.u
                        onTapped: kb.pickSymbol(modelData)
                        Text { anchors.centerIn: parent; text: modelData; color: Theme.ink; font.family: Theme.font
                               font.pixelSize: (modelData.length > 2 ? 19 : 24) * pp.u }
                    }
                }
            }
            Column {
                x: parent.width - pp.inset - sy.colW; y: sg.y; width: sy.colW; height: sg.height
                spacing: 6 * pp.u
                Repeater {
                    model: [["del", "backspace"], ["space", ""], ["enter", "enter"]]
                    delegate: Key {
                        required property var modelData
                        u: pp.u; width: parent.width; height: (sg.height - 12 * pp.u) / 3
                        def: ({ t: modelData[0] === "space" ? "space" : modelData[0], fn: true, send: modelData[0] === "enter" })
                        TapHandler {
                            gesturePolicy: TapHandler.WithinBounds
                            onPressedChanged: { parent.down = pressed; if (pressed) { kb.click(modelData[0]); kb.haptic(pp.side(parent), "key") } }
                            onTapped: {
                                if (modelData[0] === "del") kb.doDelete()
                                else if (modelData[0] === "space") kb.typeText(" ")
                                else { kb.closePanel(); kb.doEnter(false) }
                            }
                        }
                    }
                }
            }
            CatBar {
                u: pp.u; x: pp.inset; width: parent.width - 2 * pp.inset; height: pp.rowH
                y: parent.height - pp.bottomPad - height
                names: pp.symCats.map(function (e) { return e[0] }); sel: sy.cat
                onPicked: (i) => kb.symCat = i
                onBack: kb.closePanel()
                // 锁定 next to 返回, where vivo has it: a labelled toggle, not a pin icon in the title
                toggleLabel: "锁定"; toggleOn: sy.lock
                onToggled: kb.setSymLock(!kb.symLock)
            }
        }
    }

    // ======================= 全部候选 =======================
    Component {
        id: cands
        Item {
            PanelTitle { u: pp.u; width: parent.width; height: pp.topY; title: osk.preedit; note: "全部候选"; onBack: kb.closePanel() }
            readonly property real colW: (pp.fl ? 80 : 118) * pp.u
            Rectangle {
                x: pp.inset; y: pp.topY + 6 * pp.u
                width: parent.width - 2 * pp.inset - parent.colW - pp.gap; height: parent.height - y - pp.bottomPad
                radius: 18 * pp.u; color: Theme.card; clip: true
                GridView {
                    id: fg
                    anchors.fill: parent
                    cellWidth: width / (pp.fl ? 3 : 6); cellHeight: 66 * pp.u
                    model: osk.candidates
                    delegate: Rectangle {
                        required property string modelData
                        required property int index
                        width: fg.cellWidth; height: fg.cellHeight
                        color: ft.pressed ? Theme.cardP : "transparent"
                        Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.sep }
                        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.sep }
                        Text { anchors.centerIn: parent; text: modelData; color: index === 0 ? Theme.accInk : Theme.ink
                               font.family: Theme.font; font.weight: index === 0 ? Font.Medium : Font.Normal; font.pixelSize: 22 * pp.u }
                        TapHandler { id: ft; gesturePolicy: TapHandler.ReleaseWithinBounds
                                     onPressedChanged: if (pressed) { kb.click("char"); kb.haptic(pp.side(parent), "key") }
                                     onTapped: osk.selectCandidate(index) }
                    }
                }
            }
            Column {
                x: parent.width - pp.inset - parent.colW; y: pp.topY + 6 * pp.u; width: parent.colW
                height: parent.height - y - pp.bottomPad
                spacing: 8 * pp.u
                Repeater {
                    model: [["close", "返回"], ["del", ""], ["reinput", "重输"]]
                    delegate: Key {
                        required property var modelData
                        u: pp.u; width: parent.width; height: (parent.height - 16 * pp.u) / 3
                        def: ({ t: modelData[0] === "del" ? "del" : "try", fn: true })
                        Text { visible: modelData[1] !== ""; anchors.centerIn: parent; text: modelData[1]; color: Theme.ink
                               font.family: Theme.font; font.weight: Font.Medium; font.pixelSize: 19 * pp.u }
                        TapHandler {
                            gesturePolicy: TapHandler.WithinBounds
                            onPressedChanged: { parent.down = pressed; if (pressed) { kb.click("char"); kb.haptic(pp.side(parent), "key") } }
                            onTapped: {
                                switch (modelData[0]) {
                                case "close": kb.closePanel(); break
                                case "del": kb.doDelete(); break
                                case "reinput": osk.key("Escape"); kb.closePanel(); break
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ======================= 键盘选择 =======================
    Component {
        id: layoutPicker
        Item {                      // a bare Flickable root would be stretched over the inset by the Loader
        Flickable {
            x: pp.inset; y: pp.topY + 18 * pp.u
            width: parent.width - 2 * pp.inset; height: parent.height - y - pp.bottomPad
            contentHeight: lc.height; interactive: pp.fl; clip: true
            Column {
                id: lc
                width: parent.width; spacing: 18 * pp.u
                Repeater {
                    model: [
                        { h: "键盘", items: [["zh", "keyboard", "拼音全键"], ["en", "globe", "英文全键"], ["ja", "translate", "日文罗马字"], ["num", "numpad", "数字键盘"], ["sym", "symbols", "符号"]] },
                        { h: "形态", items: [["dock", "dock", "标准"], ["split", "split", "分离"], ["float", "float", "悬浮"], ["adjust", "height_adjust", "键盘调节"]] } ]
                    delegate: Column {
                        required property var modelData
                        width: lc.width; spacing: 10 * pp.u
                        Text { text: modelData.h; color: Theme.ink3; font.family: Theme.font; font.weight: Font.DemiBold; font.pixelSize: 15 * pp.u }
                        Grid {
                            columns: pp.fl ? 2 : modelData.items.length; spacing: pp.gap
                            Repeater {
                                model: modelData.items
                                delegate: PBtn {
                                    id: lb
                                    required property var modelData
                                    u: pp.u; radius: 16 * pp.u
                                    width: (lc.width - (pp.fl ? 1 : parent.columns - 1) * pp.gap) / (pp.fl ? 2 : parent.columns); height: 84 * pp.u
                                    on: { var v = modelData[0]
                                          return ((v === "zh" || v === "en" || v === "ja") && kb.layout === "main" && kb.lang === v)
                                              || (v === "num" && kb.layout === "num") || v === kb.mode }
                                    onTapped: {
                                        var v = modelData[0]
                                        kb.closePanel()
                                        if (v === "num") kb.setLayout("num")
                                        else if (v === "sym") kb.openPanel("sym")
                                        else if (v === "zh" || v === "en" || v === "ja") { kb.setLayout("main"); kb.setLang(v) }
                                        else if (v === "adjust") kb.startAdjust()
                                        else kb.setMode(v)
                                    }
                                    Column {
                                        anchors.centerIn: parent; spacing: 6 * pp.u
                                        Image { anchors.horizontalCenter: parent.horizontalCenter; width: 28 * pp.u; height: width
                                                sourceSize: Qt.size(Math.round(width * Screen.devicePixelRatio), Math.round(width * Screen.devicePixelRatio))
                                                source: Theme.ic(modelData[1], lb.on ? "#ffffff" : Theme.icon, 2) }
                                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData[2]; color: lb.on ? "#ffffff" : Theme.ink
                                               font.family: Theme.font; font.weight: Font.DemiBold; font.pixelSize: 16 * pp.u }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        }
    }

    // ======================= 语音 =======================
    Component {
        id: voice
        Item {
            id: vo
            property string text: ""
            property bool done: false
            property bool enterAfter: false
            function recognised(t) {
                vo.text = t
                // the gateway is one-shot: show the result for a beat, then commit and close
                commitTimer.restart()
            }
            function failed(m) { vo.text = ""; vo.enterAfter = false }
            // closePanel() destroys this item: take enterAfter into a local first
            Timer { id: commitTimer; interval: 420; onTriggered: { var e = vo.enterAfter; vo.enterAfter = false; kb.typeText(vo.text); vo.done = true; kb.closePanel(); if (e) kb.doEnter(false) } }
            Component.onCompleted: { kb.haptic("B", "medium"); if (osk.previewState === "") osk.voice.start() }
            Item {
                width: parent.width; height: pp.topY
                TBtn { u: pp.u; x: 8 * pp.u; anchors.verticalCenter: parent.verticalCenter; icon: "settings"; label: "语音设置"
                       onTapped: kb.toast("语音识别：语音网关（普通话 / English 自动）", "", 1800) }
                Text { anchors.centerIn: parent; color: Theme.ink; font.family: Theme.font; font.weight: Font.Medium; font.pixelSize: 19 * pp.u
                       text: osk.voice.state === 1 ? "我在听，请说" : osk.voice.state === 2 ? "识别中" : vo.text !== "" ? "识别完成" : "点「说完了」结束" }
                TBtn { u: pp.u; anchors.right: parent.right; anchors.rightMargin: 14 * pp.u; anchors.verticalCenter: parent.verticalCenter
                       icon: "close"; label: "关闭"; onTapped: kb.closePanel() }
            }
            Rectangle {
                x: pp.inset; y: pp.topY + 6 * pp.u
                width: parent.width - 2 * pp.inset; height: parent.height - y - pp.rowH - pp.bottomPad - 16 * pp.u
                radius: 18 * pp.u; color: Theme.card
                Column {
                    anchors.centerIn: parent; spacing: 16 * pp.u
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Math.min(implicitWidth, parent.parent.width * 0.86); horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap
                        text: vo.text !== "" ? vo.text : osk.voice.state === 1 ? osk.voice.seconds + " 秒" : ""
                        color: vo.text !== "" ? Theme.ink : Theme.ink3
                        font.family: Theme.font; font.weight: vo.text !== "" ? Font.Medium : Font.Normal; font.pixelSize: (vo.text !== "" ? 26 : 21) * pp.u
                    }
                    Wave { anchors.horizontalCenter: parent.horizontalCenter; u: pp.u; bars: pp.fl ? 21 : 37; live: osk.voice.state === 1; level: osk.voice.level }
                }
                Rectangle {
                    x: 18 * pp.u; anchors.bottom: parent.bottom; anchors.bottomMargin: 16 * pp.u
                    height: 34 * pp.u; width: lt.implicitWidth + 28 * pp.u; radius: height / 2; color: Theme.accSoft
                    Text { id: lt; anchors.centerIn: parent; text: "普通话 / English"; color: Theme.accInk; font.family: Theme.font; font.pixelSize: 15 * pp.u }
                }
            }
            Row {
                x: pp.inset; y: parent.height - pp.bottomPad - pp.rowH; spacing: pp.gap
                readonly property real unit: (parent.width - 2 * pp.inset - 4 * pp.gap) / 6.83
                Repeater {
                    model: [["en", "英", 1], ["punct", "，", 1], ["done", "说完了", 2.83], ["del", "", 1], ["enter", "", 1]]
                    delegate: Key {
                        required property var modelData
                        u: pp.u; width: parent.unit * modelData[2]; height: pp.rowH
                        def: ({ t: modelData[0] === "del" ? "del" : modelData[0] === "enter" ? "enter" : "try", fn: modelData[0] !== "done" })
                        accent: modelData[0] === "done"
                        Text { visible: modelData[1] !== ""; anchors.centerIn: parent; text: modelData[1]; color: parent.accent ? "#ffffff" : Theme.ink
                               font.family: Theme.font; font.weight: Font.Medium; font.pixelSize: (modelData[0] === "punct" ? 24 : 21) * pp.u }
                        TapHandler {
                            gesturePolicy: TapHandler.WithinBounds
                            onPressedChanged: { parent.down = pressed; if (pressed) { kb.click(modelData[0] === "del" ? "del" : modelData[0] === "enter" ? "enter" : "char"); kb.haptic(pp.side(parent), "key") } }
                            onTapped: {
                                switch (modelData[0]) {
                                case "en": kb.closePanel(); kb.setLang("en"); break
                                case "punct": kb.typeText("，"); break
                                case "done": if (osk.voice.state === 1) osk.voice.finish(); else if (osk.voice.state === 0 && vo.text === "") osk.voice.start(); break
                                case "del": kb.doDelete(); break
                                case "enter":
                                    if (osk.voice.state === 1) { vo.enterAfter = true; osk.voice.finish() }      // text first, then Enter
                                    else if (osk.voice.state === 2 || commitTimer.running) vo.enterAfter = true
                                    else { kb.closePanel(); kb.doEnter(false) }
                                    break
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
