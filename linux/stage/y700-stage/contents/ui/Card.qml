// One card in the column (vivo 原子工作台): the group's picture at the stage's aspect, one window 172 wide or
// two 83 + 6 + 83, each rounded 10; the whole card in perspective (its right edge 0.9 high, towards the
// column's middle); each app's icon pressed onto its picture's lower-left corner, no names. Tap = to the
// stage, long press = the menu (the card lifts to 1.05), drag (16 px) = onto the stage (Stage.qml).
import QtQuick
import Qt5Compat.GraphicalEffects
import org.kde.kwin as K
import org.kde.kirigami as Kirigami

Item {
    id: card
    required property int gid
    required property var stage
    readonly property var group: (stage.rev, stage.groupById(gid))
    readonly property var wins: (stage.rev, group ? group.wins : [])   // g.wins is replaced, not changed in place
    width: stage.cardW
    height: stage.cardH(wins.length)
    // a flight's copies stand in for it (instant: the copy is drawn in the same place)
    opacity: !group || stage.flyHidden.indexOf(gid) >= 0 ? 0 : 1
    readonly property bool lifted: !!group && stage.menuGroup === group
    // the column's middle in this card's coordinates, which the perspective converges on (follows the reorder)
    readonly property real cy: stage.midY() - stage.area.y - (ListView.view ? ListView.view.y + y - ListView.view.contentY : y)
    readonly property var quad: stage.trapezoid(0, 0, width, height, stage.persp, cy)
    readonly property var qq: stage.sq2quad(quad)

    // Still pictures (11-09). A live K.WindowThumbnail makes KWin render its window offscreen for as long as the
    // thumbnail exists, visible or not: frame callbacks at the output's refresh rate, 120 Hz here
    // (Window::refOffscreenRendering). Live cards kept every app in the column drawing in the background (Chrome,
    // wiliwili: 6-8 W on the tablet). So a card takes its picture once: a thumbnail per window, copied into a
    // ShaderEffectSource that then stops (live: false), and the thumbnail is destroyed. KWin fills a thumbnail
    // only as it composites a frame of a screen it shows on, so the picture is taken while the column is up and
    // the card drawn, for shotMs; a hidden column or a hidden card waits. New windows in the card or a new shape
    // (the keyboard's work area: the slot and the cards go shorter), a new picture, not the old one stretched.
    // The copies of a flight or a drag (Stage.qml) are live thumbnails, for as long as those last.
    readonly property int shotMs: 600
    property bool shot: false                     // the picture is taken
    readonly property bool shooting: !shot && stage.shown && opacity > 0
    onWinsChanged: shot = false
    onHeightChanged: shot = false
    // and when a window of the card changes size (11-10): minimized, it commits what it was asked (Stage.qml
    // placeRest: back into its slot after the keyboard) only on the frame callbacks this very thumbnail brings, so
    // the right size turns up in the middle of a take or just after one. A take ends no sooner than half a second
    // after the last size change (one more beat if need be): the last frame copied is the settled one
    readonly property string sizes: wins.map(w => w ? Math.round(w.frameGeometry.width) + "x" + Math.round(w.frameGeometry.height) : "").join(" ")
    property real sizedAt: 0
    onSizesChanged: { sizedAt = Date.now(); shot = false }
    Timer {
        interval: card.shotMs; running: card.shooting; repeat: true
        onTriggered: if (Date.now() - card.sizedAt >= card.shotMs - 100) card.shot = true
    }
    // the thumbnail stays one beat after the copy stops: the copy must not see it go
    property bool linger: false
    onShootingChanged: if (!shooting) { linger = true; lingerTimer.restart() }
    Timer { id: lingerTimer; interval: 100; onTriggered: card.linger = false }

    // the app icon on a card's corner, 30, with a soft shadow (vivo: elevation 12); also used by Stage.qml
    component Badge: Item {
        property alias source: icon.source
        width: 30; height: 30
        Kirigami.Icon { id: icon; anchors.fill: parent; visible: false }
        DropShadow {
            anchors.fill: icon
            source: icon
            verticalOffset: 3
            radius: 6
            samples: 13
            color: Qt.rgba(0, 0, 0, 0.35)
            transparentBorder: true
        }
    }

    Item {
        id: body
        width: card.width; height: card.height
        scale: card.lifted ? 1.05 : drag.active ? 0.973 : tap.pressed ? 0.97 : 1
        opacity: drag.active ? 0.4 : 1
        // the target picks the motion (vivo): press 200 ms, the drag's 300, release and lift 250
        Behavior on scale {
            id: press
            NumberAnimation {
                duration: (press.targetValue < 0.971 ? 200 : press.targetValue < 1 ? 300 : 250) * card.stage.k
                easing.type: Easing.BezierSpline
                easing.bezierCurve: press.targetValue < 0.971 ? card.stage.cDown : press.targetValue < 1 ? card.stage.cDrag : card.stage.cUp
            }
        }
        Behavior on opacity { NumberAnimation { duration: 300 * card.stage.k; easing.type: Easing.BezierSpline; easing.bezierCurve: card.stage.cDrag } }

        // the picture drawn 4x into its own layer and scaled down (mipmapped): the perspective's slanted edges come
        // out smooth instead of stair-stepped (bed 11-09). layer.samples (MSAA) would do it too, but was blamed for a
        // test-KWin hang that turned out to be the yuv709 shim (README 踩坑) and never tried again; this one is seen
        // working. The trapezoid lies inside the card's rect: nothing is cut.
        Item {
            width: card.width; height: card.height
            layer.enabled: true
            layer.textureSize: Qt.size(Math.ceil(width * 4), Math.ceil(height * 4))
            layer.mipmap: true
            layer.smooth: true
            Item {
                width: card.width; height: card.height
                transform: Matrix4x4 { matrix: card.stage.quadMatrix(card.quad, card.width, card.height) }
                Repeater {
                    model: card.wins
                    // rounded by a mask, as the task cards (StackCard.qml) do it; the layer also cuts off the
                    // window's shadow, which a thumbnail draws outside its frame
                    Item {
                        id: half
                        required property var modelData
                        required property int index
                        readonly property rect r: card.stage.sub(0, 0, index, card.wins.length)
                        x: r.x; y: r.y; width: r.width; height: r.height
                        layer.enabled: true
                        layer.effect: OpacityMask { maskSource: Rectangle { width: half.width; height: half.height; radius: card.stage.rCard } }
                        Rectangle { anchors.fill: parent; color: "#111" }
                        // the live thumbnail, only while the picture is taken (see shotMs); a new one each time:
                        // one whose window was let go keeps a node on a texture KWin has deleted
                        Loader {
                            id: thumbHolder
                            anchors.fill: parent
                            active: card.shooting || card.linger
                            sourceComponent: K.WindowThumbnail { wId: half.modelData.internalId }
                        }
                        ShaderEffectSource {
                            anchors.fill: parent
                            sourceItem: thumbHolder
                            hideSource: true
                            live: card.shooting
                        }
                    }
                }
            }
        }
        Repeater {
            model: card.wins
            Badge {
                required property var modelData
                required property int index
                // the picture's lower-left corner through the perspective, the icon 5 out of it
                readonly property var at: card.stage.mapPt(card.qq, card.stage.sub(0, 0, index, card.wins.length).x / card.width, 1)
                x: at[0] - 5; y: at[1] + 5 - 30
                source: modelData.icon
            }
        }
    }

    TapHandler {
        id: tap
        longPressThreshold: 0.5
        onTapped: card.stage.tapCard(card.gid, card.mapToItem(null, 0, 0))
        onLongPressed: card.stage.openMenu(card.gid, card.mapToItem(null, 0, 0))
    }
    DragHandler {
        id: drag
        target: null
        dragThreshold: 16
        onActiveChanged: active ? card.stage.dragStart(card.gid, centroid.scenePressPosition, card.mapToItem(null, 0, 0), centroid.scenePosition)
                                : card.stage.dragEnd(card.gid)
        onCentroidChanged: if (active) card.stage.dragMove(card.gid, centroid.scenePosition)
    }
}
