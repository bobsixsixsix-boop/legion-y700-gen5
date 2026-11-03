"""apps.py: unit names -> app ids, .desktop parsing with the dock's precedence, and ledger key -> app / ui / sys.

The index tests run on the real 10-30 desktop-files.txt (trimmed) with the real rules.json.
Run: tools/venv/Scripts/python -X utf8 -I -B -m unittest discover -s linux/power/battery/report/tests -t linux/power/battery/report
"""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

REPORT = Path(__file__).resolve().parents[1]
if str(REPORT) not in sys.path:
    sys.path.insert(0, str(REPORT))

from y700_battery import apps  # noqa: E402
from y700_battery.types import Rules  # noqa: E402

REAL = REPORT / "tests" / "fixtures" / "real-1030"
RULES_JSON = REPORT.parent / "rules.json"
HOME = "/home/user"


def load_rules(**over) -> Rules:
    """rules.json as types.Rules (config.py's job; kept local so these tests stand alone)"""
    d = json.loads(RULES_JSON.read_text(encoding="utf-8"))
    r = Rules()
    for k in ("aliases", "launcher_prefixes", "parents", "ui", "sys", "desktop_classes", "x11_classes", "hidden_ok"):
        setattr(r, k, d[k])
    r.labels = [(g, n) for g, n in d["labels"]]
    for k, v in over.items():
        setattr(r, k, v)
    return r


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def desktop(name, exec_, *extra, group="[Desktop Entry]"):
    return "\n".join([group, "Type=Application", "Name=" + name, "Exec=" + exec_, *extra]) + "\n"


class TestUnitNames(unittest.TestCase):
    def test_four_shapes(self):
        u = apps.unit_app_id
        # the dock's own scopes: app-y700-<id>-<pid>-<seq>
        self.assertEqual(u("app-y700-org.telegram.desktop-3315-12.scope"), "org.telegram.desktop")
        self.assertEqual(u("app-y700-dev.f-io.livi-3513-10.scope"), "dev.f-io.livi")
        self.assertEqual(u("app-y700-steam-arm64-3513-12.scope"), "steam-arm64")
        # XDG launches: app-<id>-<random>.scope and app-<id>@<random>.service
        self.assertEqual(u("app-com.anthropic.Claude-16803.scope"), "com.anthropic.Claude")
        self.assertEqual(u("app-com.google.Chrome-308129.scope"), "com.google.Chrome")
        self.assertEqual(u("app-cn.xfangfang.wiliwili@535c513efae94a458b5c587e32f70a4b.service"), "cn.xfangfang.wiliwili")
        self.assertEqual(u("app-CarPlay@f4bcd04b24dd42799cbede66c46f62ec.service"), "CarPlay")
        self.assertEqual(u("app-geoclue\\x2ddemo\\x2dagent@autostart.service"), "geoclue-demo-agent")
        # flatpak
        self.assertEqual(u("app-flatpak-org.telegram.desktop-3558488364.scope"), "org.telegram.desktop")
        # our helper units (resolved later by launcher_prefixes)
        self.assertEqual(u("app-steam-arm64-tri-restore-1700000000.service"), "steam-arm64-tri-restore")
        # with a slice in front, as ledger keys have it
        self.assertEqual(u("u/app.slice/app-y700-mpv-3513-2.scope"), "mpv")

    def test_not_apps(self):
        for n in ("y700-shellbar.service", "app.slice", "app-x.slice", "plasma-kwin_wayland.service", "app-.scope"):
            self.assertIsNone(apps.unit_app_id(n), n)

    def test_unescape(self):
        self.assertEqual(apps.unescape_unit("app-geoclue\\x2ddemo"), "app-geoclue-demo")
        self.assertEqual(apps.unescape_unit("a\\x2Db"), "a-b")
        self.assertEqual(apps.unescape_unit("\\xe7\\xa4\\xba\\xe4\\xbe\\x8b"), "示例")
        self.assertEqual(apps.unescape_unit("tray\\x20x.scope"), "tray x.scope")
        self.assertEqual(apps.unescape_unit("no\\xZZescape"), "no\\xZZescape")
        self.assertEqual(apps.unescape_unit("plain"), "plain")


