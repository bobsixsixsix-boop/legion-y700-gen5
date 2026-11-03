// Battery curve for one range (section 6 曲线; 6b.a bands / buckets). Local layout, y = 0 at the plot top:
//   plot        x plotX (48) .. width, y 0 .. plotH      grid 0/50/100 %, labels right-aligned 12 px left of it
//   screen bar  y plotH + 12 .. + 28                     bands.on in the screen colour on a divider track
//   time axis   y plotH + 36 .. + 60                     HH:MM up to 36 h, else D日
//   legend      y plotH + 72 .. + 96
// In the landscape window plotX lands on x 104 and the 296 px plot on y 264-560.
//
// Under the curve: charger bands (12 % green), the open item's per-bucket bars (accent, 35 %, at most 30 %
// of the plot) and, for 「没记到是谁用的」, the uncovered bands (neutral4, 35 %). The curve is one Shape:
// discharge runs in accent, charger runs green, a gap as a dashed hop over grey hatching.
//
// Read-out: a 1 px line and 「30日 14:20 · 64% · 亮屏」 that follow the finger with no animation, fading out
// 1.5 s after release. Landscape reads on press; in the portrait page (holdToRead) the finger must rest
// 250 ms first so a scroll of the page wins, and the read then keeps the page from scrolling.
import QtQuick
import QtQuick.Shapes
import "Fmt.js" as Fmt

