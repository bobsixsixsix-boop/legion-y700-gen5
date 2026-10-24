// Top band: the toolbar (vivo slot order; the 小V写作 slot became 剪贴板, then 文本编辑) or, while
// composing, the pinyin string over the candidate row with the ⌄ expander. Pulling the band down by
// 70 px puts the keyboard away (same threshold as the control centre's swipe-to-close).
import QtQuick
import QtQuick.Effects
import "."

Item {
    id: band
    required property var kb
    readonly property real u: kb.u

    function scrollCandidates(dx) {
        cands.contentX = Math.max(0, Math.min(Math.max(0, cands.contentWidth - cands.width), cands.contentX + dx))
    }

    readonly property var tools: [
        { id: "toolbox", ic: "expand", lab: "工具箱" }, { id: "emoji", ic: "emoji", lab: "表情" },
        { id: "layout", ic: "keyboard", lab: "键盘选择" }, { id: "voice", ic: "mic", lab: "语音输入" },
        { id: "clip", ic: "clipboard", lab: "剪贴板" }, { id: "edit", ic: "cursor_edit", lab: "文本编辑" } ]
    readonly property real pitch: (kb.mode === "float" ? 64 : kb.mode === "split" ? 76 : 123) * u
    readonly property real pad: (kb.mode === "float" ? 6 : 24) * u
    readonly property real rightStart: width - pad - 2 * 56 * u - 12 * u     // x of the split toggle

    // ---- toolbar ----
    Item {
        id: toolbar
        anchors.fill: parent
        opacity: kb.composing ? 0 : 1
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 140 } }
        Repeater {
            model: band.tools
            delegate: TBtn {
                required property var modelData
                required property int index
                u: band.u
                // split: 工具箱/表情/键盘选择 on the left half, 语音/剪贴板/编辑 on the right half
                x: kb.mode === "split" && index > 2 ? band.rightStart - (6 - index) * band.pitch : band.pad + index * band.pitch
                anchors.verticalCenter: parent.verticalCenter
                icon: modelData.ic; label: modelData.lab
                on: kb.panel === modelData.id
                onTapped: kb.openPanel(modelData.id)
            }
        }
        TBtn {
            visible: kb.mode !== "float"
            u: band.u
            x: band.width - band.pad - 2 * 56 * band.u - 12 * band.u
            anchors.verticalCenter: parent.verticalCenter
            icon: kb.mode === "split" ? "dock" : "split"; label: kb.mode === "split" ? "常规键盘" : "分离键盘"
            on: kb.mode === "split"
            onTapped: kb.setMode(kb.mode === "split" ? "dock" : "split")
        }
        TBtn {
            u: band.u
            x: band.width - band.pad - 56 * band.u
            anchors.verticalCenter: parent.verticalCenter
            icon: "collapse"; label: "收起键盘"
            onTapped: kb.hideKeyboard()
        }
    }

    // ---- composition ----
    Item {
        id: compo
        anchors.fill: parent
        opacity: kb.composing ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 140 } }
        Text {
            id: pinyin
            x: 16 * band.u; y: 6 * band.u; height: 20 * band.u
            text: osk.preedit
            color: Theme.ink; opacity: 0.8
            font.family: Theme.font; font.pixelSize: (kb.mode === "float" ? 15 : 18) * band.u; font.letterSpacing: 0.4
        }
        ListView {
            id: cands
            x: 0; y: 26 * band.u
            width: parent.width - more.width - pager.width; height: parent.height - y
            orientation: ListView.Horizontal
            clip: true
            // the last 8 % fades out (the mockup's mask-image): a cut word reads as "more to the right"
            layer.enabled: true
            layer.effect: MultiEffect { maskEnabled: true; maskSource: fadeMask; maskThresholdMin: 0.5; maskSpreadAtMin: 1.0 }
            boundsBehavior: Flickable.StopAtBounds
            model: osk.candidates
            onModelChanged: positionViewAtBeginning()
            delegate: Item {
                required property string modelData
                required property int index
                width: Math.max(56 * band.u, label.implicitWidth + 40 * band.u); height: cands.height
                Rectangle { anchors.centerIn: parent; width: parent.width; height: 46 * band.u; radius: 10 * band.u; color: tap.pressed ? Theme.card : "transparent" }
                Text {
                    id: label
                    anchors.centerIn: parent
                    text: modelData
                    // the highlighted candidate: mozc says which (cursor), rime does not (then the first)
                    readonly property bool hi: index === (osk.candidateCursor >= 0 ? osk.candidateCursor : 0)
                    color: hi ? Theme.accInk : Theme.ink
                    font.family: Theme.font; font.weight: hi ? Font.Medium : Font.Normal
                    font.pixelSize: (kb.mode === "float" ? 19 : 22) * band.u
                }
                TapHandler {
                    id: tap
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onPressedChanged: if (pressed) { kb.click("char"); kb.haptic(band.sideOf(parent), "key") }
                    onTapped: osk.selectCandidate(index)
                }
            }
        }
        Rectangle {
            id: fadeMask
            visible: false
            layer.enabled: true
            width: cands.width; height: cands.height
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.92; color: "black" }
                GradientStop { position: 1.0; color: "transparent" }
            }
        }
        // ‹ › for paged candidate lists (mozc); rime's bulk list never shows them
        Row {
            id: pager
            anchors.right: more.left
            y: 26 * band.u; height: parent.height - y
            visible: osk.hasPrev || osk.hasNext
            width: visible ? implicitWidth : 0
            Repeater {
                model: [["arrow_left", false], ["arrow_right", true]]
                delegate: Item {
                    required property var modelData
                    readonly property bool can: modelData[1] ? osk.hasNext : osk.hasPrev
                    width: 48 * band.u; height: pager.height
                    opacity: can ? 1 : 0.3
                    Image { anchors.centerIn: parent; width: 22 * band.u; height: width
                            sourceSize: Qt.size(Math.round(width * Screen.devicePixelRatio), Math.round(width * Screen.devicePixelRatio))
                            source: Theme.ic(modelData[0], Theme.icon2, 2) }
                    TapHandler {
                        enabled: parent.can
                        gesturePolicy: TapHandler.ReleaseWithinBounds
                        onPressedChanged: if (pressed) { kb.click("tool"); kb.haptic(band.sideOf(parent), "key") }
                        onTapped: modelData[1] ? osk.nextPage() : osk.prevPage()
                    }
                }
            }
        }
        Item {
            id: more
            anchors.right: parent.right
            y: 26 * band.u; width: 60 * band.u; height: parent.height - y
            Rectangle { x: 0; y: 11 * band.u; width: 1; height: parent.height - 22 * band.u; color: Theme.sep }
            Image { anchors.centerIn: parent; width: 24 * band.u; height: width
                    sourceSize: Qt.size(Math.round(width * Screen.devicePixelRatio), Math.round(width * Screen.devicePixelRatio))
                    source: Theme.ic("candidate_more", Theme.icon2, 2) }
            TapHandler {
                gesturePolicy: TapHandler.ReleaseWithinBounds
                onPressedChanged: if (pressed) { kb.click("expand"); kb.haptic("R", "key") }
                onTapped: kb.openPanel("cands")
            }
        }
    }

    function sideOf(it) { return kb.sideAt(it) }

    // ---- pull down to hide (docked / split only) ----
    DragHandler {
        id: pull
        enabled: kb.mode !== "float"
        target: null
        xAxis.enabled: false
        grabPermissions: PointerHandler.CanTakeOverFromAnything
        onTranslationChanged: {
            if (translation.y > 0) kb.pullY = Math.min(translation.y, 140 * band.u) * 0.6
            if (translation.y >= 70 * band.u && active) { kb.pullY = 0; kb.hideKeyboard() }
        }
        onActiveChanged: if (!active) kb.pullY = 0
    }
}
