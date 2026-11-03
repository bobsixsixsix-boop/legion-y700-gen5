.pragma library

// Palette, text formatting and chart geometry for the battery page (DESIGN.md 6b.c).
//
// Everything here is a pure function of its arguments: no Qt objects, no QML context, no system time
// zone. That keeps the page's numbers identical to the report's (out.py implements the same duration and
// clock rules) and lets page/tests/fmt-test.mjs run this file under node. Chart geometry comes back as
// plain [x, y] pairs; Chart.qml turns them into Qt.point for the Shape paths.
//
// Clock rule: every wall time is shown in the report's zone (doc.tz_offset_min), never the tablet's:
// new Date((t + tz * 60) * 1000) read with the getUTC* methods.

// ---------------------------------------------------------------- palette (section 6 视觉 + 6b.a colour roles)

var BG = "#121212"
var TEXT = "#f2f2f2"
var TEXT2 = "#9a9a9a"
var ACCENT = "#2e6bf6"
var ACCENT2 = "#8fb0ff"
var CHARGE = "#34c759"
var SCREEN = "#f2c94c"
var WARN = "#f2994a"
var DIVIDER = "#262626"
var NEUTRAL1 = "#9a9a9a"
var NEUTRAL2 = "#707070"
var NEUTRAL3 = "#4d4d4d"
var NEUTRAL4 = "#333333"

var ROLE = {
    screen: SCREEN, accent: ACCENT, accent2: ACCENT2,
    neutral1: NEUTRAL1, neutral2: NEUTRAL2, neutral3: NEUTRAL3, neutral4: NEUTRAL4
}
var LEVEL = { warn: WARN, charge: CHARGE }

// the one ease-out curve every animation on the page uses (emil-design-eng): Easing.Bezier control points
var EASE = [0.23, 1, 0.32, 1, 1, 1]

function roleColor(role) {
    return ROLE[role] || NEUTRAL2
}

function levelColor(level) {
    return LEVEL[level] || WARN
}

// ---------------------------------------------------------------- numbers and times (6b.a 「报表生成的文字…」)

function pad2(n) {
    return n < 10 ? "0" + n : "" + n
}

function local(t, tz) {
    return new Date((t + tz * 60) * 1000)
}

// Durations are floored, never rounded: 3599 s must read 「59 分」, not 「60 分」, and 7230 s is a whole 「2 小时」.
function dur(s) {
    s = Math.max(0, Math.floor(s))
    if (s < 60)
        return "不到 1 分"
    var m = Math.floor(s / 60)
    if (m < 60)
        return m + " 分"
    var h = Math.floor(m / 60)
    m = m % 60
    return m === 0 ? h + " 小时" : h + " 小时 " + m + " 分"
}

// p is the largest-remainder integer the report already made add up to used_pct; raw only decides 「<1%」.
function pct(p, raw) {
    return (p === 0 && raw > 0) ? "<1%" : p + "%"
}

// For values that come only as raw percentage points (an item's parts): round half up, keep 「<1%」.
function pctRaw(v) {
    return pct(Math.floor(v + 0.5), v)
}

function clock(t, tz) {
    var d = local(t, tz)
    return pad2(d.getUTCHours()) + ":" + pad2(d.getUTCMinutes())
}

function dayClock(t, tz) {
    return local(t, tz).getUTCDate() + "日 " + clock(t, tz)
}

function mmdd(t, tz) {
    var d = local(t, tz)
    return pad2(d.getUTCMonth() + 1) + "-" + pad2(d.getUTCDate())
}

function dayNo(t, tz) {
    return Math.floor((t + tz * 60) / 86400)
}

function rel(t, now, tz) {
    var diff = dayNo(now, tz) - dayNo(t, tz)
    if (diff === 0)
        return "今天 " + clock(t, tz)
    if (diff === 1)
        return "昨天 " + clock(t, tz)
    return dayClock(t, tz)
}

// Time-axis label: a range up to 36 h reads in clock times, a longer one in days.
function tick(t, span, tz) {
    return span <= 36 * 3600 ? clock(t, tz) : local(t, tz).getUTCDate() + "日"
}

