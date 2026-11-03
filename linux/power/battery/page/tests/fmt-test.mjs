// Runs page/qml/Fmt.js (a QML `.pragma library` file) under node and checks it, then makes a rough
// text-width pass over the canned reports in linux/dock/tests/batpage/ in both orientations, and checks
// the few lines of QML geometry that pass models (the legend's wrap, the curve's right edge).
//
//   node linux/power/battery/page/tests/fmt-test.mjs
//
// Fmt.js has no Qt dependency by design, so stripping the pragma line is all it takes to load it. Times are
// checked in fixed zones (UTC+8 and UTC-5) through tz_offset_min, never the host's zone, which Fmt.js must
// not read. The width pass uses per-character advance estimates (CJK 1 em, digits ~0.57 em, ...): it cannot
// replace a look at the tablet, but it catches a string that is clearly too long for its slot.
import fs from "node:fs"
import path from "node:path"
import vm from "node:vm"
import { fileURLToPath } from "node:url"

const here = path.dirname(fileURLToPath(import.meta.url))
const src = fs.readFileSync(path.join(here, "..", "qml", "Fmt.js"), "utf8")
if (!src.startsWith(".pragma library"))
    throw new Error("Fmt.js must start with .pragma library")
const F = vm.createContext({})
vm.runInContext(src.replace(/^\.pragma library[^\n]*\n/, "\n"), F, { filename: "Fmt.js" })

let passed = 0
const failures = []
const notes = []
function eq(name, got, want) {
    const g = JSON.stringify(got), w = JSON.stringify(want)
    if (g === w)
        passed++
    else
        failures.push(`${name}: got ${g}, want ${w}`)
}
function ok(name, cond, detail = "") {
    if (cond)
        passed++
    else
        failures.push(`${name}${detail ? ": " + detail : ""}`)
}
// numbers from the vm context come back as plain values, arrays need a copy to compare structurally
const J = (v) => JSON.parse(JSON.stringify(v))

// ---------------------------------------------------------------- palette

eq("roleColor accent2", F.roleColor("accent2"), "#8fb0ff")
eq("roleColor neutral4", F.roleColor("neutral4"), "#333333")
eq("roleColor unknown", F.roleColor("nope"), "#707070")
eq("levelColor charge", F.levelColor("charge"), "#34c759")
eq("levelColor unknown", F.levelColor("x"), "#f2994a")
eq("EASE", J(F.EASE), [0.23, 1, 0.32, 1, 1, 1])

// ---------------------------------------------------------------- durations and percentages

eq("dur 0", F.dur(0), "不到 1 分")
eq("dur 59", F.dur(59), "不到 1 分")
eq("dur 60", F.dur(60), "1 分")
eq("dur 3599 floors", F.dur(3599), "59 分")
eq("dur 3600", F.dur(3600), "1 小时")
eq("dur 7230 whole hour", F.dur(7230), "2 小时")
eq("dur 7260", F.dur(7260), "2 小时 1 分")
eq("dur 548999", F.dur(548999), "152 小时 29 分")
eq("dur negative", F.dur(-5), "不到 1 分")

eq("pct <1", F.pct(0, 0.3), "<1%")
eq("pct 0", F.pct(0, 0), "0%")
eq("pct 12", F.pct(12, 11.6), "12%")
eq("pct 377", F.pct(377, 377.18), "377%")
eq("pctRaw 0.38", F.pctRaw(0.38), "<1%")
eq("pctRaw 0.5", F.pctRaw(0.5), "1%")
eq("pctRaw 2.5", F.pctRaw(2.5), "3%")
eq("pctRaw 2.49", F.pctRaw(2.49), "2%")
eq("pctRaw 0", F.pctRaw(0), "0%")

eq("minutes 0", F.minutes(0), "0 分钟")
eq("minutes 20", F.minutes(20), "不到 1 分钟")
eq("minutes 30", F.minutes(30), "1 分钟")
eq("minutes 405", F.minutes(405), "7 分钟")

eq("count 0", F.count(0), "0 次")
eq("count 9999", F.count(9999), "9999 次")
eq("count 10000", F.count(10000), "约 1 万次")
eq("count 34000", F.count(34000), "约 3.4 万次")
eq("count 34567", F.count(34567), "约 3.5 万次")
eq("count 870000", F.count(870000), "约 87 万次")

