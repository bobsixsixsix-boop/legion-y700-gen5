// The performance line of the status bar (10-22: the performance overlay moves onto the status bar): the game
// overlay's numbers (hud: src/hud.cpp, the sampler y700-hud-overlay --sampler) after the clock, set in the bar's
// own type. Shown in an app only (over a fullscreen one the bar moves to the Overlay layer, Main.qml barOverlay);
// on the desktop the same numbers are a widget (HudWidget.qml). The overlay bar's steps and thresholds (hud.js):
// "full" = rate, CPU, GPU, skin, power; "mini" = rate and power. No battery percentage - the bar's right end has it.
// Labels dim, values white, amber / red past the thresholds; every value sits in a cell as wide as its widest
// reading, so nothing jitters as the numbers change. 28 px high like the bar; nothing animates (a number changing
// is not an event, the eye should find it where it was).
import QtQuick
import "hud.js" as H

Row {
    id: line
    height: 28
    spacing: 0
    onWidthChanged: if (visible) shell.log("hud line: " + Math.round(width) + " px wide")   // the bed reads it (tests/hud.sh)
    onVisibleChanged: if (visible) shell.log("hud line: " + Math.round(width) + " px wide")

    readonly property var kv: hud.kv
    readonly property bool mini: hud.mode === "mini"
    readonly property color dim: Qt.rgba(1, 1, 1, 0.55)
    // the charger tail, as main.rs tail() without the percentage: off the charger "PWR 1.5W"; charging
    // "BAT +15.6W · IN 19.9W 8.0V PD" (the rate in the charging green, not the overlay's yellow: the bar already
    // says "charging" in green); on PPS the pumps' input is not measured: "IN --"; full on the charger:
    // "PWR 4.5W 8.0V PD"; a battery draining on the charger: the rate in red
    readonly property var chg: H.charger(kv)

    function num(k) { return H.num(kv, k) }
    function has(k) { return H.has(kv, k) }

    component Lbl: Text {
        height: 28; verticalAlignment: Text.AlignVCenter
        color: line.dim; font.pixelSize: 13; font.weight: Font.DemiBold
    }
    // a right-aligned number in a cell as wide as `widest`
    component Val: Item {
        id: cell
        property string text
        property string widest: text
        property color color: H.INK
        width: Math.ceil(tm.advanceWidth); height: 28
        // by id, not `parent`: inside an inline component `parent` of a non-Item (TextMetrics) resolves to the
        // component's own parent, the Row (bed 10-22: "Unable to assign [undefined] to QString")
        TextMetrics { id: tm; font: t.font; text: cell.widest }
        Text {
            id: t
            anchors.right: cell.right; anchors.verticalCenter: cell.verticalCenter
            text: cell.text; color: cell.color
            font.pixelSize: 13; font.weight: Font.DemiBold; font.features: { "tnum": 1 }
        }
    }
    component Gap: Item { width: 5; height: 28 }
    component Sep: Item {
        width: 23; height: 28
        Rectangle { width: 1; height: 10; anchors.centerIn: parent; color: Qt.rgba(1, 1, 1, 0.28) }
    }

    // ---- rate: the game's FPS, else the panel's refresh rate (the overlay showed the same first column)
    Lbl { text: line.has("fps") ? "FPS" : "HZ" }
    Gap {}
    Val {
        widest: "888"
        text: line.has("fps") ? Math.round(line.num("fps")) : line.has("hz") ? Math.round(line.num("hz")) : "--"
        color: line.has("fps") ? H.color("fps", line.num("fps")) : line.has("hz") ? H.INK : line.dim
    }

    // ---- CPU / GPU / skin: the full step only
    Sep { visible: !line.mini }
    Lbl { visible: !line.mini; text: "CPU" }
    Gap { visible: !line.mini }
    Val { visible: !line.mini; widest: "100%"; text: Math.round(line.num("cpu")) + "%"; color: H.color("cpu", line.num("cpu")) }
    Gap { visible: !line.mini }
    Val { visible: !line.mini; widest: "8888MHz"; text: Math.round(line.num("cpu_mhz")) + "MHz" }
    Gap { visible: !line.mini }
    Val { visible: !line.mini; widest: "88°C"; text: Math.round(line.num("cpu_c")) + "°C"; color: H.color("cpu_c", line.num("cpu_c")) }
    Sep { visible: !line.mini }
    Lbl { visible: !line.mini; text: "GPU" }
    Gap { visible: !line.mini }
    Val { visible: !line.mini; widest: "100%"; text: Math.round(line.num("gpu")) + "%"; color: H.color("gpu", line.num("gpu")) }
    Gap { visible: !line.mini }
    Val {
        visible: !line.mini; widest: "8888MHz"; text: Math.round(line.num("gpu_mhz")) + "MHz"
        color: line.num("gpu") >= 50 ? H.color("gpu_mhz", line.num("gpu_mhz")) : H.INK
    }
    Gap { visible: !line.mini }
    Val { visible: !line.mini; widest: "88°C"; text: Math.round(line.num("gpu_c")) + "°C"; color: H.color("gpu_c", line.num("gpu_c")) }
    Sep { visible: !line.mini }
    Lbl { visible: !line.mini; text: "SKIN" }
    Gap { visible: !line.mini }
    Val { visible: !line.mini; widest: "88°C"; text: Math.round(line.num("skin_c")) + "°C"; color: H.color("skin_c", line.num("skin_c")) }
    Gap { visible: !line.mini && line.num("thr") !== 0 }
    Lbl { visible: !line.mini && line.num("thr") !== 0; text: "THR"; color: H.BAD }

    // ---- battery rate (on the charger) and power
    Sep { visible: line.chg.showRate }
    Lbl { visible: line.chg.showRate; text: "BAT" }
    Gap { visible: line.chg.showRate }
    Val {
        visible: line.chg.showRate; widest: "+88.8W"
        text: (line.chg.batW > 0 ? "+" : "") + line.chg.batW.toFixed(1) + "W"
        color: line.chg.batW > 0 ? H.GOOD : H.BAD
    }
    Sep {}
    Lbl { text: line.chg.charging ? "IN" : "PWR" }
    Gap {}
    Val {
        widest: "88.8W"
        text: line.chg.pump ? "--" : line.chg.charging ? line.num("in_w").toFixed(1) + "W" : line.num("sys_w").toFixed(1) + "W"
        color: line.chg.pump ? line.dim : line.chg.charging ? H.INK : H.color("sys_w", line.num("sys_w"))
    }
    Gap { visible: line.chg.showVolt }
    Val { visible: line.chg.showVolt; widest: "88.8V"; text: line.num("in_v").toFixed(1) + "V"; color: line.num("in_v") < 6 ? H.WARN : H.INK }
    Gap { visible: line.chg.showVolt && line.has("adapter") }
    Lbl { visible: line.chg.showVolt && line.has("adapter"); text: line.kv.adapter || "" }
}