// Busy times (处理器忙, 图形芯片忙) are whole minutes, rounded; a few seconds still say something.
function minutes(s) {
    var m = Math.round(s / 60)
    return (m === 0 && s > 0) ? "不到 1 分钟" : m + " 分钟"
}

// Wake-ups: exact below 10 000; above that 「约 3.4 万次」, whole 万 from 10 万 on.
function count(n) {
    if (n < 10000)
        return n + " 次"
    var w = n / 10000
    var txt = w < 10 ? String(Math.round(w * 10) / 10) : String(Math.round(w))
    return "约 " + txt + " 万次"
}

function remain(h) {
    if (h < 1) {
        var m = Math.max(1, Math.round(h * 60))
        return m >= 60 ? "约 1 小时" : "约 " + m + " 分钟"
    }
    return "约 " + Math.round(h) + " 小时"
}

// ---------------------------------------------------------------- sentences the page puts together from numbers

// The basis of the remaining time: the report takes the past day (basis_h 24); another basis_h is named in hours.
function remainBasis(basisH) {
    return basisH >= 24 ? "按过去一天的用法" : "按最近 " + basisH + " 小时的用法"
}

// Summary line 1 from the live sysfs state (C++ reads it; the report's copy may be minutes old).
// A charger that is plugged but too weak (status Discharging) reads as plugged-and-not-charging.
function statusLine(status, plugged, rem) {
    var s
    if (status === "charging")
        s = "正在充电"
    else if (status === "full")
        s = "已充满 · 正在用充电器"
    else if (status === "not_charging" || plugged)
        s = "插着充电器 · 没在充电"
    else
        s = "正在用电池"
    if (!plugged && status !== "charging" && status !== "full" && status !== "not_charging" && rem)
        s += " · " + remainBasis(rem.basis_h) + "还能用" + remain(rem.h)
    return s
}

// Summary line 3. 「亮灭不明」 is the discharge nobody watched the screen for (before the ledger started):
// without it a range that began before the recorder would read 「亮屏 4 分」 next to 「用掉 76%」.
function summaryLine3(r) {
    if (!r)
        return ""
    var parts = []
    if (r.on_s + r.off_s >= 60)
        parts.push("亮屏 " + dur(r.on_s) + " · 熄屏 " + dur(r.off_s))
    var u = (r.end - r.start) - r.on_s - r.off_s - r.charger_s - r.gap_s
    if (u >= 300)
        parts.push("亮灭不明 " + dur(u))
    if (r.charger_s >= 60)
        parts.push("插电 " + dur(r.charger_s))
    return parts.join(" · ")
}

// The grey second line of a list row.
function rowSub(it, r) {
    if (!it)
        return ""
    if (it.kind === "app" || it.kind === "apps_rest") {
        var parts = []
        if (it.fg_s >= 60)
            parts.push("前台 " + dur(it.fg_s))
        if (it.bg_s >= 60)
            parts.push("后台 " + dur(it.bg_s))
        return parts.join(" · ")
    }
    if (it.kind === "screen")
        return r ? "亮屏 " + dur(r.on_s) : ""
    if ((it.kind === "ui" || it.kind === "sys") && it.cpu_s != null)
        return "处理器忙 " + minutes(it.cpu_s)
    return ""
}

// 「在前台时 9% · 在后台时 3%（其中熄屏 2%）」; the bracket only when some of it really fell in screen-off time.
function splitLine(it) {
    if (!it || !it.split || !it.split_raw)
        return ""
    var s = "在前台时 " + pct(it.split.fg, it.split_raw.fg) + " · 在后台时 " + pct(it.split.bg, it.split_raw.bg)
    if (it.split_raw.off > 0)
        s += "（其中熄屏 " + pct(it.split.off, it.split_raw.off) + "）"
    return s
}