class TestDesktopFiles(unittest.TestCase):
    def test_app_dirs(self):
        self.assertEqual(apps.app_dirs("/h"), ["/h/.local/share/applications", "/usr/local/share/applications",
                                               "/usr/share/applications", "/var/lib/flatpak/exports/share/applications",
                                               "/h/.local/share/flatpak/exports/share/applications",
                                               "/var/lib/snapd/desktop/applications", "/h/Desktop"])

    def test_parse(self):
        text = ("# comment\n"
                "[Desktop Entry]\n"
                "  Type = Application \n"
                "Name=Foo\n"
                "Name[zh]=福\n"
                "Name[zh_CN]=富\n"
                "Exec=foo --x\n"
                "Exec=foo %U\n"                      # later duplicate wins
                "Icon=/opt/foo/foo.png\n"
                "StartupWMClass=FooWin\n"
                "\n"
                "[Desktop Action new]\n"
                "Name=New window\n"
                "Exec=foo --new\n")
        e = apps.parse_desktop("/x/kde/foo.desktop", text)
        self.assertEqual((e.id, e.name, e.exec, e.icon, e.wmclass, e.visible, e.steam_appid),
                         ("foo", "富", "foo %U", "file:///opt/foo/foo.png", "FooWin", True, None))
        self.assertEqual(apps.parse_desktop("/x/kde/foo.desktop", text, id="kde-foo").id, "kde-foo")
        self.assertEqual(apps.parse_desktop("/x/a.desktop", desktop("A", "a", "Name[zh]=阿")).name, "阿")
        self.assertEqual(apps.parse_desktop("/x/a.desktop", "[Desktop Entry]\nExec=a\nType=Application\n").name, "a")
        self.assertIsNone(apps.parse_desktop("/x/a.desktop", "Name=A\nExec=a\n"))
        g = apps.parse_desktop("/x/g.desktop", desktop("示例游戏(Sample)", "steam steam://rungameid/4242421",
                                                       "Icon=steam_icon_4242421"))
        self.assertEqual((g.steam_appid, g.icon), (4242421, "steam_icon_4242421"))

    def test_visibility(self):
        def vis(*extra, exec_="a"):
            return apps.parse_desktop("/x/a.desktop", desktop("A", exec_, *extra)).visible

        self.assertTrue(vis())
        self.assertFalse(vis("NoDisplay=True"))
        self.assertFalse(vis("Hidden=true"))
        self.assertTrue(vis("NoDisplay=false"))
        self.assertFalse(vis(exec_=""))
        self.assertFalse(vis("Type=Link"))
        self.assertFalse(vis("OnlyShowIn=GNOME;"))
        self.assertTrue(vis("OnlyShowIn=GNOME;KDE;"))
        self.assertFalse(vis("NotShowIn=KDE;"))
        self.assertTrue(vis("NotShowIn=GNOME;"))

    def test_scan_precedence(self):
        with tempfile.TemporaryDirectory() as h:
            d = [os.path.join(h, n) for n in ("local", "usrlocal", "usr", "flat", "Desktop")]
            write(os.path.join(d[0], "hidden.desktop"), desktop("Hidden local", "h", "NoDisplay=true"))
            write(os.path.join(d[2], "hidden.desktop"), desktop("Shown usr", "h"))
            write(os.path.join(d[0], "both.desktop"), desktop("Local copy", "b --local"))
            write(os.path.join(d[2], "both.desktop"), desktop("System copy", "b"))
            write(os.path.join(d[2], "kde", "sub.desktop"), desktop("Sub", "s"))
            write(os.path.join(d[2], "notes.txt"), "x")
            write(os.path.join(d[3], "dev.f-io.livi.desktop"), desktop("CarPlay", "/usr/local/bin/y700-carplay",
                                                                         "StartupWMClass=dev.f-io.livi"))
            write(os.path.join(d[4], "My Car.desktop"), desktop("My Car", "/usr/local/bin/y700-carplay"))
            write(os.path.join(d[4], "Other.desktop"), desktop("Other", "other"))
            entries = apps.scan(d + [os.path.join(h, "missing")])
            idx = apps.AppIndex(entries, load_rules(aliases={}))
        self.assertEqual([e.id for e in entries], ["both", "hidden", "both", "hidden", "kde-sub", "dev.f-io.livi",
                                                   "My Car", "Other"])
        # a hidden copy in an earlier dir does not shadow a visible one further down; a visible one does
        self.assertEqual(idx.get("hidden").name, "Shown usr")
        self.assertEqual(idx.get("both").name, "Local copy")
        self.assertEqual(idx.get("kde-sub").name, "Sub")
        # a ~/Desktop launcher with the Exec of an app already found is that app
        self.assertIsNone(idx.get("My Car"))
        self.assertEqual(idx.by_class("My Car").id, "dev.f-io.livi")
        self.assertEqual(idx.lookup("my car")[0].id, "dev.f-io.livi")
        self.assertEqual(idx.get("Other").name, "Other")

    def test_capture_order(self):
        entries = apps.parse_capture((REAL / "desktop-files.txt").read_text(encoding="utf-8"))
        self.assertEqual(len(entries), 29)
        first = {}
        for e in entries:
            first.setdefault(e.id, e)
        # the capture lists /usr/share first; the dock reads ~/.local/share/applications first
        self.assertTrue(first["chatgpt"].path.startswith(HOME + "/.local/share/applications/"))
        self.assertTrue(first["cn.xfangfang.wiliwili"].path.startswith(HOME + "/.local/"))
        self.assertTrue(first["org.telegram.desktop"].path.startswith("/var/lib/flatpak/"))

    def test_capture_full_text(self):
        # 6b.b: a block may be the whole file; only its [Desktop Entry] group counts
        text = ("== /usr/share/applications/org.kde.konsole.desktop\n"
                "# comment\n"
                "[Desktop Entry]\n"
                "Type=Application\n"
                "Name=Konsole\n"
                "Exec=konsole\n"
                "\n"
                "[Desktop Action NewWindow]\n"
                "Name=Open a New Window\n"
                "Exec=konsole --new\n"
                "== /usr/share/applications/hidden.desktop\n"
                "[Desktop Entry]\n"
                "Type=Application\n"
                "Name=H\n"
                "Exec=h\n"
                "NoDisplay=true\n")
        e = apps.parse_capture(text)
        self.assertEqual([(x.id, x.name, x.exec, x.visible) for x in e],
                         [("org.kde.konsole", "Konsole", "konsole", True), ("hidden", "H", "h", False)])


