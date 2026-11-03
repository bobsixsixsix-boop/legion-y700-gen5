"""contract.validate() against the canned page JSONs and hand-broken variants of them.

The canned files (linux/dock/tests/batpage/*.json) feed the page test bed; if they stop being
valid, the page is being tested against data the report can never produce.
Run: python -X utf8 -m unittest discover -s linux/power/battery/report/tests -t linux/power/battery/report
"""

import copy
import importlib.util
import json
import math
import sys
import unittest
from pathlib import Path

REPORT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPORT))

from y700_battery import contract  # noqa: E402

BATPAGE = REPORT.parents[2] / "dock" / "tests" / "batpage"
CANNED = ("ok", "just_full", "empty", "first_run", "partial", "all_charger", "degraded")

# Icon= values seen in the tablet's .desktop files (bp-capture desktop-files.txt, 10-30); app
# items in the canned files may only use these, so the test bed shows real icons.
CAPTURE_ICONS = {
    "google-chrome", "claude-desktop", "steam-arm64", "cn.xfangfang.wiliwili",
    "com.moonlight_stream.Moonlight", "org.kde.dolphin", "org.telegram.desktop",
    "utilities-terminal", "okular", "mpv", "chatgpt", "steam_icon_4242421", "steam_icon_4242431",
    "battery", "application-x-executable",
}


def load(name):
    with open(BATPAGE / (name + ".json"), encoding="utf-8") as f:
        return json.load(f)


def item(doc, rng, kind=None, iid=None):
    for it in doc["ranges"][rng]["items"]:
        if (kind is None or it["kind"] == kind) and (iid is None or it["id"] == iid):
            return it
    raise KeyError((rng, kind, iid))


