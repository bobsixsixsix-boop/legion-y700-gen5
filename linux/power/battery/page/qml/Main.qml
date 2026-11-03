// The battery page (DESIGN.md section 6, 6b.c). C++ (`backend`) owns the data: the report as one map, the
// live battery values, the error and cache state; this file only lays it out.
//
// State that must survive a rotation lives here, not in the layouts: the range (`rangeKey`), the open detail
// (`detailId`) and the detail's enter/exit progress (`dOpacity`, `dShift`). The two layouts are rebuilt from
// scratch when width > height flips, with no animation, and bind to these.
//
// Landscape (1600 x 974 after maximize, section 6 横屏): left column x 56-968, right column x 1016-1544;
// a KWin title bar's lost height comes out of the plot (296 px, at least 240) and everything below the
// plot moves up with it. Portrait (1002 x 1572): one Flickable, margin 32, plot 260 (at least 240); the
// detail is a whole page pushed over it.
//
// Motion: the segmented block slides 180 ms; the detail comes in from +24 px with a fade in 220 ms and goes
// out in 160 ms; presses scale. A range switch and a rotation change everything at once. No timers here
// (the chart's read-out fade is a one-shot animation), nothing loops.
import QtQuick
import "Fmt.js" as Fmt

Window {
    id: root
    visible: false
    title: "电池"
    color: "#121212"
    // C++ calls showMaximized(); the screen size is the closest guess until the compositor configures us
    width: Screen.width
    height: Screen.height

    readonly property bool landscape: width > height

    // backend.data converts the whole report to JS on every read; read it once per change, here only
    readonly property var doc: backend.data
    readonly property var ranges: doc && doc.ranges ? doc.ranges : null
    readonly property int tz: doc && typeof doc.tz_offset_min === "number" ? doc.tz_offset_min : 0
    readonly property real cachedOpacity: backend.stale ? 0.4 : 1

    readonly property var rangeModel: [
        { key: "since_full", label: "自上次充满" },
        { key: "24h", label: "24 小时" },
        { key: "7d", label: "7 天" }
    ]
    function validKey(k) {
        return k === "since_full" || k === "24h" || k === "7d"
    }
    property string rangeKey: validKey(backend.startRange) ? backend.startRange : "since_full"
    readonly property var range: ranges && ranges[rangeKey] ? ranges[rangeKey] : null

    function pickRange(key) {
        if (validKey(key))
            rangeKey = key
    }

    // ---------------------------------------------------------------- detail

    property string detailId: ""
    readonly property var detailItem: findItem(range, detailId)
    // the item on screen: the open one, or during the exit fade the one that was open
    property var lastItem: null
    readonly property var shownItem: detailItem ? detailItem : lastItem
    property real dOpacity: 0
    property real dShift: 24
    property bool startApplied: false

    function findItem(r, id) {
        if (!r || !r.items || id === "")
            return null
        for (var i = 0; i < r.items.length; i++)
            if (r.items[i].id === id)
                return r.items[i]
        return null
    }

    function openDetail(id) {
        var it = findItem(range, id)
        if (!it)
            return
        detailId = id
        lastItem = it
        exitAnim.stop()
        enterAnim.start()
    }
    function closeDetail() {
        if (detailId === "")
            return
        detailId = ""
        enterAnim.stop()
        exitAnim.start()
    }
    // the detail's final state without motion: a range switch, a refresh, the start-up --detail
    function snapDetail() {
        enterAnim.stop()
        exitAnim.stop()
        if (detailId !== "") {
            lastItem = detailItem
            dOpacity = 1
            dShift = 0
        } else {
            lastItem = null
            dOpacity = 0
            dShift = 24
        }
    }
    // 6b.c 切换范围时的详情: the same id in the new range stays open with the new numbers, otherwise back
    // to the list. The first range to arrive also applies --detail (test bench), once.
    function syncDetail() {
        if (!startApplied && range !== null) {
            startApplied = true
            if (backend.startDetail !== "" && findItem(range, backend.startDetail)) {
                detailId = backend.startDetail
                snapDetail()
                return
            }
        }
        if (detailId === "")
            return
        var it = findItem(range, detailId)
        if (it) {
            lastItem = it
        } else {
            detailId = ""
            snapDetail()
        }
    }
    onRangeChanged: syncDetail()
    Component.onCompleted: syncDetail()

    function goBack() {
        if (detailId !== "")
            closeDetail()
        else
            backend.quit()
    }

    ParallelAnimation {
        id: enterAnim
        NumberAnimation {
            target: root; property: "dOpacity"; to: 1; duration: 220
            easing.type: Easing.Bezier; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1]
        }
        NumberAnimation {
            target: root; property: "dShift"; to: 0; duration: 220
            easing.type: Easing.Bezier; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1]
        }
    }
    ParallelAnimation {
        id: exitAnim
        NumberAnimation {
            target: root; property: "dOpacity"; to: 0; duration: 160
            easing.type: Easing.Bezier; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1]
        }
        NumberAnimation {
            target: root; property: "dShift"; to: 24; duration: 160
            easing.type: Easing.Bezier; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1]
        }
        onFinished: root.lastItem = null
    }

    // the edge-swipe back gesture arrives as Esc for most windows (control centre backend.cpp), KEY_BACK
    // or Alt+Left elsewhere
    Shortcut {
        sequences: ["Esc", "Back", "Alt+Left"]
        onActivated: root.goBack()
    }

    // ---------------------------------------------------------------- texts the page puts together

    // the report's banners, behind the page's own one when the report failed (6b.c error / stale)
    readonly property var banners: {
        var out = []
        if (backend.error !== "")
            out.push({
                kind: "error", level: "warn",
                text: backend.stale && backend.cacheAgeMin >= 0
                      ? backend.cacheAgeMin + " 分钟前的数据 · " + backend.error : backend.error
            })
        var b = range && range.banners ? range.banners : []
        for (var i = 0; i < b.length; i++)
            out.push(b[i])
        return out
    }

    readonly property string footText: "怎么算的：总耗电是电池实测；屏幕估得较准，各应用只适合看谁多谁少（可能差三到五成）；插着充电器的时间不算。"
                                       + (range && range.footnote ? range.footnote : "")

    readonly property string healthText: {
        var b = doc && doc.battery ? doc.battery : null
        var parts = []
        if (b && b.health_pct !== null && b.health_pct !== undefined)
            parts.push("电池健康 " + b.health_pct + "%")
        if (b && b.cycles !== null && b.cycles !== undefined)
            parts.push("充放电 " + b.cycles + " 次")
        return parts.join(" · ")
    }

    // ---------------------------------------------------------------- pieces both layouts use
    // (inline components do not see this file's ids: everything comes in through properties)

    // 64 high, the whole row opens the KDE battery page (works with no report at all)
    component HealthRow: Item {
        id: hr
        property string label: ""
        property real dim: 1
        height: 64
        scale: hrTap.pressed ? 0.98 : 1
        Behavior on scale {
            NumberAnimation { duration: 120; easing.type: Easing.Bezier; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] }
        }
        Rectangle {
            anchors.fill: parent
            radius: 4
            color: Qt.rgba(1, 1, 1, 0.06)
            opacity: hrTap.pressed ? 1 : 0
            Behavior on opacity {
                NumberAnimation { duration: 120; easing.type: Easing.Bezier; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] }
            }
        }
        Text {
            x: 12
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, kde.x - 16 - x)
            elide: Text.ElideRight
            text: hr.label
            color: Fmt.TEXT
            font.pixelSize: 22
            opacity: hr.dim
        }
        Text {
            id: kde
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: "KDE 电量页 ›"
            color: Fmt.TEXT2
            font.pixelSize: 22
        }
        TapHandler {
            id: hrTap
            onTapped: backend.openKde()
        }
    }

    // section 6 说明: 18 px grey, two lines
    component Footnote: Text {
        wrapMode: Text.Wrap
        maximumLineCount: 2
        elide: Text.ElideRight
        lineHeightMode: Text.FixedHeight
        lineHeight: 28
        color: Fmt.TEXT2
        font.pixelSize: 18
    }

    // landscape: one 40 px line, the banners joined with 「；」 and elided; the bar takes the first one's level
    component BannerLine: Item {
        id: bl
        property var list: []
        height: 40
        visible: list.length > 0
        Rectangle {
            y: 8
            width: 3
            height: 24
            color: bl.list.length > 0 ? Fmt.levelColor(bl.list[0].level) : "transparent"
        }
        Text {
            x: 15
            width: Math.max(0, bl.width - 15)
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            text: Fmt.bannerText(bl.list)
            color: Fmt.TEXT
            font.pixelSize: 18
        }
    }

    // portrait: one banner per row, wrapping
    component BannerRows: Column {
        id: br
        property var list: []
        Repeater {
            model: br.list
            delegate: Item {
                id: brow
                required property var modelData
                width: br.width
                height: Math.max(40, bt.implicitHeight + 16)
                Rectangle {
                    y: 8
                    width: 3
                    height: brow.height - 16
                    color: Fmt.levelColor(brow.modelData.level)
                }
                Text {
                    id: bt
                    x: 15
                    width: Math.max(0, brow.width - 15)
                    anchors.verticalCenter: parent.verticalCenter
                    wrapMode: Text.Wrap
                    text: brow.modelData.text
                    color: Fmt.TEXT
                    font.pixelSize: 18
                }
            }
        }
    }

    // static placeholders while a report with no cache behind it is late (backend.skeleton); no shimmer
    component SkelSummary: Item {
        height: 92
        Rectangle { x: 192; y: 40; width: 360; height: 14; radius: 2; color: Fmt.DIVIDER }
        Rectangle { x: 192; y: 70; width: 280; height: 14; radius: 2; color: Fmt.DIVIDER }
    }
    component SkelRows: Column {
        id: sk
        property int rows: 6
        Repeater {
            model: sk.rows
            delegate: Item {
                width: sk.width
                height: 76
                Rectangle { y: 16; width: 44; height: 44; radius: 4; color: Fmt.DIVIDER }
                Rectangle { x: 60; y: 14; width: 180; height: 18; radius: 2; color: Fmt.DIVIDER }
                Rectangle { x: 60; y: 42; width: 260; height: 14; radius: 2; color: Fmt.DIVIDER }
                Rectangle { x: sk.width - 48; y: 26; width: 48; height: 20; radius: 2; color: Fmt.DIVIDER }
            }
        }
    }

    // ---------------------------------------------------------------- layouts

    Component {
        id: landscapeLayout

        Item {
            id: land
            readonly property real plotH: Math.max(240, 296 + root.height - 974)
            readonly property real rightX: width - 56 - 528
            readonly property real colW: Math.max(0, rightX - 48 - 56)
            // composition top: 688 with the full 296 px plot
            readonly property real lowY: 264 + plotH + 128

            Text {
                x: 56
                y: 24
                height: 56
                verticalAlignment: Text.AlignVCenter
                text: "电池"
                color: Fmt.TEXT
                font.pixelSize: 32
                font.weight: Font.DemiBold
            }
            Segmented {
                x: land.rightX
                y: 24
                width: 528
                height: 56
                model: root.rangeModel
                current: root.rangeKey
                onPicked: (key) => root.pickRange(key)
            }

            Summary {
                x: 56
                y: 104
                width: land.colW
                height: 92
                doc: root.doc
                range: root.range
                livePct: backend.livePct
                liveStatus: backend.liveStatus
                livePlugged: backend.livePlugged
            }
            SkelSummary {
                x: 56
                y: 104
                width: land.colW
                visible: backend.skeleton
            }

            BannerLine {
                x: 56
                y: 208
                width: land.colW
                list: root.banners
            }

            Chart {
                x: 56
                y: 264
                width: land.colW
                height: implicitHeight
                plotH: land.plotH
                range: root.range
                tz: root.tz
                detailBuckets: root.detailItem ? root.detailItem.buckets : null
                showUncovered: root.detailItem !== null && root.detailItem.kind === "unrecorded"
                opacity: root.cachedOpacity
            }

            Composition {
                x: 56
                y: land.lowY
                width: land.colW
                height: implicitHeight
                visible: root.range !== null
                range: root.range
                opacity: root.cachedOpacity
            }

            Footnote {
                x: 56
                y: land.lowY + 124
                width: land.colW
                text: root.footText
                opacity: root.cachedOpacity
            }

            HealthRow {
                x: 44
                y: land.lowY + 198
                width: land.colW + 24
                label: root.healthText
                dim: root.cachedOpacity
            }

            // right column, y 104-950: the list, or in its place the detail
            Item {
                x: land.rightX
                y: 104
                width: 528
                height: Math.max(0, land.height - 128)

                UsageList {
                    anchors.fill: parent
                    range: root.range
                    enabled: root.detailId === ""
                    opacity: (1 - root.dOpacity) * root.cachedOpacity
                    onOpen: (id) => root.openDetail(id)
                    onShowRange: (key) => root.pickRange(key)
                }
                SkelRows {
                    y: 80
                    width: parent.width
                    visible: backend.skeleton
                }
                Detail {
                    x: -12 + root.dShift
                    width: parent.width + 24
                    height: parent.height
                    sidePad: 12
                    item: root.shownItem
                    range: root.range
                    tz: root.tz
                    visible: root.dOpacity > 0
                    enabled: root.detailId !== ""
                    opacity: root.dOpacity * root.cachedOpacity
                    onBack: root.closeDetail()
                }
            }
        }
    }

    Component {
        id: portraitLayout

        Item {
            id: port
            readonly property real plotH: Math.max(240, 260 + root.height - 1572)
            readonly property bool hasComp: root.range !== null && !!root.range.composition && root.range.composition.length > 0

            Flickable {
                id: pflick
                anchors.fill: parent
                contentWidth: width
                contentHeight: content.height
                boundsBehavior: Flickable.StopAtBounds
                // hidden under an open detail by opacity, not visible: an invisible subtree collapses its
                // Columns, which would change contentHeight and move the scroll position
                opacity: root.dOpacity < 1 ? 1 : 0
                enabled: root.detailId === ""

                Item {
                    id: content
                    x: 32
                    width: Math.max(0, pflick.width - 64)
                    height: health.y + health.height + 32

                    Text {
                        y: 24
                        height: 56
                        verticalAlignment: Text.AlignVCenter
                        text: "电池"
                        color: Fmt.TEXT
                        font.pixelSize: 32
                        font.weight: Font.DemiBold
                    }
                    Segmented {
                        y: 96
                        width: content.width
                        height: 56
                        model: root.rangeModel
                        current: root.rangeKey
                        onPicked: (key) => root.pickRange(key)
                    }

                    Summary {
                        id: psum
                        y: 176
                        width: content.width
                        height: 92
                        doc: root.doc
                        range: root.range
                        livePct: backend.livePct
                        liveStatus: backend.liveStatus
                        livePlugged: backend.livePlugged
                    }
                    SkelSummary {
                        y: psum.y
                        width: content.width
                        visible: backend.skeleton
                    }

                    BannerRows {
                        id: pban
                        y: psum.y + psum.height + 12
                        width: content.width
                        list: root.banners
                    }

                    // 16 px clear above the plot: the 「100%」 label sits 12 px over the chart's top
                    Chart {
                        id: pchart
                        y: pban.y + pban.height + 16
                        width: content.width
                        height: implicitHeight
                        plotH: port.plotH
                        holdToRead: true
                        range: root.range
                        tz: root.tz
                        opacity: root.cachedOpacity
                    }

                    Composition {
                        id: pcomp
                        y: pchart.y + pchart.height + 32
                        width: content.width
                        visible: port.hasComp
                        height: port.hasComp ? implicitHeight : 0
                        range: root.range
                        opacity: root.cachedOpacity
                    }

                    UsageList {
                        id: plist
                        y: (port.hasComp ? pcomp.y + pcomp.height : pchart.y + pchart.height) + 32
                        width: content.width
                        height: backend.skeleton ? 80 + 6 * 76 : implicitHeight
                        scrolls: false
                        range: root.range
                        opacity: root.cachedOpacity
                        onOpen: (id) => root.openDetail(id)
                        onShowRange: (key) => root.pickRange(key)
                    }
                    SkelRows {
                        y: plist.y + 80
                        width: content.width
                        visible: backend.skeleton
                    }

                    Footnote {
                        id: pfoot
                        y: plist.y + plist.height + 24
                        width: content.width
                        text: root.footText
                        opacity: root.cachedOpacity
                    }

                    HealthRow {
                        id: health
                        x: -12
                        y: pfoot.y + pfoot.height + 18
                        width: content.width + 24
                        label: root.healthText
                        dim: root.cachedOpacity
                    }
                }
            }

            // the detail page, pushed over the list page
            Item {
                anchors.fill: parent
                visible: root.dOpacity > 0
                enabled: root.detailId !== ""
                opacity: root.dOpacity

                Rectangle {
                    anchors.fill: parent
                    color: Fmt.BG
                }
                Detail {
                    x: root.dShift
                    width: parent.width
                    height: parent.height
                    page: true
                    sidePad: 32
                    topPad: 24
                    bottomPad: 32
                    plotH: port.plotH
                    item: root.shownItem
                    range: root.range
                    tz: root.tz
                    opacity: root.cachedOpacity
                    onBack: root.closeDetail()
                }
            }
        }
    }

    Loader {
        anchors.fill: parent
        active: root.width > 0 && root.height > 0
        sourceComponent: root.landscape ? landscapeLayout : portraitLayout
    }
}
