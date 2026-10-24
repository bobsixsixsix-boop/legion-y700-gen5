// The performance numbers as a desktop widget (10-22: a widget on the desktop, the status bar only over an app):
// on the desktop the status bar keeps only its clock and the numbers sit in a card at the top left, its edge under
// the clock's; in an app they are a line in the status bar instead (HudLine.qml). Same thresholds (hud.js).
// Layout (second round, 10-22 afternoon: the first layout of the widget looked unbalanced): a 3 x 2 grid
// where every cell is the same two lines, a label over one reading. Row 1 is the power row and is the whole "mini"
// step (rate | the device's draw | the battery: level, or what goes in or out of it on the charger); row 2 is the
// temperature row (skin | CPU | GPU, the load small in the label). The outer columns are flush with the card's
// edges (left column left-aligned, right column right-aligned) and the middle one is centred on the card, so the
// insets are the same 16 px on both sides whatever the numbers are. No clock speeds, volts or charger protocol:
// on the desktop the device idles and they say nothing; the status bar line in an app still has the speeds.
// Material: flat - KWin blur behind a dark veil and a 1 px rim, no sheen; darker than the dock on purpose, so
// white text stays readable over a light sky (the first round's light glass was not). Warnings only where something
// is wrong (temperatures, the draw, throttling, a low frame rate), in lighter tints that keep their contrast here.
// Layer-shell Bottom layer (src/main.cpp): above the wallpaper and the desktop icons, under every window; scope
// "dock", so the task switcher draws it on its desktop layer with the dock. Takes no touches and does nothing when
// tapped. Nothing animates: a number changing is not an event.
import QtQuick
import QtQuick.Window
import "hud.js" as H