class CannedFiles(unittest.TestCase):
    def test_all_present_and_valid(self):
        names = sorted(p.stem for p in BATPAGE.glob("*.json"))
        self.assertEqual(names, sorted(CANNED))
        for name in CANNED:
            with self.subTest(name=name):
                errs = contract.validate(load(name))
                self.assertEqual(errs, [], "\n".join(errs[:20]))

    def test_lf_only(self):
        for name in CANNED:
            raw = (BATPAGE / (name + ".json")).read_bytes()
            self.assertNotIn(b"\r", raw, name)

    def test_states_match_file_names(self):
        st = {n: {k: r["state"] for k, r in load(n)["ranges"].items()} for n in CANNED}
        self.assertEqual(st["ok"], {"since_full": "ok", "24h": "ok", "7d": "ok"})
        self.assertEqual(st["just_full"]["since_full"], "just_full")
        self.assertEqual(set(st["empty"].values()), {"empty"})
        self.assertEqual(set(st["first_run"].values()), {"empty"})
        self.assertEqual(set(st["partial"].values()), {"partial"})
        self.assertEqual(set(st["all_charger"].values()), {"all_charger"})
        self.assertEqual(st["degraded"], {"since_full": "empty", "24h": "empty", "7d": "partial"})

    def test_ok_has_the_promised_rows(self):
        names = {it["name"] for it in load("ok")["ranges"]["since_full"]["items"]}
        for want in ("屏幕", "Google Chrome", "Claude", "Steam", "wiliwili", "Moonlight",
                     "Dolphin 文件管理器", "系统界面", "系统后台", "基本耗电（开着机就有）",
                     "没算清的部分"):
            self.assertIn(want, names)
        kinds = {it["kind"] for it in load("ok")["ranges"]["since_full"]["items"]}
        self.assertTrue({"wifi", "apps_rest"} <= kinds)
        steam = item(load("ok"), "since_full", iid="app:steam-arm64")
        self.assertIn("示例游戏(Sample)", [w[0] for w in steam["windows"]])

    def test_partial_has_gap_degraded_and_late_start(self):
        r = load("partial")["ranges"]["since_full"]
        self.assertTrue(r["bands"]["gap"])
        self.assertGreaterEqual(r["gap_s"], 4 * 3600)
        self.assertIsNotNone(r["data_from"])
        self.assertEqual([b["kind"] for b in r["banners"]], ["degraded", "gap"])
        self.assertGreater(len(r["bands"]["uncovered"]), 1)

    def test_first_run_marks_where_the_screen_became_known(self):
        # one start snapshot, screen off, nothing itemised: no 亮屏 band, all unitemised, data_from at the snapshot
        d = load("first_run")
        for key, r in d["ranges"].items():
            with self.subTest(key=key):
                self.assertEqual((r["bands"]["on"], r["on_s"], r["data_from"]), ([], 0, d["rec"]["since"]))
                self.assertTrue(r["start"] < r["data_from"] < r["end"])
                self.assertEqual(r["bands"]["uncovered"][-1], [r["bands"]["uncovered"][-1][0], r["end"]])
                self.assertLessEqual(r["bands"]["uncovered"][-1][0], r["data_from"])
                self.assertEqual(r["empty"]["title"], "刚开始记录")

    def test_generator_reproduces_the_files(self):
        # batpage/gen_batpage.py makes them: an edit by hand would drift from the timeline the rest agrees with
        spec = importlib.util.spec_from_file_location("gen_batpage", BATPAGE / "gen_batpage.py")
        gen = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gen)
        got = gen.render()
        self.assertEqual(sorted(got), sorted(CANNED))
        for name in CANNED:
            with self.subTest(name=name):
                self.assertEqual((BATPAGE / (name + ".json")).read_text(encoding="utf-8"), got[name])

    def test_app_icons_exist_on_the_tablet(self):
        for name in CANNED:
            for r in load(name)["ranges"].values():
                for it in r["items"]:
                    if it["kind"] == "app":
                        self.assertIn(it["icon"], CAPTURE_ICONS, (name, it["id"]))

    def test_week_looks_like_a_week(self):
        r = load("ok")["ranges"]["7d"]
        self.assertGreaterEqual(len(r["bands"]["charger"]), 4)   # about one charge per 1.5 days
        self.assertGreaterEqual(len(r["bands"]["on"]), 40)
        self.assertLessEqual(len(r["curve"]), contract.MAX_CURVE)
        lows = min(p for _, p in r["curve"])
        self.assertLess(lows, 30)


class ErrorDoc(unittest.TestCase):
    def test_error_shape(self):
        self.assertEqual(contract.validate({"v": 1, "error": "账本读不了"}), [])
        self.assertTrue(contract.is_error({"v": 1, "error": "x"}))
        self.assertTrue(contract.validate({"v": 1, "error": ""}))
        self.assertTrue(contract.validate({"v": 1, "error": "x", "now": 1}))
        self.assertTrue(contract.validate({"v": 2, "error": "x"}))
        self.assertTrue(contract.validate([]))
        self.assertTrue(contract.validate(None))


