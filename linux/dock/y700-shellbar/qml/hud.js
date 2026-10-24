.pragma library
// The performance numbers' shared rules, for HudLine.qml (the status bar, in an app) and HudWidget.qml (the desktop
// widget): the thresholds the overlay bar had (linux/games/hud/overlay/src/main.rs grade(): amber from the first
// value, red from the second; reverse = low is bad) and the charger state as main.rs tail() reads it. The pairs
// come from the sampler's .kv file (src/hud.cpp), all strings.

var INK = "#ffffff";
var WARN = "#ffcc00";
var BAD = "#ff453a";
var GOOD = "#34c759";   // the battery's charging green (the status bar's battery cell has the same)

var T = {
    fps: [45, 28, true],
    cpu: [80, 95],
    cpu_c: [85, 95],
    gpu: [85, 97],
    gpu_mhz: [800, 650, true],   // only while the GPU is busy (>= 50 %): idle is 160 MHz by design
    gpu_c: [80, 90],
    skin_c: [50, 56],
    sys_w: [12, 16]
};

function num(kv, k) { var v = parseFloat(kv[k]); return isNaN(v) ? 0 : v; }
function has(kv, k) { return kv[k] !== undefined && kv[k] !== ""; }

// 0 fine, 1 amber, 2 red
function level(k, v) {
    var t = T[k];
    if (!t) return 0;
    if (t[2]) return v <= t[1] ? 2 : v <= t[0] ? 1 : 0;
    return v >= t[1] ? 2 : v >= t[0] ? 1 : 0;
}

// the colour of value v of key k: white when fine (or `fine`, e.g. the widget's dim second line)
function color(k, v, fine) {
    var l = level(k, v);
    return l === 2 ? BAD : l === 1 ? WARN : (fine === undefined ? INK : fine);
}

// off the charger: the device's draw (sys_w). Charging: the input (in_w) and the battery's rate; on PPS the charge
// pumps carry it and the input is not measured (in_w empty: "pump"). Full on the charger: the draw again, no rate
// below 0.5 W; a battery draining on the charger: a negative rate.
function charger(kv) {
    var on = kv.on === "1";
    var hasRate = has(kv, "bat_w");
    var batW = hasRate ? num(kv, "bat_w") : 0;
    var charging = on && hasRate && batW > 0.5;
    return {
        on: on,
        batW: batW,
        charging: charging,
        pump: charging && !has(kv, "in_w"),
        showRate: on && hasRate && Math.abs(batW) >= 0.5,
        showVolt: on && has(kv, "in_v") && num(kv, "in_v") > 0.5
    };
}