// Detail fact table: [label, value] rows, only for the fields the report filled in.
function facts(it) {
    var out = []
    if (!it)
        return out
    if (it.fg_s != null)
        out.push(["前台使用", dur(it.fg_s)])
    if (it.bg_s != null)
        out.push(["后台开着", dur(it.bg_s)])
    if (it.cpu_s != null)
        out.push(["处理器忙", minutes(it.cpu_s)])
    if (it.gpu_s != null)
        out.push(["图形芯片忙", minutes(it.gpu_s)])
    if (it.wake_off_n != null)
        out.push(["熄屏时醒来", count(it.wake_off_n)])
    return out
}

// Banners for the landscape strip: one line, joined with 「；」 (6b.a); the colour bar follows the first one.
function bannerText(list) {
    var out = []
    for (var i = 0; i < list.length; i++)
        out.push(list[i].text)
    return out.join("；")
}

// ---------------------------------------------------------------- chart: what is at time t

function inBand(t, list) {
    if (!list)
        return false
    for (var i = 0; i < list.length; i++)
        if (t >= list[i][0] && t < list[i][1])
            return true
    return false
}

// What the read-out names: 没记录 (gap) > 插电 > 亮屏 > 熄屏. Before data_from nobody watched the screen,
// so the state is left out rather than guessed as 熄屏.
function stateAt(t, bands, dataFrom) {
    if (inBand(t, bands.gap))
        return "没记录"
    if (inBand(t, bands.charger))
        return "插电"
    if (inBand(t, bands.on))
        return "亮屏"
    if (dataFrom !== null && dataFrom !== undefined && t < dataFrom)
        return ""
    return "熄屏"
}

// Battery % at t, linear between curve points; at a vertical jump (two points, same t) the later one wins.
function interp(curve, t) {
    if (!curve || curve.length === 0)
        return null
    if (t <= curve[0][0])
        return curve[0][1]
    var n = curve.length
    if (t >= curve[n - 1][0])
        return curve[n - 1][1]
    var lo = 0, hi = n - 1
    while (hi - lo > 1) {
        var mid = (lo + hi) >> 1
        if (curve[mid][0] <= t)
            lo = mid
        else
            hi = mid
    }
    var a = curve[lo], b = curve[hi]
    if (b[0] === a[0])
        return b[1]
    return a[1] + (b[1] - a[1]) * (t - a[0]) / (b[0] - a[0])
}

function readout(t, p, state, tz) {
    var s = dayClock(t, tz)
    if (p !== null && p !== undefined)
        s += " · " + Math.round(p) + "%"
    if (state)
        s += " · " + state
    return s
}

// ---------------------------------------------------------------- chart: geometry

// The curve cut at every charger / gap band edge into runs of one kind: "line" (on battery, accent),
// "charge" (plugged, green), "gap" (no data: the straight hop between the two points either side, dashed).
// Runs are lists of [t, pct]; a vertical jump stays in the run it continues.
function splitCurve(curve, bands) {
    var out = { line: [], charge: [], gap: [] }
    if (!curve || curve.length < 2)
        return out
    var cuts = []
    var lists = [bands.gap || [], bands.charger || []]
    for (var l = 0; l < lists.length; l++)
        for (var k = 0; k < lists[l].length; k++)
            cuts.push(lists[l][k][0], lists[l][k][1])
    cuts.sort(function (x, y) { return x - y })

    function kindAt(t) {
        if (inBand(t, bands.gap))
            return "gap"
        if (inBand(t, bands.charger))
            return "charge"
        return "line"
    }

    var run = null, runKind = null
    for (var i = 0; i + 1 < curve.length; i++) {
        var a = curve[i], b = curve[i + 1]
        var pts = [a]
        for (var c = 0; c < cuts.length; c++) {
            var x = cuts[c]
            if (x > a[0] && x < b[0])
                pts.push([x, a[1] + (b[1] - a[1]) * (x - a[0]) / (b[0] - a[0])])
        }
        pts.push(b)
        for (var j = 0; j + 1 < pts.length; j++) {
            var p0 = pts[j], p1 = pts[j + 1]
            var kind = (p0[0] === p1[0] && runKind !== null) ? runKind : kindAt((p0[0] + p1[0]) / 2)
            if (kind !== runKind || run === null) {
                run = [p0, p1]
                out[kind].push(run)
                runKind = kind
            } else {
                run.push(p1)
            }
        }
    }
    return out
}