eq("remain 9.2", F.remain(9.2), "约 9 小时")
eq("remain 21.5", F.remain(21.5), "约 22 小时")
eq("remain 0.5", F.remain(0.5), "约 30 分钟")
eq("remain 0.999", F.remain(0.999), "约 1 小时")
eq("remain 0.001", F.remain(0.001), "约 1 分钟")

// ---------------------------------------------------------------- clock, in two fixed zones

const T = Date.UTC(2026, 9, 30, 0, 11, 0) / 1000          // 10-30 08:11 at UTC+8, 10-29 19:11 at UTC-5
eq("clock +8", F.clock(T, 480), "08:11")
eq("dayClock +8", F.dayClock(T, 480), "30日 08:11")
eq("mmdd +8", F.mmdd(T, 480), "10-30")
eq("clock -5", F.clock(T, -300), "19:11")
eq("dayClock -5", F.dayClock(T, -300), "29日 19:11")
eq("mmdd -5", F.mmdd(T, -300), "10-29")
eq("clock +5:30", F.clock(T, 330), "05:41")
eq("rel today", F.rel(T - 3600, T, 480), "今天 07:11")
eq("rel yesterday", F.rel(T - 86400, T, 480), "昨天 08:11")
eq("rel earlier", F.rel(T - 2 * 86400, T, 480), "28日 08:11")
// 00:30 local now, 23:50 the evening before: a different local day even though only 40 min apart
const mid = Date.UTC(2026, 9, 29, 16, 30, 0) / 1000       // 10-30 00:30 at UTC+8
eq("rel across midnight", F.rel(mid - 2400, mid, 480), "昨天 23:50")
eq("tick short", F.tick(T, 86400, 480), "08:11")
eq("tick 36h", F.tick(T, 36 * 3600, 480), "08:11")
eq("tick long", F.tick(T, 7 * 86400, 480), "30日")

// ---------------------------------------------------------------- sentences

// the report's remain is based on the past day (basis_h 24); another basis_h still reads in hours
eq("status discharging + remain", F.statusLine("discharging", false, { h: 9.2, basis_h: 24 }),
   "正在用电池 · 按过去一天的用法还能用约 9 小时")
eq("status discharging, short remain", F.statusLine("discharging", false, { h: 0.5, basis_h: 24 }),
   "正在用电池 · 按过去一天的用法还能用约 30 分钟")
eq("status discharging, no remain", F.statusLine("discharging", false, null), "正在用电池")
eq("status unknown + remain", F.statusLine("unknown", false, { h: 4, basis_h: 24 }),
   "正在用电池 · 按过去一天的用法还能用约 4 小时")
eq("status basis 3 h", F.statusLine("discharging", false, { h: 9.2, basis_h: 3 }),
   "正在用电池 · 按最近 3 小时的用法还能用约 9 小时")
eq("status charging", F.statusLine("charging", true, null), "正在充电")
eq("status full", F.statusLine("full", true, null), "已充满 · 正在用充电器")
eq("status not_charging", F.statusLine("not_charging", true, null), "插着充电器 · 没在充电")
eq("status weak charger", F.statusLine("discharging", true, { h: 3, basis_h: 24 }), "插着充电器 · 没在充电")

const R0 = { start: 0, end: 3600, on_s: 1200, off_s: 2400, charger_s: 0, gap_s: 0 }
eq("line3 plain", F.summaryLine3(R0), "亮屏 20 分 · 熄屏 40 分")
eq("line3 tiny", F.summaryLine3({ start: 0, end: 50, on_s: 20, off_s: 30, charger_s: 0, gap_s: 0 }), "")
eq("line3 null", F.summaryLine3(null), "")
eq("line3 unknown 299", F.summaryLine3({ start: 0, end: 3899, on_s: 1200, off_s: 2400, charger_s: 0, gap_s: 0 }),
   "亮屏 20 分 · 熄屏 40 分")
eq("line3 unknown 300", F.summaryLine3({ start: 0, end: 3900, on_s: 1200, off_s: 2400, charger_s: 0, gap_s: 0 }),
   "亮屏 20 分 · 熄屏 40 分 · 亮灭不明 5 分")