class TestIndex(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rules = load_rules()
        cls.idx = apps.AppIndex(apps.parse_capture((REAL / "desktop-files.txt").read_text(encoding="utf-8")),
                                cls.rules)

    def r(self, key, **kw):
        x = self.idx.resolve(key, **kw)
        return x.kind, x.id, x.via

    def test_entries(self):
        i = self.idx
        self.assertIsNone(i.get("kcm_mobile_power"))         # NoDisplay
        self.assertIsNone(i.get("com.google.Chrome"))        # hidden in both copies
        self.assertTrue(i.get("google-chrome").path.startswith(HOME + "/.local/"))
        self.assertEqual(i.get("org.kde.dolphin").name, "Dolphin 文件管理器")
        self.assertEqual(i.get("systemsettings").name, "系统设置")    # OnlyShowIn=KDE
        self.assertEqual(i.get("dev.f-io.livi").icon, "file:///opt/livi-10.0.0/livi.png")
        self.assertEqual(i.get("示例游戏(Sample)").steam_appid, 4242421)
        hidden = apps.AppIndex(apps.parse_capture((REAL / "desktop-files.txt").read_text(encoding="utf-8")),
                               load_rules(hidden_ok=["kcm_mobile_power"]))
        self.assertEqual(hidden.get("kcm_mobile_power").name, "电量")

    def test_apps(self):
        A = "u/app.slice/"
        self.assertEqual(self.r(A + "app-y700-com.anthropic.Claude-3513-9.scope"), ("app", "com.anthropic.Claude", "exact"))
        self.assertEqual(self.r(A + "app-com.anthropic.Claude-16803.scope"), ("app", "com.anthropic.Claude", "exact"))
        self.assertEqual(self.r(A + "app-com.google.Chrome-308129.scope"), ("app", "google-chrome", "alias"))
        self.assertEqual(self.r(A + "app-CarPlay@f4bcd04b24dd42799cbede66c46f62ec.service"),
                         ("app", "dev.f-io.livi", "alias"))
        self.assertEqual(self.r(A + "app-y700-dev.f-io.livi-3513-10.scope"), ("app", "dev.f-io.livi", "exact"))
        self.assertEqual(self.r(A + "app-cn.xfangfang.wiliwili@535c513efae94a458b5c587e32f70a4b.service"),
                         ("app", "cn.xfangfang.wiliwili", "exact"))
        self.assertEqual(self.r(A + "app-y700-mpv-3513-2.scope"), ("app", "mpv", "exact"))
        x = self.idx.resolve(A + "app-CarPlay@x.service")
        self.assertEqual((x.name, x.icon), ("CarPlay", "file:///opt/livi-10.0.0/livi.png"))

    def test_flatpak_and_dock_merge(self):
        a = self.r("u/app.slice/app-flatpak-org.telegram.desktop-3558488364.scope")
        b = self.r("u/app.slice/app-y700-org.telegram.desktop-3315-12.scope")
        self.assertEqual(a, ("app", "org.telegram.desktop", "exact"))
        self.assertEqual(b, a)

    def test_launcher_prefixes(self):
        self.assertEqual(self.r("u/app.slice/app-steam-arm64-tri-restore-1700000000.service"),
                         ("app", "steam-arm64", "prefix"))
        self.assertEqual(self.r("u/app.slice/app-steam-arm64-relaunch-1700000001.service"),
                         ("app", "steam-arm64", "prefix"))
        # an XDG launcher in front of the id (app-<launcher>-<id>-<random>), and a known id with a suffix
        self.assertEqual(self.r("u/app.slice/app-org.kde.krunner-org.kde.dolphin-1234.scope"),
                         ("app", "org.kde.dolphin", "prefix"))
        self.assertEqual(self.r("u/app.slice/app-org.kde.konsole\\x2dhelper-abc.scope"),
                         ("app", "org.kde.konsole", "prefix"))

    def test_dock_wildcard(self):
        # apps.cpp makes every char outside letters / digits / _ . - into '_', systemd then escapes non-ASCII
        game = "app-y700-\\xe7\\xa4\\xba\\xe4\\xbe\\x8b\\xe6\\xb8\\xb8\\xe6\\x88\\x8f_Sample_-3513-14.scope"
        self.assertEqual(apps.unit_app_id(game), "示例游戏_Sample_")
        self.assertEqual(self.r("u/app.slice/" + game), ("app", "示例游戏(Sample)", "exact"))
        self.assertEqual(self.r("u/app.slice/app-y700-Sample_Drone_Demo-3513-20.scope"),
                         ("app", "Sample Drone Demo", "exact"))
        # only dock units get the wildcard
        self.assertEqual(self.r("u/app.slice/app-Sample_Drone_Demo-123.scope")[0], "sys")

    def test_classes(self):
        i = self.idx
        self.assertEqual(i.by_class("steam_app_4242421").id, "示例游戏(Sample)")
        self.assertEqual(i.by_class("steam_app_4242431").name, "Sample Drone Demo")
        self.assertIsNone(i.by_class("steam_app_1"))
        self.assertEqual(i.by_class("steam").id, "steam-arm64")              # StartupWMClass
        self.assertEqual(i.by_class("TelegramDesktop").id, "org.telegram.desktop")
        self.assertEqual(i.by_class("konsole").id, "org.kde.konsole")
        self.assertEqual(i.by_class("CarPlay").id, "dev.f-io.livi")         # rules alias
        self.assertIsNone(i.by_class(""))
        self.assertIsNone(i.by_class("NoSuchWindow"))
        self.assertEqual(i.window_name("steam_app_4242421"), "示例游戏(Sample)")
        self.assertEqual(i.window_name("dolphin", "~ — Dolphin"), "Dolphin 文件管理器")
        self.assertEqual(i.window_name("NoSuchWindow", "A title"), "A title")
        self.assertEqual((i.window_name("NoSuchWindow"), i.window_name(None)), ("NoSuchWindow", ""))
        self.assertTrue(i.is_desktop_class("") and i.is_desktop_class("plasmashell") and i.is_desktop_class(None))
        self.assertFalse(i.is_desktop_class("dolphin"))
        self.assertTrue(i.is_x11("steam_app_42") and i.is_x11("setup.exe") and i.is_x11("steam"))
        self.assertFalse(i.is_x11("dolphin") or i.is_x11("") or i.is_x11(None))

    def test_fg_classes(self):
        k = "u/app.slice/app-y700-unknownthing-3513-30.scope"
        self.assertEqual(self.r(k), ("sys", "其他后台服务", "default"))
        self.assertEqual(self.r(k, alive=False), ("closed", apps.CLOSED_ID, "default"))
        self.assertEqual(self.r(k, fg_classes=["TelegramDesktop"]), ("app", "org.telegram.desktop", "wmclass"))
        self.assertEqual(self.r(k, fg_classes=["dolphin"]), ("app", "org.kde.dolphin", "wmclass"))
        self.assertEqual(self.r(k, fg_classes=["steam_app_4242421"]), ("app", "示例游戏(Sample)", "wmclass"))
        x = self.idx.resolve(k, fg_classes=["plasmashell", "Some Window"])
        self.assertEqual((x.kind, x.id, x.name, x.icon, x.via), ("app", "class:Some Window", "Some Window", None, "fg"))
        self.assertEqual(self.r(k, alive=False, fg_classes=["", "plasmashell"]), ("closed", apps.CLOSED_ID, "default"))

    def test_ui_sys(self):
        self.assertEqual(self.r("u/app.slice/y700-shellbar.service"), ("ui", "状态栏和程序坞", "rule"))
        self.assertEqual(self.r("u/app.slice/app-org.fcitx.Fcitx5-1234.scope"), ("ui", "输入法", "rule"))
        self.assertEqual(self.r("u/session.slice/plasma-kwin_wayland.service"), ("ui", "窗口合成（KWin）", "rule"))
        self.assertEqual(self.r(apps.XWAYLAND), ("ui", "X11 兼容层（Xwayland）", "rule"))
        self.assertEqual(self.r("s/NetworkManager.service"), ("sys", "网络（NetworkManager、wpa_supplicant）", "rule"))
        self.assertEqual(self.r("/"), ("sys", "内核与中断", "rule"))
        self.assertEqual(self.r("-k"), ("sys", "内核与中断", "rule"))
        self.assertEqual(self.r("l/session-c1.scope"), ("sys", "登录会话", "rule"))
        self.assertEqual(self.r("u/app.slice/y700-refresh-auto.service"), ("sys", "我们自己的后台服务", "rule"))
        # systemd's \x2d stays in the key; the rules glob is written for it
        self.assertEqual(self.r("u/app.slice/app-geoclue\\x2ddemo\\x2dagent@autostart.service"),
                         ("sys", "其他后台服务", "rule"))
        self.assertEqual(self.r("/system.slice"), ("sys", "其他后台服务", "rule"))
        x = self.idx.resolve("u/app.slice")
        self.assertEqual((x.kind, x.id, x.name), ("closed", apps.CLOSED_ID, apps.CLOSED_NAME))

    def test_label(self):
        self.assertEqual(self.idx.label("s/y700-flightrec.service"), "我们自己的后台服务")
        bare = apps.AppIndex([], load_rules(labels=[]))
        self.assertEqual(bare.label("s/foo.service"), "foo.service")
        self.assertEqual(bare.resolve("s/foo.service").name, "foo.service")


if __name__ == "__main__":
    unittest.main()