// 45° hatch lines (rising to the right) filling the slab x0..x1 between top and bottom, as [[x, y], [x, y]]
// segments. The line family sits on a global grid of `step`, so neighbouring gaps share one pattern.
function hatch(x0, x1, top, bottom, step) {
    var out = []
    var h = bottom - top
    if (x1 <= x0 || h <= 0 || step <= 0)
        return out
    for (var u = Math.floor((x0 - h) / step) * step; u < x1; u += step) {
        var s0 = Math.max(0, (x0 - u) / h), s1 = Math.min(1, (x1 - u) / h)
        if (s1 > s0)
            out.push([[u + s0 * h, bottom - s0 * h], [u + s1 * h, bottom - s1 * h]])
    }
    return out
}

// A straight line as dash segments (pixel space): `on` px drawn, `off` px skipped.
function dashes(x0, y0, x1, y1, on, off) {
    var out = []
    var dx = x1 - x0, dy = y1 - y0
    var len = Math.sqrt(dx * dx + dy * dy)
    if (len <= 0 || on <= 0)
        return out
    for (var s = 0; s < len; s += on + off) {
        var e = Math.min(len, s + on)
        out.push([[x0 + dx * s / len, y0 + dy * s / len], [x0 + dx * e / len, y0 + dy * e / len]])
    }
    return out
}

// [a, b] minus the union of bands, as sorted [from, to] pieces.
function subtract(a, b, bands) {
    var out = []
    var cur = a
    var sorted = (bands || []).slice().sort(function (x, y) { return x[0] - y[0] })
    for (var i = 0; i < sorted.length && cur < b; i++) {
        var s = sorted[i][0], e = sorted[i][1]
        if (e <= cur)
            continue
        if (s >= b)
            break
        if (s > cur)
            out.push([cur, s])
        cur = Math.max(cur, e)
    }
    if (cur < b)
        out.push([cur, b])
    return out
}

// Tick times for the time axis, on the local (tz) grid. Up to 36 h: clock steps from 5 min to 12 h, the
// smallest that gives at most 6 ticks; longer: local midnights every 1/2/3/7/14 days, at most 8. A range
// too short to hold a grid line (a few minutes) labels its two ends instead.
function tickTimes(start, end, tz) {
    var span = end - start, off = tz * 60, out = [], i, step, first, n
    if (span <= 0)
        return out
    if (span <= 36 * 3600) {
        var steps = [300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200]
        for (i = 0; i < steps.length; i++) {
            step = steps[i]
            first = Math.ceil((start + off) / step) * step - off
            n = first <= end ? Math.floor((end - first) / step) + 1 : 0
            if (n === 0)
                break
            if (n <= 6) {
                for (var k = 0; k < n; k++)
                    out.push(first + k * step)
                return out
            }
        }
        return [start, end]
    }
    var days = [1, 2, 3, 7, 14]
    first = Math.ceil((start + off) / 86400) * 86400 - off
    for (i = 0; i < days.length; i++) {
        step = days[i] * 86400
        n = first <= end ? Math.floor((end - first) / step) + 1 : 0
        if (n <= 8 || i === days.length - 1) {
            for (var d = 0; d < n; d++)
                out.push(first + d * step)
            return out
        }
    }
    return out
}

// Stacked bar: segment boxes {x, w} for raws across `width` with `gap` px between them. Every segment gets
// at least `minW` px so a sliver stays visible; the rest is shared by raw, and the last box ends exactly at width.
function segments(raws, width, gap, minW) {
    var out = []
    var n = raws.length
    if (n === 0)
        return out
    var avail = Math.max(0, width - gap * (n - 1) - minW * n)
    var sum = 0, i
    for (i = 0; i < n; i++)
        sum += Math.max(0, raws[i])
    var x = 0, acc = 0
    for (i = 0; i < n; i++) {
        acc += Math.max(0, raws[i])
        var share = sum > 0 ? acc / sum : (i + 1) / n
        var end = Math.round(minW * (i + 1) + gap * i + share * avail)
        out.push({ x: x, w: Math.max(0, end - x) })
        x = end + gap
    }
    return out
}