const app = { kind: "app", fg_s: 4800, bg_s: 21600, cpu_s: 405, gpu_s: 41, wake_off_n: 34000,
              split: { fg: 9, bg: 3, off: 2 }, split_raw: { fg: 8.7, bg: 2.9, off: 1.6 } }
eq("rowSub app", F.rowSub(app, R0), "前台 1 小时 20 分 · 后台 6 小时")
eq("rowSub app no fg", F.rowSub({ kind: "app", fg_s: 30, bg_s: 21600 }, R0), "后台 6 小时")
eq("rowSub app nothing", F.rowSub({ kind: "app", fg_s: 0, bg_s: 59 }, R0), "")
eq("rowSub screen", F.rowSub({ kind: "screen" }, R0), "亮屏 20 分")
eq("rowSub ui", F.rowSub({ kind: "ui", cpu_s: 405 }, R0), "处理器忙 7 分钟")
eq("rowSub ui null cpu", F.rowSub({ kind: "ui", cpu_s: null }, R0), "")
eq("rowSub floor", F.rowSub({ kind: "floor" }, R0), "")
eq("splitLine", F.splitLine(app), "在前台时 9% · 在后台时 3%（其中熄屏 2%）")
eq("splitLine no off", F.splitLine({ split: { fg: 9, bg: 3, off: 0 }, split_raw: { fg: 9.1, bg: 3.2, off: 0 } }),
   "在前台时 9% · 在后台时 3%")
eq("splitLine <1", F.splitLine({ split: { fg: 0, bg: 1, off: 0 }, split_raw: { fg: 0.2, bg: 0.6, off: 0.1 } }),
   "在前台时 <1% · 在后台时 1%（其中熄屏 <1%）")
eq("splitLine component", F.splitLine({ split: null, split_raw: null }), "")
eq("facts app", J(F.facts(app)), [["前台使用", "1 小时 20 分"], ["后台开着", "6 小时"], ["处理器忙", "7 分钟"],
                                  ["图形芯片忙", "1 分钟"], ["熄屏时醒来", "约 3.4 万次"]])
eq("facts sparse", J(F.facts({ fg_s: null, bg_s: null, cpu_s: 60, gpu_s: null, wake_off_n: 12 })),
   [["处理器忙", "1 分钟"], ["熄屏时醒来", "12 次"]])
eq("facts null", J(F.facts(null)), [])
eq("bannerText", F.bannerText([{ text: "a" }, { text: "b" }]), "a；b")
eq("bannerText empty", F.bannerText([]), "")

// ---------------------------------------------------------------- chart: state and curve

const B = { on: [[10, 20]], charger: [[30, 40]], gap: [[50, 60]], uncovered: [] }
eq("stateAt before data_from", F.stateAt(3, B, 5), "")
eq("stateAt on", F.stateAt(15, B, 5), "亮屏")
eq("stateAt on end is open", F.stateAt(20, B, 5), "熄屏")
eq("stateAt charger", F.stateAt(35, B, 5), "插电")
eq("stateAt gap", F.stateAt(55, B, 5), "没记录")
eq("stateAt off", F.stateAt(25, B, null), "熄屏")
eq("stateAt gap beats on", F.stateAt(55, { on: [[50, 60]], charger: [], gap: [[50, 60]] }, null), "没记录")

const C = [[0, 100], [10, 90], [10, 95], [20, 85]]
eq("interp mid", F.interp(C, 5), 95)
eq("interp jump takes later", F.interp(C, 10), 95)
eq("interp after jump", F.interp(C, 15), 90)
eq("interp before", F.interp(C, -1), 100)
eq("interp after", F.interp(C, 30), 85)
eq("interp empty", F.interp([], 3), null)
eq("readout", F.readout(T, 64.4, "亮屏", 480), "30日 08:11 · 64% · 亮屏")
eq("readout gap", F.readout(T, null, "没记录", 480), "30日 08:11 · 没记录")
eq("readout no state", F.readout(T, 64.6, "", -300), "29日 19:11 · 65%")

let s = J(F.splitCurve([[0, 100], [100, 90], [200, 95], [300, 80]],
                       { on: [], charger: [[100, 200]], gap: [], uncovered: [] }))
