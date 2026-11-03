// Offscreen test bed for fixes of the 10-31 audit, built apart from the page (../CMakeLists.txt does not know this
// directory, install.sh does not build it):
//   A1  report.cpp: a refresh that fails after a good report dims that report (stale) with its age by the report's
//       own "now", and the same error once more notifies again, so 「x 分钟前」 is counted anew - without dataChanged
//   A6  UsageList.qml (through UsageListBed.qml): a refresh with as many rows keeps the landscape list where it was
//       scrolled to; another range goes back to the top
// Build and run on the tablet (any user; QT_QPA_PLATFORM is forced to offscreen, nothing shows on the screen):
//   cmake -S linux/power/battery/page/tests -B /tmp/bp-state-test && cmake --build /tmp/bp-state-test -j8
//   /tmp/bp-state-test/bp-state-test
// One PASS / FAIL line per check, exit 1 on any FAIL. On the page before the fix (224afab) exactly the checks marked
// "old: FAIL" fail and the others pass (README's checklist line for this bed greps that).
#include "report.h"
#include <QDateTime>
#include <QEventLoop>
#include <QFile>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMetaObject>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QTemporaryDir>
#include <QTimer>
#include <QUrl>
#include <QVariant>
#include <cstdio>
#include <memory>

namespace {

int failed = 0;

void check(bool ok, const char *what)
{
    std::printf("%s %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok) ++failed;
}

// the event loop for ms: the window's polish (the ListView lays out its rows there) and the bindings
void settle(int ms)
{
    QEventLoop loop;
    QTimer::singleShot(ms, &loop, &QEventLoop::quit);
    loop.exec();
}

bool put(const QString &path, const QByteArray &json)
{
    QFile f(path);
    return f.open(QIODevice::WriteOnly | QIODevice::Truncate) && f.write(json) == json.size();
}

// a report as the fixture file: only what loadFixture() and liveFromData() read
QByteArray goodReport(qint64 ageS)
{
    return "{\"v\":1,\"now\":" + QByteArray::number(QDateTime::currentSecsSinceEpoch() - ageS)
           + ",\"battery\":{\"pct\":50,\"status\":\"discharging\",\"plugged\":false}}";
}

// Y700_BATTERY_REPORT: refresh() reads the file again, a good report or an error document, the paths a real report
// takes through setData() / setError()
void backendChecks(const QString &dir)
{
    const QString file = dir + QStringLiteral("/report.json");
    qputenv("Y700_BATTERY_REPORT", QFile::encodeName(file));
    put(file, goodReport(330));
    Backend b{QString(), QString()}; // braces: with () this declares a function (most vexing parse)
    int data = 0, err = 0;
    QObject::connect(&b, &Backend::dataChanged, [&data] { ++data; });
    QObject::connect(&b, &Backend::errorChanged, [&err] { ++err; });
    b.start();
    check(!b.data().isEmpty() && b.error().isEmpty() && !b.stale(), "A1 a good report is shown, not dimmed");

    put(file, "{\"v\":1,\"error\":\"报表超时\"}");
    data = err = 0;
    b.refresh();
    check(b.error() == QStringLiteral("报表超时"), "A1 the failure is the error line");
    check(b.stale(), "A1 a failure after a good report dims that report (old: FAIL)");
    check(b.cacheAgeMin() == 5, "A1 its age is its own now: 5 min (old: FAIL, -1)");
    check(data == 0 && err == 1, "A1 the failure: errorChanged once, no dataChanged");
    b.refresh();
    check(err == 2 && data == 0, "A1 the same failure again notifies again, no dataChanged (old: FAIL)");

    put(file, goodReport(0));
    b.refresh();
    check(!b.stale() && b.error().isEmpty() && data == 1, "A1 a good report again: not dimmed");
    check(b.cacheAgeMin() == 0, "A1 its age is the new report's now: 0 min (old: FAIL, -1)");
}

QVariant call(QObject *o, const char *fn)
{
    QVariant r;
    QMetaObject::invokeMethod(o, fn, Q_RETURN_ARG(QVariant, r));
    return r;
}

QVariant call(QObject *o, const char *fn, const QVariant &a)
{
    QVariant r;
    QMetaObject::invokeMethod(o, fn, Q_RETURN_ARG(QVariant, r), Q_ARG(QVariant, a));
    return r;
}

// the canned ok.json (linux/dock/tests/batpage): since_full and 24h have 14 rows each, more than the 520 px column
void listChecks()
{
    QFile f(QStringLiteral(BED_DIR "/../../../../dock/tests/batpage/ok.json"));
    if (!f.open(QIODevice::ReadOnly)) {
        check(false, "A6 linux/dock/tests/batpage/ok.json readable");
        return;
    }
    const QVariantMap ranges =
        QJsonDocument::fromJson(f.readAll()).object().value(QStringLiteral("ranges")).toObject().toVariantMap();
    const QVariantMap since = ranges.value(QStringLiteral("since_full")).toMap();
    const QVariantMap day = ranges.value(QStringLiteral("24h")).toMap();
    // the same range refreshed: other numbers, as many rows
    QVariantMap since2 = since;
    QVariantList items = since2.value(QStringLiteral("items")).toList();
    for (QVariant &v : items) {
        QVariantMap m = v.toMap();
        m[QStringLiteral("pct_raw")] = m.value(QStringLiteral("pct_raw")).toDouble() / 2;
        v = m;
    }
    since2[QStringLiteral("items")] = items;

    QQmlEngine engine;
    QQmlComponent comp(&engine, QUrl::fromLocalFile(QStringLiteral(BED_DIR "/UsageListBed.qml")));
    std::unique_ptr<QObject> win(comp.create());
    if (!win) {
        std::printf("%s\n", qPrintable(comp.errorString()));
        check(false, "A6 UsageListBed.qml loads");
        return;
    }
    QObject *w = win.get();
    call(w, "setRange", since);
    settle(300);
    check(items.size() == 14 && call(w, "count").toInt() == 14, "A6 14 rows in since_full");
    call(w, "scrollTo", 300);
    settle(100);
    check(qAbs(call(w, "pos").toDouble() - 300) < 1, "A6 the list scrolled 300 px down");
    call(w, "setRange", since2);
    settle(300);
    check(qAbs(call(w, "pos").toDouble() - 300) < 1, "A6 a refresh with as many rows keeps the place (old: FAIL)");
    check(qAbs(call(w, "rowPct", 5).toDouble() - items.at(5).toMap().value(QStringLiteral("pct_raw")).toDouble()) < 1e-9,
          "A6 the rows show the refreshed numbers");
    call(w, "setRange", day);
    settle(300);
    check(qAbs(call(w, "pos").toDouble()) < 1, "A6 another range, as many rows, goes back to the top");
}

} // namespace

int main(int argc, char **argv)
{
    qputenv("QT_QPA_PLATFORM", "offscreen");       // never a window on the owner's screen
    // the software scene graph needs no GPU context offscreen
    if (qEnvironmentVariableIsEmpty("QT_QUICK_BACKEND")) qputenv("QT_QUICK_BACKEND", "software");
    QGuiApplication app(argc, argv);
    QTemporaryDir dir;
    if (!dir.isValid()) {
        std::printf("FAIL no temporary directory\n");
        return 1;
    }
    backendChecks(dir.path());
    listChecks();
    std::printf("%s (%d failed)\n", failed ? "FAILED" : "OK", failed);
    return failed ? 1 : 0;
}
