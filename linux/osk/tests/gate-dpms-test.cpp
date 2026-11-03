// gate-dpms-test: which DRM connectors the gate's screenOff() reads (10-31 audit osk A1). Runs
// Gate::panelDpms() on a fake /sys/class/drm in a temporary directory: the internal panel switched off by
// KWin when the keyboard started (enabled = disabled), an external monitor that was enabled then and has
// been unplugged since (dpms stuck at Off), an unused DP connector, the card itself (no dpms).
// Prints PASS/FAIL per check, exits 1 on a FAIL. Not built by default; on the tablet:
//   cd /usr/local/src/y700-osk && cmake --build build --target gate-dpms-test && build/gate-dpms-test
#include "../src/gate.h"

#include <QDir>
#include <QFile>
#include <QTemporaryDir>

#include <cstdio>

namespace {
void connector(const QDir &drm, const QString &name, const QByteArray &enabled, const QByteArray &dpms)
{
    drm.mkpath(name);
    auto put = [&](const QString &file, const QByteArray &text) {
        if (text.isEmpty()) return;
        QFile f(drm.filePath(name + QLatin1Char('/') + file));
        if (f.open(QIODevice::WriteOnly)) f.write(text);
    };
    put(QStringLiteral("enabled"), enabled);
    put(QStringLiteral("dpms"), dpms);
}

int bad = 0;
void check(const char *what, bool ok)
{
    std::printf("%s %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok) ++bad;
}
} // namespace

int main()
{
    QTemporaryDir tmp;
    if (!tmp.isValid()) { std::printf("FAIL no temporary directory\n"); return 1; }
    const QDir drm(tmp.path());
    connector(drm, QStringLiteral("card0"), {}, {});
    connector(drm, QStringLiteral("card0-DSI-1"), "disabled\n", "On\n");
    connector(drm, QStringLiteral("card0-DP-1"), "enabled\n", "Off\n");
    connector(drm, QStringLiteral("card0-DP-2"), "disabled\n", "On\n");

    const QStringList got = Gate::panelDpms(tmp.path());
    for (const QString &f : got) std::printf("  reads %s\n", qPrintable(QDir(tmp.path()).relativeFilePath(f)));
    check("the internal panel is read, though KWin had it switched off at start", got.contains(drm.filePath(QStringLiteral("card0-DSI-1/dpms"))));
    check("an unplugged external output (dpms Off for good) is not read", !got.contains(drm.filePath(QStringLiteral("card0-DP-1/dpms"))));
    check("only the panel", got.size() == 1);
    return bad ? 1 : 0;
}