Window {
    id: win
    required property var shellRoot
    readonly property var r: shellRoot
    readonly property var kv: hud.kv
    readonly property bool mini: hud.mode === "mini"
    readonly property var chg: H.charger(kv)

    // geometry: 16 px clear all round (the top to the label's ink; the bottom from the last baseline, 17: the digits'
    // ink reaches into the baseline's row); a cell is a label (baseline 11) over a reading (baseline 42); rows 61
    // apart (18 px clear from a reading to the next label); 20 px at least between columns
    readonly property int pad: 16
    readonly property int padB: 17
    readonly property int labBase: 11
    readonly property int valBase: 42
    readonly property int pitch: 61
    readonly property int gapX: 20
    readonly property int radius: 16
    readonly property color dim: Qt.rgba(1, 1, 1, 0.74)
    readonly property color loadInk: Qt.rgba(1, 1, 1, 0.9)

    // the alarm colours on this card: hud.js's red and green are the system's, too dark on a veil over a bright
    // sky (red came out 2.1:1 on the bed's bright wallpaper); the same hues lighter, 3.4:1 and 4.6:1 there. Amber
    // keeps its own (5.3:1).
    function tint(c) { return c === H.BAD ? "#ff847a" : c === H.GOOD ? "#5fdc7f" : c }
    function num(k) { return H.num(kv, k) }
    function has(k) { return H.has(kv, k) }

    FontMetrics { id: fLab; font.pixelSize: 13; font.weight: Font.DemiBold; font.features: { "tnum": 1 } }
    FontMetrics { id: fBig; font.pixelSize: 26; font.weight: Font.DemiBold; font.features: { "tnum": 1 } }
    FontMetrics { id: fUnit; font.pixelSize: 14; font.weight: Font.DemiBold }
    function readW(v, u) { return fBig.advanceWidth(v) + (u ? 3 + fUnit.advanceWidth(u) : 0) }
    // each column as wide as the widest label or reading it can show (tabular figures)
    readonly property int w0: Math.ceil(Math.max(readW("120", "FPS"), readW("56", "°C"), fLab.advanceWidth("机身 降频")))
    readonly property int w1: Math.ceil(Math.max(readW("18.8", "W"), readW("99", "°C"), fLab.advanceWidth("整机功耗"),
                                                 fLab.advanceWidth("CPU") + 6 + fLab.advanceWidth("100 %")))
    readonly property int w2: Math.ceil(Math.max(readW("+21.4", "W"), readW("100", "%"), readW("99", "°C"),
                                                 fLab.advanceWidth("供电不足"), fLab.advanceWidth("GPU") + 6 + fLab.advanceWidth("100 %")))

    // the middle column centred on the card, the outer ones flush with its edges
    width: pad * 2 + Math.max(w0, w2) * 2 + gapX * 2 + w1
    height: pad + pitch + valBase + padB
    color: "transparent"
    flags: Qt.FramelessWindowHint
    title: "y700-hud-widget"
    visible: r.ready && hud.on && r.onDesktop

    function sync() {
        if (!visible) return;
        shell.setBlur(win, 0, 0, Math.round(card.width), Math.round(card.height), radius);
        shell.setInputRects(win, []);
    }
    onVisibleChanged: {
        Qt.callLater(sync);
        shell.log("hud widget: " + (visible ? "shown " + hud.mode + " " + cardSize() : "hidden"));
    }
    function cardSize() { return Math.round(card.width) + "x" + Math.round(card.height) }
    function logSize() { if (visible) shell.log("hud widget: " + hud.mode + " " + cardSize()) }   // the bed reads it

    // the battery cell, in words read at a glance: off the charger the level; charging the rate into the
    // battery (快充 from 10 W: a PD charger tapering near full says 充电); a charger too weak to run the device (a
    // 5 V computer port) the rate out of it; on the charger and holding, full or not
    readonly property var batt: {
        const pct = has("bat_pct") ? String(Math.round(num("bat_pct"))) : "—";
        if (!chg.on) return { label: "电池", value: pct, unit: has("bat_pct") ? "%" : "", color: H.INK };
        if (chg.charging) return { label: chg.batW >= 10 ? "快充" : "充电", value: "+" + chg.batW.toFixed(1), unit: "W", color: tint(H.GOOD) };
        if (chg.showRate) return { label: "供电不足", value: "−" + (-chg.batW).toFixed(1), unit: "W", color: H.INK };
        return { label: num("bat_pct") >= 99 ? "已充满" : "插电", value: pct, unit: has("bat_pct") ? "%" : "", color: H.INK };
    }

    Item {
        id: card
        width: win.width
        height: win.mini ? win.pad + win.valBase + win.padB : win.height
        onWidthChanged: { Qt.callLater(win.sync); Qt.callLater(win.logSize) }
        onHeightChanged: { Qt.callLater(win.sync); Qt.callLater(win.logSize) }

        Rectangle {
            anchors.fill: parent
            radius: win.radius
            color: Qt.rgba(14 / 255, 14 / 255, 16 / 255, 0.64)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.10)
        }

        // ---- row 1: the power row (= mini)
        Cell {
            col: 0; row: 0
            label: win.has("fps") ? "帧率" : "刷新率"
            value: win.has("fps") ? Math.round(win.num("fps")) : win.has("hz") ? Math.round(win.num("hz")) : "—"
            unit: win.has("fps") ? "FPS" : win.has("hz") ? "Hz" : ""
            valueColor: win.has("fps") ? win.tint(H.color("fps", win.num("fps"))) : win.has("hz") ? H.INK : win.dim
        }
        Cell {
            col: 1; row: 0
            label: "整机功耗"
            // on PPS the charge pumps carry the charge and the input is not measured, so neither is the draw
            value: win.has("sys_w") ? win.num("sys_w").toFixed(1) : "—"
            unit: win.has("sys_w") ? "W" : ""
            valueColor: win.has("sys_w") ? win.tint(H.color("sys_w", win.num("sys_w"))) : win.dim
        }
        Cell {
            col: 2; row: 0
            label: win.batt.label; value: win.batt.value; unit: win.batt.unit; valueColor: win.batt.color
        }

        // ---- row 2: the temperature row (the full step only)
        Cell {
            col: 0; row: 1; visible: !win.mini
            label: "机身"
            tag: win.num("thr") !== 0 ? "降频" : ""; tagColor: win.tint(H.BAD)
            value: Math.round(win.num("skin_c")); unit: "°C"
            valueColor: win.tint(H.color("skin_c", win.num("skin_c")))
        }
        Cell {
            col: 1; row: 1; visible: !win.mini
            label: "CPU"; tag: Math.round(win.num("cpu")) + " %"
            value: Math.round(win.num("cpu_c")); unit: "°C"
            valueColor: win.tint(H.color("cpu_c", win.num("cpu_c")))
        }
        Cell {
            col: 2; row: 1; visible: !win.mini
            label: "GPU"; tag: Math.round(win.num("gpu")) + " %"
            value: Math.round(win.num("gpu_c")); unit: "°C"
            valueColor: win.tint(H.color("gpu_c", win.num("gpu_c")))
        }
    }

    // a label (and a tag after it: the load, or 降频) over a reading (a number and its unit 3 px after it), on
    // baselines, so the CJK font's tall line box moves nothing. Column 0 is left-aligned at the card's left inset,
    // column 2 right-aligned at its right inset, column 1 centred on the card; the label and the reading of a cell
    // share that edge or axis. Whole pixels throughout.
    component Cell: Item {
        id: cell
        property int col
        property int row
        property string label
        property string tag
        property color tagColor: win.loadInk
        property string value
        property string unit
        property color valueColor: H.INK
        x: 0
        y: win.pad + row * win.pitch
        width: card.width
        height: win.valBase
        readonly property int labW: Math.ceil(lab.implicitWidth) + (tag ? 6 + Math.ceil(tg.implicitWidth) : 0)
        readonly property int readW: Math.ceil(big.implicitWidth) + (unit ? 3 + Math.ceil(u.implicitWidth) : 0)
        function place(w) {
            return col === 0 ? win.pad : col === 2 ? card.width - win.pad - w : Math.round((card.width - w) / 2);
        }
        Text {
            id: lab
            x: cell.place(cell.labW)
            y: Math.round(win.labBase - baselineOffset)
            text: cell.label
            color: win.dim
            font.pixelSize: 13; font.weight: Font.DemiBold
        }
        Text {
            id: tg
            visible: cell.tag !== ""
            x: lab.x + Math.ceil(lab.implicitWidth) + 6
            y: Math.round(win.labBase - baselineOffset)
            text: cell.tag
            color: cell.tagColor
            font.pixelSize: 13; font.weight: Font.DemiBold; font.features: { "tnum": 1 }
        }
        Text {
            id: big
            x: cell.place(cell.readW)
            y: Math.round(win.valBase - baselineOffset)
            text: cell.value
            color: cell.valueColor
            font.pixelSize: 26; font.weight: Font.DemiBold; font.features: { "tnum": 1 }
        }
        Text {
            id: u
            visible: cell.unit !== ""
            x: big.x + Math.ceil(big.implicitWidth) + 3
            y: Math.round(win.valBase - baselineOffset)
            text: cell.unit
            color: win.dim
            font.pixelSize: 14; font.weight: Font.DemiBold
        }
    }
}