eq("splitCurve charger", s, { line: [[[0, 100], [100, 90]], [[200, 95], [300, 80]]],
                              charge: [[[100, 90], [200, 95]]], gap: [] })
s = J(F.splitCurve([[0, 100], [150, 90], [250, 80], [300, 75]],
                   { on: [], charger: [], gap: [[150, 250]], uncovered: [] }))
eq("splitCurve gap", s, { line: [[[0, 100], [150, 90]], [[250, 80], [300, 75]]], charge: [],
                          gap: [[[150, 90], [250, 80]]] })
s = J(F.splitCurve([[0, 100], [100, 90], [100, 95], [200, 85]], { on: [], charger: [], gap: [] }))
eq("splitCurve jump stays", s, { line: [[[0, 100], [100, 90], [100, 95], [200, 85]]], charge: [], gap: [] })
s = J(F.splitCurve([[0, 100], [200, 80]], { on: [], charger: [[50, 100]], gap: [] }))
eq("splitCurve cut inside a segment", s, { line: [[[0, 100], [50, 95]], [[100, 90], [200, 80]]],
                                           charge: [[[50, 95], [100, 90]]], gap: [] })
eq("splitCurve one point", J(F.splitCurve([[0, 50]], { on: [], charger: [], gap: [] })),
   { line: [], charge: [], gap: [] })

const H = J(F.hatch(100, 140, 4, 300, 8))
ok("hatch has lines", H.length > 0)
ok("hatch inside slab and 45 deg", H.every(([[x0, y0], [x1, y1]]) =>
    x0 >= 100 - 1e-9 && x1 <= 140 + 1e-9 && y0 <= 300 + 1e-9 && y1 >= 4 - 1e-9 &&
    Math.abs((y0 - y1) - (x1 - x0)) < 1e-6 && x1 > x0), JSON.stringify(H.slice(0, 3)))
const H2 = J(F.hatch(140, 180, 4, 300, 8))
// every line is x + y = bottom + k * step, so two neighbouring slabs continue the same stripes
const onGrid = (x, y) => { const m = (((x + y - 300) % 8) + 8) % 8; return m < 1e-6 || 8 - m < 1e-6 }
ok("hatch shares the global grid", H.concat(H2).every(([[x0, y0], [x1, y1]]) => onGrid(x0, y0) && onGrid(x1, y1)))
eq("hatch empty", J(F.hatch(10, 10, 0, 10, 8)), [])

eq("dashes", J(F.dashes(0, 0, 20, 0, 6, 4)), [[[0, 0], [6, 0]], [[10, 0], [16, 0]]])
eq("dashes partial last", J(F.dashes(0, 0, 22, 0, 6, 4)), [[[0, 0], [6, 0]], [[10, 0], [16, 0]], [[20, 0], [22, 0]]])
eq("dashes zero length", J(F.dashes(5, 5, 5, 5, 6, 4)), [])

eq("subtract", J(F.subtract(0, 100, [[50, 60], [10, 20]])), [[0, 10], [20, 50], [60, 100]])
eq("subtract edge bands", J(F.subtract(0, 100, [[-5, 10], [90, 120]])), [[10, 90]])
eq("subtract all", J(F.subtract(0, 100, [[0, 100]])), [])
eq("subtract none", J(F.subtract(0, 100, [])), [[0, 100]])

const seg = J(F.segments([50, 30, 20, 0.01], 912, 2, 2))
eq("segments count", seg.length, 4)
ok("segments end at width", seg[3].x + seg[3].w === 912, JSON.stringify(seg))
ok("segments gaps", seg.every((b, i) => i === 0 || b.x === seg[i - 1].x + seg[i - 1].w + 2), JSON.stringify(seg))
ok("segments min width", seg.every((b) => b.w >= 2), JSON.stringify(seg))
ok("segments proportional", Math.abs(seg[0].w / seg[1].w - 50 / 30) < 0.05, JSON.stringify(seg))
eq("segments empty", J(F.segments([], 912, 2, 2)), [])

// ---------------------------------------------------------------- tick grids on the canned reports