Item {
    id: chart
    property var range: null
    property int tz: 0
    property var detailBuckets: null          // null, or the open item's `buckets` (aligned with range.bucket_t)
    property bool showUncovered: false
    property real plotH: 296
    property bool holdToRead: false

    implicitHeight: plotH + 96

    readonly property real plotX: 48
    readonly property real plotW: Math.max(1, width - plotX)
    readonly property real barY: plotH + 12
    readonly property real tickY: plotH + 36
    readonly property real legendY: plotH + 72

    readonly property real t0: range ? range.start : 0
    readonly property real t1: range ? range.end : 1
    readonly property real span: Math.max(1, t1 - t0)
    readonly property var bands: range ? range.bands : ({ on: [], charger: [], gap: [], uncovered: [] })

    function xOf(t) { return plotX + (t - t0) / span * plotW }
    function yOf(p) { return plotH * (1 - p / 100) }

    // ---------------- geometry (rebuilt when the range or the size changes, never per frame)

    // the Shape reaches 4 px above and below the plot so the 2.5 px line is not cut at 0 % and 100 %; not to
    // the right: the curve ends at `end` on the plot's right edge, and its round cap must not pass the column
    readonly property real shapePad: 4
    readonly property var runs: range ? Fmt.splitCurve(range.curve, range.bands) : ({ line: [], charge: [], gap: [] })

    function polys(list) {
        var out = []
        for (var i = 0; i < list.length; i++) {
            var pts = []
            for (var j = 0; j < list[i].length; j++)
                pts.push(Qt.point(xOf(list[i][j][0]), shapePad + yOf(list[i][j][1])))
            out.push(pts)
        }
        return out
    }
    function pairs(list) {
        var out = []
        for (var i = 0; i < list.length; i++)
            out.push([Qt.point(list[i][0][0], list[i][0][1]), Qt.point(list[i][1][0], list[i][1][1])])
        return out
    }
    readonly property var linePaths: polys(runs.line)
    readonly property var chargePaths: polys(runs.charge)
    readonly property var dashPaths: {
        var out = []
        for (var i = 0; i < runs.gap.length; i++) {
            var r = runs.gap[i]
            for (var j = 0; j + 1 < r.length; j++)
                out = out.concat(pairs(Fmt.dashes(xOf(r[j][0]), shapePad + yOf(r[j][1]),
                                                  xOf(r[j + 1][0]), shapePad + yOf(r[j + 1][1]), 6, 5)))
        }
        return out
    }
    readonly property var hatchPaths: {
        var out = []
        for (var i = 0; i < bands.gap.length; i++)
            out = out.concat(pairs(Fmt.hatch(xOf(bands.gap[i][0]), xOf(bands.gap[i][1]), shapePad, shapePad + plotH, 8)))
        return out
    }

    // the open item's bars; the first bucket also holds the use from `start` to its own beginning (6b.a 桶)
    readonly property var barRects: {
        var out = []
        if (!range || !detailBuckets)
            return out
        var bt = range.bucket_t, bs = range.bucket_s, mx = 0, i
        for (i = 0; i < detailBuckets.length; i++)
            mx = Math.max(mx, detailBuckets[i])
        if (mx <= 0)
            return out
        for (i = 0; i < bt.length && i < detailBuckets.length; i++) {
            var v = detailBuckets[i]
            if (v <= 0)
                continue
            var a = i === 0 ? t0 : Math.max(t0, bt[i])
            var b = Math.min(t1, bt[i] + bs)
            if (b <= a)
                continue
            var xa = xOf(a), xb = xOf(b)
            var h = Math.max(1, v / mx * 0.3 * plotH)
            out.push({ x: xa + 1, w: Math.max(1, xb - xa - 2), h: h })
        }
        return out
    }

    // the screen bar's track: where screen on/off is known (not before data_from, not across a gap)
    readonly property var track: {
        if (!range)
            return []
        var from = (range.data_from !== null && range.data_from !== undefined) ? Math.max(t0, range.data_from) : t0
        return Fmt.subtract(from, t1, bands.gap)
    }
    readonly property var ticks: range ? Fmt.tickTimes(range.start, range.end, tz) : []

    // ---------------- plot

    Repeater {
        model: [100, 50, 0]
        delegate: Item {
            id: grid
            required property var modelData
            Rectangle {
                x: chart.plotX
                y: Math.min(chart.plotH - 1, Math.round(chart.yOf(grid.modelData)))
                width: chart.plotW
                height: 1
                color: Fmt.DIVIDER
            }
            Text {
                x: 0
                y: chart.yOf(grid.modelData) - 12
                width: chart.plotX - 12
                height: 24
                horizontalAlignment: Text.AlignRight
                verticalAlignment: Text.AlignVCenter
                text: grid.modelData + "%"
                color: Fmt.TEXT2
                font.pixelSize: 16
            }
        }
    }

    Repeater {
        model: chart.bands.charger
        delegate: Rectangle {
            required property var modelData
            x: chart.xOf(modelData[0])
            width: Math.max(1, chart.xOf(modelData[1]) - chart.xOf(modelData[0]))
            height: chart.plotH
            color: Qt.rgba(0.204, 0.780, 0.349, 0.12)
        }
    }

    Repeater {
        model: chart.showUncovered ? chart.bands.uncovered : []
        delegate: Rectangle {
            required property var modelData
            x: chart.xOf(modelData[0])
            width: Math.max(1, chart.xOf(modelData[1]) - chart.xOf(modelData[0]))
            height: chart.plotH
            color: Fmt.NEUTRAL4
            opacity: 0.35
        }
    }

    Repeater {
        model: chart.barRects
        delegate: Rectangle {
            required property var modelData
            x: modelData.x
            y: chart.plotH - modelData.h
            width: modelData.w
            height: modelData.h
            color: Fmt.ACCENT
            opacity: 0.35
        }
    }

    // GeometryRenderer is not antialiased; 4x MSAA on the layer is the long-standing way to smooth Shapes.
    // The layer clips to the Shape: at chart.width the last point's cap is cut at the column's right edge
    // (x 970 in portrait, 968 in landscape), where section 6 ends everything.
    Shape {
        y: -chart.shapePad
        width: chart.width
        height: chart.plotH + 2 * chart.shapePad
        layer.enabled: true
        layer.samples: 4

        ShapePath {
            strokeColor: Fmt.NEUTRAL3
            strokeWidth: 1
            fillColor: "transparent"
            PathMultiline { paths: chart.hatchPaths }
        }
        ShapePath {
            strokeColor: Fmt.NEUTRAL2
            strokeWidth: 2
            fillColor: "transparent"
            capStyle: ShapePath.FlatCap
            PathMultiline { paths: chart.dashPaths }
        }
        ShapePath {
            strokeColor: Fmt.CHARGE
            strokeWidth: 2.5
            fillColor: "transparent"
            joinStyle: ShapePath.RoundJoin
            capStyle: ShapePath.RoundCap
            PathMultiline { paths: chart.chargePaths }
        }
        ShapePath {
            strokeColor: Fmt.ACCENT
            strokeWidth: 2.5
            fillColor: "transparent"
            joinStyle: ShapePath.RoundJoin
            capStyle: ShapePath.RoundCap
            PathMultiline { paths: chart.linePaths }
        }
    }

    // ---------------- screen bar, time axis, legend

    Repeater {
        model: chart.track
        delegate: Rectangle {
            required property var modelData
            x: chart.xOf(modelData[0])
            y: chart.barY
            width: Math.max(1, chart.xOf(modelData[1]) - chart.xOf(modelData[0]))
            height: 16
            color: Fmt.DIVIDER
        }
    }
    Repeater {
        model: chart.bands.on
        delegate: Rectangle {
            required property var modelData
            x: chart.xOf(modelData[0])
            y: chart.barY
            width: Math.max(1, chart.xOf(modelData[1]) - chart.xOf(modelData[0]))
            height: 16
            color: Fmt.SCREEN
        }
    }

    Repeater {
        model: chart.ticks
        delegate: Text {
            required property var modelData
            x: Math.max(chart.plotX, Math.min(chart.plotX + chart.plotW - implicitWidth,
                                              chart.xOf(modelData) - implicitWidth / 2))
            y: chart.tickY
            height: 24
            verticalAlignment: Text.AlignVCenter
            text: Fmt.tick(modelData, chart.span, chart.tz)
            color: Fmt.TEXT2
            font.pixelSize: 16
        }
    }

    component Key: Row {
        id: key
        property string label: ""
        property color tint: "white"
        property string swatch: "line"        // line | block | dash
        property real tintOpacity: 1
        spacing: 8
        height: 24
        Item {
            width: 16
            height: 24
            Rectangle { visible: key.swatch === "line"; y: 11; width: 16; height: 3; radius: 1; color: key.tint }
            Rectangle { visible: key.swatch === "block"; y: 6; width: 16; height: 12; color: key.tint; opacity: key.tintOpacity }
            Rectangle { visible: key.swatch === "dash"; y: 11; width: 6; height: 2; color: key.tint }
            Rectangle { visible: key.swatch === "dash"; x: 10; y: 11; width: 6; height: 2; color: key.tint }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: key.label
            color: Fmt.TEXT2
            font.pixelSize: 16
        }
    }

    Row {
        x: chart.plotX
        y: chart.legendY
        height: 24
        spacing: 24
        visible: chart.range !== null
        Key { label: "电量"; tint: Fmt.ACCENT }
        Key { label: "亮屏"; tint: Fmt.SCREEN; swatch: "block" }
        Key { label: "插电"; tint: Fmt.CHARGE; visible: chart.bands.charger.length > 0 }
        Key { label: "没记录"; tint: Fmt.NEUTRAL2; swatch: "dash"; visible: chart.bands.gap.length > 0 }
        Key { label: "这一项用的电"; tint: Fmt.ACCENT; swatch: "block"; tintOpacity: 0.35; visible: chart.barRects.length > 0 }
        Key {
            label: "没分项的时段"; tint: Fmt.NEUTRAL4; swatch: "block"; tintOpacity: 0.35
            visible: chart.showUncovered && chart.bands.uncovered.length > 0
        }
    }

    // ---------------- read-out

    property real readX: 0
    property var readPct: null
    property string readState: ""
    property string readText: ""

    function readAt(mx) {
        if (!range)
            return
        var x = Math.max(0, Math.min(plotW, mx))
        var t = t0 + x / plotW * span
        readState = Fmt.stateAt(t, bands, range.data_from)
        readPct = readState === "没记录" ? null : Fmt.interp(range.curve, t)
        readText = Fmt.readout(t, readPct, readState, tz)
        readX = Math.round(plotX + x)
        fade.stop()
        readLayer.opacity = 1
    }
    function endRead() {
        reader.reading = false
        reader.preventStealing = false
        if (readLayer.opacity > 0)
            fade.restart()
    }

    MouseArea {
        id: reader
        property bool reading: false
        x: chart.plotX
        width: chart.plotW
        height: chart.barY + 16
        enabled: chart.range !== null
        pressAndHoldInterval: 250
        onPressed: (mouse) => {
            if (!chart.holdToRead) {
                reader.reading = true
                chart.readAt(mouse.x)
            }
        }
        onPressAndHold: (mouse) => {
            if (chart.holdToRead) {
                // from here on the enclosing Flickable must not take the finger away
                reader.preventStealing = true
                reader.reading = true
                chart.readAt(mouse.x)
            }
        }
        onPositionChanged: (mouse) => { if (reader.reading) chart.readAt(mouse.x) }
        onReleased: chart.endRead()
        onCanceled: chart.endRead()
    }

    Item {
        id: readLayer
        width: chart.width
        height: chart.barY + 16
        opacity: 0
        visible: opacity > 0

        Rectangle {
            x: chart.readX
            width: 1
            height: parent.height
            color: Fmt.TEXT2
        }
        Rectangle {
            visible: chart.readPct !== null
            x: chart.readX - 3.5
            y: chart.yOf(chart.readPct === null ? 0 : chart.readPct) - 4
            width: 8
            height: 8
            radius: 4
            color: chart.readState === "插电" ? Fmt.CHARGE : Fmt.ACCENT
        }
        // beside the line, never on it, so the point being read stays visible; flips left near the right edge
        Rectangle {
            width: readLabel.implicitWidth + 24
            height: 36
            radius: 4
            color: Fmt.DIVIDER
            x: chart.readX + 12 + width <= chart.plotX + chart.plotW ? chart.readX + 12 : chart.readX - 12 - width
            y: 8
            Text {
                id: readLabel
                anchors.centerIn: parent
                text: chart.readText
                color: Fmt.TEXT
                font.pixelSize: 18
            }
        }
    }

    SequentialAnimation {
        id: fade
        PauseAnimation { duration: 1500 }
        NumberAnimation {
            target: readLayer
            property: "opacity"
            to: 0
            duration: 150
            easing.type: Easing.Bezier
            easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1]
        }
    }
}