class Broken(unittest.TestCase):
    """Each mutation must be rejected, with a message that names the problem."""

    def check(self, base, mutate, expect):
        doc = copy.deepcopy(load(base))
        mutate(doc)
        errs = contract.validate(doc)
        self.assertTrue(errs, f"{base}: mutation accepted")
        self.assertTrue(any(expect in e for e in errs), f"{expect!r} not in {errs[:8]}")

    def test_pct_sum(self):
        def m(d):
            item(d, "since_full", kind="screen")["pct"] += 1
        self.check("ok", m, "pct sum")

    def test_largest_remainder_order(self):
        def m(d):
            r = d["ranges"]["since_full"]
            s = sum(it["pct_raw"] for it in r["items"])
            q = [it["pct_raw"] * r["used_pct"] / s for it in r["items"]]
            up = [i for i, it in enumerate(r["items"]) if it["pct"] > q[i] + 0.05]
            down = [i for i, it in enumerate(r["items"]) if it["pct"] < q[i] - 0.05]
            # take the rounded-up item with the largest remainder and give its +1 to the
            # rounded-down item with the smallest remainder
            i = max(up, key=lambda k: q[k] - math.floor(q[k]))
            j = min(down, key=lambda k: q[k] - math.floor(q[k]))
            r["items"][i]["pct"] -= 1
            r["items"][j]["pct"] += 1
        self.check("ok", m, "largest-remainder")

    def test_pct_raw_sum(self):
        def m(d):
            item(d, "24h", kind="floor")["pct_raw"] += 1.5
        self.check("ok", m, "pct_raw sum")

    def test_used_pct_rounding(self):
        def m(d):
            d["ranges"]["24h"]["used_pct_raw"] = d["ranges"]["24h"]["used_pct"] + 0.6
        self.check("ok", m, "round-half-up")

    def test_curve_too_long(self):
        def m(d):
            r = d["ranges"]["7d"]
            t0, t1 = r["start"], r["end"]
            r["curve"] = [[t0 + (t1 - t0) * i // 450, 50.0] for i in range(451)]
        self.check("ok", m, "points > 400")

    def test_curve_two_decimals(self):
        def m(d):
            d["ranges"]["24h"]["curve"][3][1] = 55.55
        self.check("ok", m, "more than one decimal")

    def test_curve_goes_back_in_time(self):
        def m(d):
            c = d["ranges"]["24h"]["curve"]
            c[4][0], c[5][0] = c[5][0], c[4][0]
        self.check("ok", m, "non-decreasing")

    def test_curve_out_of_range(self):
        def m(d):
            d["ranges"]["24h"]["curve"][0][0] -= 3600
        self.check("ok", m, "outside the range")

    def test_24h_bucket_count(self):
        def m(d):
            r = d["ranges"]["24h"]
            r["bucket_t"] = r["bucket_t"][1:]
            for it in r["items"]:
                it["buckets"] = it["buckets"][1:]
        self.check("ok", m, "24 buckets")

    def test_7d_bucket_alignment(self):
        def m(d):
            r = d["ranges"]["7d"]
            r["bucket_t"] = [t + 3600 for t in r["bucket_t"]]
        self.check("ok", m, "local midnight")

    def test_since_full_bucket_not_smallest(self):
        def m(d):
            r = d["ranges"]["since_full"]
            bs = 7200
            off = d["tz_offset_min"] * 60
            first = (r["start"] + off) // bs * bs - off
            n = (r["end"] - 1 + off) // bs - (r["start"] + off) // bs + 1
            r["bucket_s"], r["bucket_t"] = bs, [first + bs * i for i in range(n)]
            for it in r["items"]:
                b = it["buckets"]
                it["buckets"] = [round(sum(b[2 * i:2 * i + 2]), 3) for i in range(n)]
        self.check("ok", m, "use the smallest size")

    def test_item_bucket_sum(self):
        def m(d):
            item(d, "since_full", kind="screen")["buckets"][10] += 2.0
        self.check("ok", m, "buckets: sum")

    def test_bool_is_not_int(self):
        def m(d):
            d["ranges"]["since_full"]["model_high_segments"] = True
        self.check("ok", m, "expected int")

    def test_unknown_key(self):
        def m(d):
            d["ranges"]["7d"]["remain_h"] = 9.2
        self.check("ok", m, "unknown keys remain_h")

    def test_missing_key(self):
        def m(d):
            del d["ranges"]["7d"]["footnote"]
        self.check("ok", m, "missing keys footnote")

    def test_bad_state(self):
        def m(d):
            d["ranges"]["7d"]["state"] = "stale"
        self.check("ok", m, "not one of")

    def test_just_full_outside_since_full(self):
        def m(d):
            r = d["ranges"]["24h"]
            r["state"] = "just_full"
        self.check("ok", m, "just_full only exists")

    def test_empty_with_items(self):
        row = load("ok")["ranges"]["since_full"]["items"][0]

        def m(d):
            d["ranges"]["since_full"]["items"] = [copy.deepcopy(row)]
        self.check("empty", m, "must be empty in state empty")

    def test_empty_block_required(self):
        def m(d):
            d["ranges"]["24h"]["empty"] = None
        self.check("all_charger", m, "expected object")

    def test_show_24h_only_for_just_full(self):
        def m(d):
            d["ranges"]["24h"]["empty"]["action"] = "show_24h"
        self.check("empty", m, "show_24h exactly when")

    def test_partial_without_unrecorded(self):
        def m(d):
            r = d["ranges"]["since_full"]
            r["items"] = [it for it in r["items"] if it["kind"] != "unrecorded"]
        self.check("partial", m, "partial needs the unrecorded item")

    def test_ok_with_uncovered_time(self):
        def m(d):
            d["ranges"]["since_full"]["state"] = "ok"
        self.check("partial", m, "ok has no unrecorded item")

    def test_coverage_vs_unrecorded(self):
        def m(d):
            d["ranges"]["since_full"]["coverage"] = 0.99
        self.check("partial", m, "(1 - coverage)")

    def test_banner_order(self):
        def m(d):
            b = d["ranges"]["since_full"]["banners"]
            b[0], b[1] = b[1], b[0]
        self.check("partial", m, "priority")

    def test_banner_level(self):
        def m(d):
            d["ranges"]["since_full"]["banners"][0]["level"] = "info"
        self.check("partial", m, "has level")

    def test_recorder_off_needs_banner(self):
        def m(d):
            d["rec"]["running"] = False
        self.check("ok", m, "recorder_off banner required")

    def test_charger_banner_follows_plugged(self):
        def m(d):
            d["battery"]["plugged"] = False
            d["battery"]["status"] = "discharging"
        self.check("all_charger", m, "charger_now banner exactly when")

    def test_status_implies_plugged(self):
        def m(d):
            d["battery"]["plugged"] = False
        self.check("all_charger", m, "implies plugged")

    def test_remain_while_plugged(self):
        def m(d):
            d["remain"] = {"h": 9.0, "basis_h": 3}
        self.check("all_charger", m, "null while plugged")

    def test_band_overlap(self):
        def m(d):
            on = d["ranges"]["24h"]["bands"]["on"]
            on[1][0] = on[0][1] - 60
        self.check("ok", m, "non-overlapping")

    def test_band_outside(self):
        def m(d):
            r = d["ranges"]["since_full"]
            r["bands"]["on"][0][0] = r["start"] - 600
        self.check("ok", m, "outside range")

    def test_gap_over_charger(self):
        def m(d):
            r = d["ranges"]["7d"]
            a, b = r["bands"]["charger"][0]
            r["bands"]["gap"] = sorted(r["bands"]["gap"] + [[a + 60, a + 120]])
            r["gap_s"] += 60
        self.check("partial", m, "gap overlaps")

    def test_band_seconds(self):
        def m(d):
            d["ranges"]["7d"]["charger_s"] += 3600
        self.check("ok", m, "charger_s")

    def test_seconds_exceed_span(self):
        def m(d):
            d["ranges"]["24h"]["off_s"] += 7200
        self.check("ok", m, "> span")

    def test_split_sum(self):
        def m(d):
            item(d, "7d", iid="app:google-chrome")["split"]["fg"] += 1
        self.check("ok", m, "fg+bg")

    def test_split_null_for_components(self):
        def m(d):
            item(d, "7d", kind="ui")["split"] = {"fg": 1, "bg": 0, "off": 0}
        self.check("ok", m, "must be null for ui")

    def test_small_app_not_merged(self):
        def m(d):
            r = d["ranges"]["since_full"]
            tg = item(d, "since_full", iid="app:org.telegram.desktop")
            delta = tg["pct_raw"] - 0.4
            tg["pct_raw"] = 0.4
            tg["split_raw"]["bg"] = round(tg["split_raw"]["bg"] - delta, 2)
            r["items"][0]["pct_raw"] = round(r["items"][0]["pct_raw"] + delta, 2)
        self.check("ok", m, "must be merged into apps_rest")

    def test_apps_rest_name_count(self):
        def m(d):
            item(d, "since_full", kind="apps_rest")["name"] = "其他应用"
        self.check("ok", m, "carry its count")

    def test_sorted_items(self):
        def m(d):
            it = d["ranges"]["7d"]["items"]
            it[0], it[1] = it[1], it[0]
        self.check("ok", m, "not sorted")

    def test_composition_order(self):
        def m(d):
            c = d["ranges"]["since_full"]["composition"]
            c[0], c[1] = c[1], c[0]
        self.check("ok", m, "kinds must follow")

    def test_composition_vs_items(self):
        def m(d):
            c = d["ranges"]["since_full"]["composition"]
            c[0]["pct_raw"] += 1.0
            c[-1]["pct_raw"] -= 1.0
        self.check("ok", m, "!= items sum")

    def test_fixed_windows(self):
        def m(d):
            d["ranges"]["24h"]["start"] += 60
        self.check("ok", m, "exactly [now - 86400, now]")

    def test_data_from_pairs(self):
        def m(d):
            d["ranges"]["since_full"]["data_from_text"] = None
        self.check("partial", m, "both null or both set")

    def test_app_time_exceeds_discharge(self):
        # apps_rest bg_s as a sum of members' bg_s counted the same seconds once per app
        def m(d):
            r = d["ranges"]["24h"]
            item(d, "24h", kind="apps_rest")["bg_s"] = r["on_s"] + r["off_s"]
        self.check("ok", m, "fg_s + bg_s")

    def test_component_icon(self):
        def m(d):
            item(d, "since_full", kind="screen")["icon"] = "display"
        self.check("ok", m, "uses icon")

    def test_role(self):
        def m(d):
            item(d, "since_full", kind="sys")["role"] = "accent"
        self.check("ok", m, "has role")

    def test_hint_only_on_screen(self):
        def m(d):
            item(d, "since_full", kind="floor")["hint"] = "x"
        self.check("ok", m, "only the screen item has a hint")

    def test_windows_only_on_apps(self):
        def m(d):
            item(d, "since_full", kind="ui")["windows"] = [["KWin", 10]]
        self.check("ok", m, "only app items have windows")

    def test_coeffs_date(self):
        def m(d):
            d["coeffs"]["date"] = "10-30"
        self.check("ok", m, "YYYY-MM-DD")

    def test_diag_missing(self):
        def m(d):
            del d["diag"]["energy_age_s"]
        self.check("ok", m, "missing keys energy_age_s")

    def test_range_end_after_now(self):
        def m(d):
            d["now"] -= 60
        self.check("ok", m, "after now")


class NeverRaises(unittest.TestCase):
    """validate() must report, not crash, whatever garbage a field holds."""

    JUNK = (None, "x", "", 1.5, -1, True, [], {}, [[1]], {"a": 1})

    def test_range_fields(self):
        base = load("ok")
        for key in contract.RANGE_FIELDS:
            for junk in self.JUNK:
                doc = copy.deepcopy(base)
                doc["ranges"]["since_full"][key] = junk
                with self.subTest(key=key, junk=junk):
                    self.assertIsInstance(contract.validate(doc), list)

    def test_item_fields(self):
        base = load("partial")
        for key in contract.ITEM_FIELDS:
            for junk in self.JUNK:
                doc = copy.deepcopy(base)
                doc["ranges"]["24h"]["items"][2][key] = junk
                with self.subTest(key=key, junk=junk):
                    errs = contract.validate(doc)
                    self.assertIsInstance(errs, list)

    def test_top_fields(self):
        base = load("all_charger")
        for key in contract.TOP_KEYS:
            for junk in self.JUNK:
                doc = copy.deepcopy(base)
                doc[key] = junk
                with self.subTest(key=key, junk=junk):
                    self.assertIsInstance(contract.validate(doc), list)


if __name__ == "__main__":
    unittest.main()