const canned = path.join(here, "..", "..", "..", "..", "dock", "tests", "batpage")
const files = fs.readdirSync(canned).filter((f) => f.endsWith(".json")).sort()
// gen_batpage.py FILES: a new canned state is added here too, so a stray or missing file shows
ok("canned reports found", files.join(",") === ["all_charger", "degraded", "empty", "first_run", "just_full", "ok",
                                                "partial"].map((f) => f + ".json").join(","), files.join(","))
const docs = Object.fromEntries(files.map((f) => [f, JSON.parse(fs.readFileSync(path.join(canned, f), "utf8"))]))

for (const [f, d] of Object.entries(docs)) {
    const tz = d.tz_offset_min
    for (const key of ["since_full", "24h", "7d"]) {
        const r = d.ranges[key]
        const ticks = J(F.tickTimes(r.start, r.end, tz))
        const span = r.end - r.start
        ok(`${f} ${key} ticks exist`, ticks.length >= 1)
        ok(`${f} ${key} ticks inside`, ticks.every((t) => t >= r.start && t <= r.end), JSON.stringify(ticks))
        if (span > 36 * 3600)
            ok(`${f} ${key} ticks on local midnights`, ticks.every((t) => (t + tz * 60) % 86400 === 0) && ticks.length <= 8)
        else if (span >= 600)
            ok(`${f} ${key} ticks at most 6`, ticks.length <= 6, String(ticks.length))
    }
}
eq("ok.json 24h ticks every 6 h", J(F.tickTimes(docs["ok.json"].ranges["24h"].start, docs["ok.json"].ranges["24h"].end, 480))
    .map((t) => F.clock(t, 480)), ["12:00", "18:00", "00:00", "06:00"])
eq("ok.json 7d ticks", J(F.tickTimes(docs["ok.json"].ranges["7d"].start, docs["ok.json"].ranges["7d"].end, 480))
    .map((t) => F.tick(t, 7 * 86400, 480)), ["24日", "25日", "26日", "27日", "28日", "29日", "30日"])
eq("tickTimes tiny range", J(F.tickTimes(1000, 1030, 0)), [1000, 1030])

// ---------------------------------------------------------------- report sentences from the canned files

eq("empty.json 7d line 3", F.summaryLine3(docs["empty.json"].ranges["7d"]),
   "亮屏 4 分 · 熄屏 不到 1 分 · 亮灭不明 152 小时 10 分 · 插电 15 小时 46 分")
ok("all_charger line 3 only plugged", /^插电 [^·]+$/.test(F.summaryLine3(docs["all_charger.json"].ranges.since_full)),
   F.summaryLine3(docs["all_charger.json"].ranges.since_full))

// ---------------------------------------------------------------- text widths (rough), both orientations

const CJK = /[⺀-鿿豈-﫿＀-｠　-〿]/
function adv(ch) {
    if (CJK.test(ch)) return 1.0
    if (/[0-9]/.test(ch)) return 0.57
    if (/[A-Z]/.test(ch)) return 0.66
    if (/[a-z]/.test(ch)) return 0.54
    if (ch === " ") return 0.26
    if (ch === "%") return 0.86
    if (ch === "·") return 0.5            // CJK fonts may draw U+00B7 wider than Latin ones; assume the wide one
    if (ch === "‹" || ch === "›") return 0.4
    if (ch === "‑") return 0.36
    return 0.5
}
function width(text, px, bold = false) {
    let w = 0
    for (const ch of String(text)) w += adv(ch)
    return w * px * (bold ? 1.05 : 1)
}
// greedy wrap: CJK breaks anywhere, Latin runs and digits break only at spaces
function lines(text, px, room, bold = false) {
    const tokens = String(text).match(/[A-Za-z0-9%.()（）\-_]+|\s|./gu) || []
    let n = 1, cur = 0
    for (const t of tokens) {
        const w = width(t, px, bold)
        if (cur + w > room && cur > 0) {
            n++
            cur = t === " " ? 0 : w
        } else {
            cur += w
        }
    }
    return n
}

const FOOT = "怎么算的：总耗电是电池实测；屏幕估得较准，各应用只适合看谁多谁少（可能差三到五成）；插着充电器的时间不算。"
const L = { name: "横屏", colW: 912, lineRoom: 912 - 192, listW: 528, rowW: 552, plotW: 864, detailRoom: 846 }
const P = { name: "竖屏", colW: 938, lineRoom: 938 - 192, listW: 938, rowW: 962, plotW: 890 }

