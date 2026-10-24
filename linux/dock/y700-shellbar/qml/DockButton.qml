// A 60 px pressable square (dock icons, the all-apps button). The press motion: down to 0.90 in 200 ms
// on cubic(.25,.45,.30,1), back in 250 ms on cubic(.25,.45,.35,1). The finger owns the button once down
// (no other handler may take the point over), and a tap counts only if it is lifted inside.
import QtQuick

Item {
    id: btn
    width: 60
    height: 60
    signal pressedAt(point pt)
    signal released()
    signal tapped()
    property bool down: tap.pressed

    scale: down ? 0.90 : 1
    Behavior on scale {
        NumberAnimation {
            duration: btn.down ? 200 : 250
            easing.type: Easing.BezierSpline
            easing.bezierCurve: btn.down ? [0.25, 0.45, 0.30, 1, 1, 1] : [0.25, 0.45, 0.35, 1, 1, 1]
        }
    }

    TapHandler {
        id: tap
        gesturePolicy: TapHandler.WithinBounds
        grabPermissions: PointerHandler.TakeOverForbidden
        onPressedChanged: pressed ? btn.pressedAt(point.position) : btn.released()
        onTapped: btn.tapped()
    }
}
