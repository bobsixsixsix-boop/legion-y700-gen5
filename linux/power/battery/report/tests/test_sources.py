"""sources.py: --from replay of a capture directory (6b.b layout) and the live reader with the system faked out.

Nothing here needs Linux: live mode runs against temporary stand-ins for /sys/class/power_supply, /var/lib/upower,
/run/y700-flightrec and the boot id, with busctl / journalctl replaced.
Run: tools/venv/Scripts/python -X utf8 -I -B -m unittest discover -s linux/power/battery/report/tests -t linux/power/battery/report
"""

import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPORT = Path(__file__).resolve().parents[1]
if str(REPORT) not in sys.path:
    sys.path.insert(0, str(REPORT))

from tests.fixtures import synth  # noqa: E402
from y700_battery import apps, journal, sources  # noqa: E402

REAL = REPORT / "tests" / "fixtures" / "real-1030"


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


class TestHelpers(unittest.TestCase):
    def test_battery_txt(self):
        kv, online = sources.parse_battery_txt((REAL / "sys" / "battery.txt").read_text(encoding="utf-8"))
        self.assertEqual((kv["status"], kv["capacity"], online), ("Discharging", "76", [0, 0, 0, 0]))
        b = sources.live_battery(kv, online)
        self.assertEqual((b.pct, b.status, b.plugged, b.charge_full_uah, b.charge_full_design_uah, b.cycles,
                          b.model_name), (76, "discharging", False, 8394000, 9000000, 18, None))

    def test_status_and_plugged(self):
        self.assertEqual([sources.status_of(s) for s in ("Not charging", "Full", "Charging", " discharging\n", "Weird",
                                                         None)],
                         ["not_charging", "full", "charging", "discharging", "unknown", "unknown"])
        lb = sources.live_battery
        self.assertTrue(lb({"status": "Not charging"}, []).plugged)
        self.assertTrue(lb({"status": "Full"}, []).plugged)
        self.assertTrue(lb({"status": "Discharging"}, [0, 1]).plugged)     # a supply says online
        self.assertFalse(lb({"status": "Discharging"}, [0]).plugged)
        b = lb({"capacity": "x", "model_name": "  "}, [])
        self.assertEqual((b.pct, b.model_name, b.status), (None, None, "unknown"))

    def test_battery_txt_type_and_scope(self):
        """a capture that also lists the supplies' type / scope drops what live mode drops: a peripheral's battery
        (scope Device, hid-input reports online 1 always) and any other Battery supply"""
        P = "/sys/class/power_supply/"
        text = ("status=Discharging\ncapacity=24\n"
                + P + "hid-aabbccddeeff-battery/online=1\n" + P + "hid-aabbccddeeff-battery/type=Battery\n"
                + P + "hid-aabbccddeeff-battery/scope=Device\n"
                + P + "ps-controller-battery-aabbcc/scope=Device\n" + P + "ps-controller-battery-aabbcc/online=1\n"
                + P + "qcom-battmgr-usb/online=0\n" + P + "qcom-battmgr-usb/type=USB\n"
                + P + "zz-second-bat/type=Battery\n" + P + "zz-second-bat/online=1\n"
                + P + "ucsi-source-psy-pmic_glink.ucsi.01/online=0\n")
        kv, online = sources.parse_battery_txt(text)
        self.assertEqual((kv, online), ({"status": "Discharging", "capacity": "24"}, [0, 0]))
        self.assertFalse(sources.live_battery(kv, online).plugged)
        # without type / scope lines every online counts (older captures)
        self.assertEqual(sources.parse_battery_txt(P + "a/online=1\n" + P + "b/online=0\n")[1], [1, 0])

    def test_energy(self):
        text = (REAL / "sys" / "energy").read_text(encoding="utf-8")
        f = sources.energy_fields(text)
        self.assertEqual((f["boot"], f["t"], f["lb"], f["pw"]), ("f8a52698", "0000113278473", "+000000000370", "dis"))
        self.assertAlmostEqual(sources.energy_age(text, 113280.0, "f8a52698"), 1.527, places=6)
        self.assertIsNone(sources.energy_age(text, 113280.0, "aaaa0001"))     # another boot's file
        self.assertIsNone(sources.energy_age(text, None, "f8a52698"))
        self.assertEqual(sources.energy_fields("v2 t=1\n"), {})
        self.assertEqual(sources.energy_fields(""), {})

    def test_state_dir(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(sources.state_dir_live({"XDG_STATE_HOME": d}, home="H"), os.path.join(d, "y700-battery"))
        exp = os.path.join("H", ".local", "state", "y700-battery")
        self.assertEqual(sources.state_dir_live({"XDG_STATE_HOME": "rel/state"}, home="H"), exp)
        self.assertEqual(sources.state_dir_live({}, home="H"), exp)

    def test_boot8(self):
        self.assertEqual(sources.boot8_of("F8A52698-ed09-4f88-ac85-05831ef0d880\n"), "f8a52698")
        self.assertIsNone(sources.boot8_of(None))
        self.assertIsNone(sources.boot8_of(""))

    def test_run(self):
        self.assertIsNone(sources._run(["y700-no-such-program-xyz"]))
        self.assertIsNone(sources._run([sys.executable, "-I", "-c", "import sys; sys.exit(3)"]))
        self.assertEqual(sources._run([sys.executable, "-I", "-c", "print('ok')"]).strip(), "ok")

    def test_read_stable(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "energy")
            write(p, "v1 boot=x t=1\n")
            self.assertEqual(sources._read_stable(p), "v1 boot=x t=1\n")
            self.assertIsNone(sources._read_stable(os.path.join(d, "nope")))


class TestFrom(unittest.TestCase):
    @unittest.skipUnless((REAL / "state").is_dir(), "tests/fixtures/real-1030 capture not present (not published)")
    def test_real_capture(self):
        opened = []
        real_read = sources._read

        def spy(path, limit=-1):
            opened.append(os.path.basename(path))
            return real_read(path, limit)

        with mock.patch.object(sources, "_read", spy):
            s = sources.open_sources(str(REAL), None, 480)
        self.assertEqual((s.from_dir, s.state_dir), (str(REAL), os.path.join(str(REAL), "state")))
        self.assertEqual((s.boot_id, s.mono_now, s.tz_offset_min), ("f8a52698", None, 480))
        # no now.txt: the newest wall time in the capture (the last UPower rate point)
        self.assertEqual(s.now, 1793315479.0)
        self.assertEqual((s.battery.pct, s.battery.status, s.battery.plugged), (76, "discharging", False))
        self.assertTrue(s.upower_charge_json.startswith('{"type":"a(udu)"'))
        self.assertTrue(s.upower_rate_json.startswith('{"type":"a(udu)"'))
        self.assertEqual(s.upower_dat, {})
        self.assertEqual(len(s.journal_lines), 47)
        self.assertEqual(len(s.desktop), 29)
        self.assertTrue(s.energy.startswith("v1 boot=f8a52698"))
        self.assertIsNone(s.energy_age_s)                   # no mono.txt
        self.assertEqual(s.edge.strip(), "v1 t=113168.5 dpms=Off pw=dis")
        self.assertEqual((s.rec_running, s.fg_dir_exists), (None, True))
        # the human-only files of a capture are never opened
        for n in ("upower-props.json", "user-env.txt", "qt-version.txt", "upower-files.txt", "apps-cpp-dirs.txt"):
            self.assertNotIn(n, opened)

    def test_full_layout(self):
        with tempfile.TemporaryDirectory() as d:
            synth.standard(os.path.join(d, "state"))
            write(os.path.join(d, "sys", "battery.txt"), "status=Not charging\ncapacity=80\n"
                                                         "/sys/class/power_supply/usb/online=1\n")
            write(os.path.join(d, "sys", "energy"), "v1 boot=dddd0004 t=0000000400000 n=1\n")
            write(os.path.join(d, "now.txt"), "1793060000.5\n")
            write(os.path.join(d, "mono.txt"), "500.25\n")
            write(os.path.join(d, "boot_id.txt"), "dddd0004-0000-4000-8000-dddd00040000\n")
            write(os.path.join(d, "tz-offset.txt"), "-300\n")
            write(os.path.join(d, "rec-running.txt"), "1\n")
            write(os.path.join(d, "upower-dat", "history-charge-BAT-33.dat"), "1793000000\t50.000\tdischarging\n")
            write(os.path.join(d, "upower-dat", "history-rate-BAT-33.dat"), "1793000000\t1.000\tdischarging\n")
            write(os.path.join(d, "upower-dat", "history-time-full-BAT-33.dat"), "1793000000\t1\tcharging\n")
            write(os.path.join(d, "journal-consumed.jsonl"), "")
            s = sources.open_sources(d, None, None)
        self.assertEqual((s.now, s.mono_now, s.tz_offset_min), (1793060000.5, 500.25, -300))
        self.assertEqual(s.boot_id, "dddd0004-0000-4000-8000-dddd00040000")
        self.assertEqual((s.battery.status, s.battery.plugged, s.battery.pct), ("not_charging", True, 80))
        self.assertEqual(sorted(s.upower_dat), ["history-charge-BAT-33.dat", "history-rate-BAT-33.dat"])
        self.assertIsNone(s.upower_charge_json)
        self.assertEqual((s.journal_lines, s.desktop, s.rec_running), ([], [], True))
        self.assertAlmostEqual(s.energy_age_s, 100.25, places=6)
        # explicit now / tz win over the capture's files
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "state"))
            write(os.path.join(d, "sys", "battery.txt"), "status=Full\n")
            write(os.path.join(d, "now.txt"), "1793060000.5\n")
            write(os.path.join(d, "rec-running.txt"), "maybe\n")
            s = sources.open_sources(d, 1.8e9, 60)
        self.assertEqual((s.now, s.tz_offset_min, s.rec_running), (1.8e9, 60, None))

    def test_empty_capture(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "state"))
            write(os.path.join(d, "sys", "battery.txt"), "")
            with mock.patch.object(sources.time, "time", return_value=1.9e9):
                s = sources.open_sources(d, None, 480)
        self.assertEqual((s.now, s.boot_id, s.battery.status), (1.9e9, None, "unknown"))

    def test_missing_parts(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(FileNotFoundError) as e:
                sources.open_sources(d, None, 480)
            self.assertIn("state/", str(e.exception))
            os.makedirs(os.path.join(d, "state"))
            with self.assertRaises(FileNotFoundError) as e:
                sources.open_sources(d, None, 480)
            self.assertIn("battery.txt", str(e.exception))


class TestLive(unittest.TestCase):
    """_live() against stand-in system directories: which files and commands it reads, and nothing else"""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        t = self.tmp
        self.supply = os.path.join(t, "power_supply")
        bat = os.path.join(self.supply, "qcom-battmgr-bat")
        for k, v in (("type", "Battery"), ("status", "Charging"), ("capacity", "55"), ("charge_full", "8394000"),
                     ("charge_full_design", "9000000"), ("cycle_count", "18"), ("model_name", "Li ion 1.0"),
                     ("charge_counter", "SHOULD NOT BE READ"), ("power_now", "SHOULD NOT BE READ")):
            write(os.path.join(bat, k), v + "\n")
        write(os.path.join(self.supply, "usb", "type"), "USB\n")
        write(os.path.join(self.supply, "usb", "online"), "0\n")
        self.upower = os.path.join(t, "upower")
        write(os.path.join(self.upower, "history-charge-Li_ion_1_0-33.dat"), "1793000000\t55.000\tcharging\n")
        write(os.path.join(self.upower, "history-rate-Li_ion_1_0-33.dat"), "1793000000\t5.000\tcharging\n")
        write(os.path.join(self.upower, "history-charge-_org_bluez_hci0_dev_1.dat"), "1793000000\t90.000\tdischarging\n")
        self.flight = os.path.join(t, "flightrec")
        write(os.path.join(self.flight, "energy"), "v1 boot=f8a52698 t=0000000001000 n=1\n")
        write(os.path.join(self.flight, "edge"), "v1 t=1.0 dpms=On pw=chg\n")
        self.boot_id = os.path.join(t, "boot_id")
        write(self.boot_id, "f8a52698-ed09-4f88-ac85-05831ef0d880\n")
        self.apps = os.path.join(t, "apps")
        write(os.path.join(self.apps, "mpv.desktop"), "[Desktop Entry]\nType=Application\nName=mpv\nExec=mpv\n")
        self.state = os.path.join(t, "xdg-state")
        os.makedirs(os.path.join(self.state, "y700-battery"))
        self.calls = []
        self.opened = []

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _fake_run(self, answer):
        def run(argv):
            self.calls.append(list(argv))
            return answer(argv)
        return run

    def _open(self, answer):
        real_read = sources._read

        def spy(path, limit=-1):
            self.opened.append(path)
            return real_read(path, limit)

        env = {k: v for k, v in os.environ.items() if k != "XDG_RUNTIME_DIR"}
        env["XDG_STATE_HOME"] = self.state
        with mock.patch.multiple(sources, SUPPLY_DIR=self.supply, UPOWER_DIR=self.upower, FLIGHTREC_DIR=self.flight,
                                 BOOT_ID=self.boot_id, _run=self._fake_run(answer), _read=spy), \
                mock.patch.object(apps, "app_dirs", lambda home: [self.apps]), \
                mock.patch.dict(os.environ, env, clear=True):
            return sources.open_sources(None, 1793000000.0, 480)

    def test_live(self):
        hist = json.dumps({"type": "a(udu)", "data": [[[1793000100, 56.0, 1]]]})
        jl = json.dumps({"USER_UNIT": "x.service", "CPU_USAGE_NSEC": "1000", "_BOOT_ID": "f8a52698",
                         "__MONOTONIC_TIMESTAMP": "5", "MESSAGE_ID": journal.CONSUMED_ID})
        s = self._open(lambda argv: hist if argv[0] == "busctl" else jl + "\n")
        self.assertEqual((s.from_dir, s.now, s.tz_offset_min), (None, 1793000000.0, 480))
        self.assertEqual(s.boot_id, "f8a52698-ed09-4f88-ac85-05831ef0d880")
        self.assertEqual(s.state_dir, os.path.join(self.state, "y700-battery"))
        b = s.battery
        self.assertEqual((b.pct, b.status, b.plugged, b.model_name, b.cycles), (55, "charging", True, "Li ion 1.0", 18))
        obj = "/org/freedesktop/UPower/devices/battery_qcom_battmgr_bat"
        self.assertEqual(self.calls[0], ["journalctl", "--user", "-o", "json", "--no-pager",
                                         "MESSAGE_ID=" + journal.CONSUMED_ID, "--since=@%d" % (1793000000 - 40 * 86400)])
        self.assertEqual(self.calls[1:], [
            ["busctl", "--system", "--json=short", "call", "org.freedesktop.UPower", obj,
             "org.freedesktop.UPower.Device", "GetHistory", "suu", kind, "3456000", "0"] for kind in ("charge", "rate")])
        self.assertEqual((s.upower_charge_json, s.upower_rate_json), (hist, hist))
        # the battery's own .dat files only (model_name picks them); never the Bluetooth device's
        self.assertEqual(sorted(s.upower_dat), ["history-charge-Li_ion_1_0-33.dat", "history-rate-Li_ion_1_0-33.dat"])
        self.assertEqual(s.journal_lines, [jl])
        self.assertEqual([e.id for e in s.desktop], ["mpv"])
        self.assertTrue(s.energy.startswith("v1 boot=f8a52698"))
        self.assertEqual(s.edge, "v1 t=1.0 dpms=On pw=chg\n")
        self.assertIsNone(s.rec_running)                    # no XDG_RUNTIME_DIR
        self.assertTrue(s.fg_dir_exists)
        names = {os.path.basename(p) for p in self.opened}
        for forbidden in ("charge_counter", "power_now", "history-charge-_org_bluez_hci0_dev_1.dat"):
            self.assertNotIn(forbidden, names)
        self.assertFalse([p for p in self.opened if "debug" in p or "energy_model" in p or "qcom_stats" in p])

    def _supply(self, name, **files):
        for k, v in files.items():
            write(os.path.join(self.supply, name, k), v + "\n")

    def test_peripheral_battery_is_not_the_tablet(self):
        """a paired controller's / BT mouse's battery (type Battery, scope Device) sorts before qcom-battmgr-bat: it is
        neither the battery nor an online source, so the page, UPower and the .dat files all stay on the tablet's"""
        self._supply("qcom-battmgr-bat", status="Discharging", capacity="24")
        self._supply("hid-aabbccddeeff-battery", type="Battery", scope="Device", status="Discharging", capacity="60",
                     online="1", model_name="Xbox Wireless Controller")
        self._supply("ps-controller-battery-aabbcc", type="Battery", scope="Device", status="Charging",
                     capacity="40", online="1")
        write(os.path.join(self.upower, "history-charge-Xbox_Wireless_Controller-1.dat"), "1793000000\t60\tdischarging\n")
        s = self._open(lambda argv: None)
        b = s.battery
        self.assertEqual((b.pct, b.status, b.plugged, b.model_name), (24, "discharging", False, "Li ion 1.0"))
        obj = "/org/freedesktop/UPower/devices/battery_qcom_battmgr_bat"
        self.assertEqual([c[5] for c in self.calls if c[0] == "busctl"], [obj, obj])
        self.assertEqual(sorted(s.upower_dat), ["history-charge-Li_ion_1_0-33.dat", "history-rate-Li_ion_1_0-33.dat"])
        # the peripheral's own files are never read beyond its scope
        self.assertEqual({os.path.basename(p) for p in self.opened if "hid-aabb" in p}, {"scope"})
        # and the charger still counts once it is in
        self._supply("usb", online="1")
        self.assertTrue(self._open(lambda argv: None).battery.plugged)

    def test_battery_without_battmgr(self):
        """no qcom-battmgr-bat: the first System-scope (or scope-less) Battery by name; other Battery supplies and
        Device-scope supplies give no online"""
        shutil.rmtree(os.path.join(self.supply, "qcom-battmgr-bat"))
        self._supply("hid-aabbccddeeff-battery", type="Battery", scope="Device", capacity="60", online="1")
        self._supply("m-bat", type="Battery", scope="System", status="Discharging", capacity="33")
        self._supply("n-bat", type="Battery", status="Discharging", capacity="90", online="1")
        self._supply("o-dock", type="Mains", scope="Device", online="1")
        with mock.patch.object(sources, "SUPPLY_DIR", self.supply):
            b, name = sources._live_battery()
            self.assertEqual((name, b.pct, b.plugged), ("m-bat", 33, False))
            self._supply("p-mains", type="Mains", online="1")          # no scope file: System
            self.assertTrue(sources._live_battery()[0].plugged)
            shutil.rmtree(self.supply)
            self.assertEqual(sources._live_battery()[1], None)

    def test_commands_fail(self):
        s = self._open(lambda argv: None)
        self.assertEqual((s.upower_charge_json, s.upower_rate_json, s.journal_lines), (None, None, []))
        self.assertEqual(len(s.upower_dat), 2)              # the .dat files still give the history

    def test_recorder_running(self):
        with tempfile.TemporaryDirectory() as rt:
            with mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": rt}):
                self.assertFalse(sources._recorder_running())      # no pid file
                write(os.path.join(rt, "y700-battery", "pid"), "0\n")
                self.assertFalse(sources._recorder_running())
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertIsNone(sources._recorder_running())


if __name__ == "__main__":
    unittest.main()