for (const [f, d] of Object.entries(docs)) {
    const tz = d.tz_offset_min
    const b = d.battery
    for (const O of [L, P]) {
        const where = `${f} ${O.name}`
        const big = width((b.pct === null ? "–" : b.pct + "%"), 72)
        if (big > 180)
            notes.push(`${where}: 大数字 ${Math.round(big)} px > 180, Summary 用 HorizontalFit 缩小`)
        // the file's own remain, and the same hours on the past-day basis (should a canned file carry another basis_h)
        for (const rem of d.remain ? [d.remain, { h: d.remain.h, basis_h: 24 }] : [null]) {
            const l1 = F.statusLine(b.status, b.plugged, rem)
            ok(`${where} summary line 1 fits`, width(l1, 22) <= O.lineRoom, `${l1} ${Math.round(width(l1, 22))}`)
        }
        const health = [b.health_pct !== null ? `电池健康 ${b.health_pct}%` : null,
                        b.cycles !== null ? `充放电 ${b.cycles} 次` : null].filter(Boolean).join(" · ")
        ok(`${where} health row fits`, width(health, 22) + width("KDE 电量页 ›", 22) + 16 <= O.colW, health)

        for (const key of ["since_full", "24h", "7d"]) {
            const r = d.ranges[key]
            const w = `${where} ${key}`
            ok(`${w} sub fits`, width(r.sub, 18) <= O.lineRoom, `${r.sub} ${Math.round(width(r.sub, 18))}`)
            const l3 = F.summaryLine3(r)
            ok(`${w} line 3 fits`, width(l3, 18) <= O.lineRoom, `${l3} ${Math.round(width(l3, 18))}`)

            const fl = lines(FOOT + r.footnote, 18, O.colW)
            ok(`${w} 说明 at most 2 lines`, fl <= 2, String(fl))

            if (O === L && r.banners.length) {
                const bt = F.bannerText(r.banners)
                if (width(bt, 18) > O.colW - 15)
                    notes.push(`${w}: 横幅一行放不下，末尾省略（第 6 节允许）: ${bt}`)
            }
            if (O === P)
                for (const bn of r.banners)
                    ok(`${w} banner at most 2 lines`, lines(bn.text, 18, O.colW - 15) <= 2, bn.text)

            // time axis: neighbouring labels must not touch
            const ticks = J(F.tickTimes(r.start, r.end, tz))
            const span = r.end - r.start
            for (let i = 1; i < ticks.length; i++) {
                const gap = (ticks[i] - ticks[i - 1]) / span * O.plotW
                const lw = Math.max(width(F.tick(ticks[i], span, tz), 16), width(F.tick(ticks[i - 1], span, tz), 16))
                ok(`${w} tick labels apart`, gap >= lw + 8, `${Math.round(gap)} < ${Math.round(lw + 8)}`)
            }

            // composition legend: wraps at most once and stays above the 说明 at y 812 (landscape). Composition.qml's
            // Flow: spacing 0, each entry swatch 10 + 6 + text + its 16 px right padding (checked below), so lines
            // are 24 px apart and an entry wraps when it, padding included, passes the column
            if (r.composition.length) {
                const entries = r.composition.map((c) =>
                    10 + 6 + width(`${c.name} ${F.pct(c.pct, c.pct_raw)}`, 16) + 16)
                let n = 1, cur = 0
                for (const e of entries) {
                    if (cur > 0 && cur + e > O.colW) { n++; cur = e } else cur += e
                }
                ok(`${w} legend at most 2 lines`, n <= 2, String(n))
                if (O === L)
                    ok(`${w} legend above 说明`, 688 + 72 + 24 * n <= 812, `${n} lines end at ${688 + 72 + 24 * n}`)
                if (n > 1)
                    notes.push(`${w}: 去向图例折成 ${n} 行`)
            }

            if (r.data_from_text && r.items.length)
                ok(`${w} data_from_text fits`, width(r.data_from_text, 18) <= O.listW, r.data_from_text)

            if (r.empty) {
                const h = 30 + 12 + 28 * lines(r.empty.text, 18, O.listW) + (r.empty.action === "show_24h" ? 12 + 64 : 0)
                ok(`${w} empty block fits the list area`, O !== L || h <= 846 - 80, String(h))
            }

            const maxPct = Math.max(0, ...r.items.map((it) => it.pct_raw))
            for (const it of r.items) {
                const pw = width(F.pct(it.pct, it.pct_raw), 24)
                const room = O.rowW - 12 - 60 - 12 - pw - 16
                ok(`${w} row name fits: ${it.name}`, width(it.name, 22, true) <= room, `${Math.round(width(it.name, 22, true))} > ${Math.round(room)}`)
                const sub = F.rowSub(it, r)
                ok(`${w} row sub fits: ${it.name}`, width(sub, 18) <= room, sub)
                ok(`${w} share bar within 468`, O !== L || it.pct_raw / maxPct * (O.rowW - 24 - 60) <= 468 + 1e-9)

                // detail content height (landscape column is 846 high; the portrait page scrolls)
                const dw = O === L ? O.listW : O.colW
                ok(`${w} detail name fits: ${it.name}`, width(it.name, 30, true) <= dw - 80, it.name)
                ok(`${w} detail 约用掉 fits`, width(`约用掉 ${F.pct(it.pct, it.pct_raw)} 电量`, 44) <= dw)
                const sl = F.splitLine(it)
                ok(`${w} detail split fits: ${it.name}`, width(sl, 20) <= dw, `${sl} ${Math.round(width(sl, 20))}`)
                let h = 56 + 80 + 72 + (sl ? 32 : 0)
                if (it.explain) h += 16 + 30 * lines(it.explain, 20, dw)
                if (it.hint) h += 12 + 30 * lines(it.hint, 20, dw)
                const facts = J(F.facts(it))
                if (facts.length) h += 16 + 56 * facts.length
                if (it.note) h += 16 + 28 * lines(it.note, 18, dw)
                if (it.windows.length) h += 8 + 56 * it.windows.length
                if (it.parts.length) h += 16 + 56 * it.parts.length
                for (const [label, value] of facts)
                    ok(`${w} fact row fits`, width(label, 20) + 16 + width(value, 22) <= dw, label + value)
                for (const [name, sec] of it.windows)
                    ok(`${w} window row fits: ${name}`, width(name, 20) + 16 + width(F.dur(sec), 22) <= dw, name)
                for (const [name, v] of it.parts)
                    ok(`${w} part row fits: ${name}`, width(name, 20) + 16 + width(F.pctRaw(v), 22) <= dw, name)
                if (O === L && h > O.detailRoom)
                    notes.push(`${w}: 「${it.name}」的详情 ${h} px，超过右栏 846，详情里会滚动`)
            }
            if (O === L && r.items.length * 76 > 846 - 80)
                notes.push(`${w}: 列表 ${r.items.length} 行，右栏放得下 ${Math.floor((846 - 80) / 76)} 行，列表滚动`)
        }
    }
}

// ---------------------------------------------------------------- QML geometry the checks above rely on

const qml = (f) => fs.readFileSync(path.join(here, "..", "qml", f), "utf8")
// the legend wrap model: a Flow's spacing also separates its lines, so the 16 px gap is each entry's padding
const flow = qml("Composition.qml").split("Flow {")[1] || ""
ok("Composition legend Flow has no spacing", /^\s*spacing: 0$/m.test(flow.split("Repeater")[0]))
ok("Composition legend entry pads 16 px on the right", /delegate: Row \{[^}]*\n\s*rightPadding: 16\n/.test(flow))
// the curve ends at `end`, on the plot's right edge (x = width): the layer must clip its round cap there
const shape = qml("Chart.qml").split("Shape {")[1] || ""
ok("Chart curve layer ends at the plot's right edge", /^\s*width: chart\.width$/m.test(shape.split("ShapePath")[0]))

// the read-out chip flips to the left of the line near the right edge; the longest text must fit one side
const longest = "30日 23:59 · 100% · 没记录"
ok("read-out chip fits half the plot", width(longest, 18) + 24 + 12 <= L.plotW / 2)

for (const n of [...new Set(notes)])
    console.log("note: " + n)
for (const m of failures)
    console.log("FAIL: " + m)
console.log(`${passed} passed, ${failures.length} failed`)
process.exit(failures.length ? 1 : 0)
