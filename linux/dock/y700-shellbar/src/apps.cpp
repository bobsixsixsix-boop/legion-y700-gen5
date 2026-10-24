#include "apps.h"
#include <KWaylandExtras>
#include <QCollator>
#include <QCoreApplication>
#include <QDirIterator>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QPointer>
#include <QProcess>
#include <QSaveFile>
#include <QStandardPaths>
#include <QTextStream>
#include <QWindow>
#include <cstdio>

static QString home() { return QDir::homePath(); }
static QString pinnedFile() { return home() + "/.config/y700-shellbar/pinned"; }

// the default pins (the Plasma icontasks list the dock replaced, as in the mockup); only the ones installed
static const QStringList DEFAULT_PINNED = {"google-chrome", "com.anthropic.Claude", "org.telegram.desktop",
                                           "cn.xfangfang.wiliwili", "steam-arm64", "org.kde.dolphin"};

static QStringList appDirs()
{
    return {home() + "/.local/share/applications", "/usr/local/share/applications", "/usr/share/applications",
            "/var/lib/flatpak/exports/share/applications", home() + "/.local/share/flatpak/exports/share/applications",
            "/var/lib/snapd/desktop/applications"};
}

// [Desktop Entry] group only; values as written (no escapes beyond what Exec needs)
static QVariantMap parse(const QString &path, const QString &id)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return {};
    QTextStream in(&f);
    QHash<QString, QString> kv;
    bool inGroup = false;
    while (!in.atEnd()) {
        const QString line = in.readLine().trimmed();
        if (line.startsWith('[')) { inGroup = line == "[Desktop Entry]"; continue; }
        if (!inGroup || line.isEmpty() || line.startsWith('#')) continue;
        const int eq = line.indexOf('=');
        if (eq > 0) kv.insert(line.left(eq).trimmed(), line.mid(eq + 1).trimmed());
    }
    auto yes = [&](const char *k) { return kv.value(k).compare("true", Qt::CaseInsensitive) == 0; };
    if (kv.value("Type") != "Application" || yes("NoDisplay") || yes("Hidden") || kv.value("Exec").isEmpty()) return {};
    const QString only = kv.value("OnlyShowIn"), notIn = kv.value("NotShowIn");
    if (!only.isEmpty() && !only.split(';').contains("KDE")) return {};
    if (notIn.split(';').contains("KDE")) return {};
    QString name = kv.value("Name[zh_CN]");
    if (name.isEmpty()) name = kv.value("Name[zh]");
    if (name.isEmpty()) name = kv.value("Name");
    QString icon = kv.value("Icon");
    if (icon.startsWith('/')) icon = "file://" + icon;
    return {{"id", id}, {"name", name}, {"icon", icon}, {"path", path}, {"exec", kv.value("Exec")},
            {"terminal", yes("Terminal")}, {"workdir", kv.value("Path")}, {"wmclass", kv.value("StartupWMClass")}};
}

Apps::Apps(QObject *parent) : QObject(parent)
{
    m_rescan.setSingleShot(true);
    m_rescan.setInterval(2000);
    connect(&m_rescan, &QTimer::timeout, this, &Apps::scan);
    connect(&m_watch, &QFileSystemWatcher::directoryChanged, this, [this] { m_rescan.start(); });
    scan();
    loadPinned();
}

void Apps::scan()
{
    QVariantMap byId;
    QStringList dirs = appDirs();
    const QString desk = home() + "/Desktop";
    dirs << desk;
    // ~/Desktop holds copies of installed launchers under other ids (CarPlay.desktop = dev.f-io.livi.desktop):
    // one there with the Exec of an app already found is the same app, so the grid shows it once. Its id still
    // resolves (byKey alias) for a pinned list written before.
    QHash<QString, QString> idByExec;
    QHash<QString, QString> alias;
    for (const QString &d : dirs) {
        QDir dir(d);
        if (!dir.exists()) continue;
        if (!m_watch.directories().contains(d)) m_watch.addPath(d);
        // subdirectories make ids like kde-foo (the XDG rule); one level is all the tablet has
        QDirIterator it(d, {"*.desktop"}, QDir::Files, QDirIterator::Subdirectories);
        while (it.hasNext()) {
            const QString p = it.next();
            QString id = dir.relativeFilePath(p);
            id.chop(8);
            id.replace('/', '-');
            if (byId.contains(id)) continue;   // earlier dirs win (user's own copy over the system one)
            const QVariantMap e = parse(p, id);
            if (e.isEmpty()) continue;
            const QString exec = e.value("exec").toString();
            if (d == desk && idByExec.contains(exec)) {
                alias.insert(id.toLower(), idByExec.value(exec));
                continue;
            }
            byId.insert(id, e);
            if (!idByExec.contains(exec)) idByExec.insert(exec, id);
        }
    }
    QVariantList all;
    QVariantMap byKey;
    for (auto it = alias.cbegin(); it != alias.cend(); ++it) byKey.insert(it.key(), it.value());
    for (auto it = byId.cbegin(); it != byId.cend(); ++it) {
        const QVariantMap e = it.value().toMap();
        all << e;
        byKey.insert(it.key().toLower(), it.key());
        const QString wm = e.value("wmclass").toString().toLower();
        if (!wm.isEmpty() && !byKey.contains(wm)) byKey.insert(wm, it.key());
    }
    QCollator col(QLocale(QLocale::Chinese, QLocale::China));
    std::sort(all.begin(), all.end(), [&col](const QVariant &a, const QVariant &b) {
        return col.compare(a.toMap().value("name").toString(), b.toMap().value("name").toString()) < 0;
    });
    m_byId = byId; m_byKey = byKey; m_all = all;
    Q_EMIT changed();
}

void Apps::loadPinned()
{
    QFile f(pinnedFile());
    QStringList ids;
    if (f.open(QIODevice::ReadOnly)) {
        for (const QByteArray &l : f.readAll().split('\n')) {
            QString id = QString::fromUtf8(l).trimmed();
            if (id.isEmpty() || id.startsWith('#')) continue;
            if (!m_byId.contains(id)) id = m_byKey.value(id.toLower(), id).toString();   // a ~/Desktop copy's id
            if (!ids.contains(id)) ids << id;
        }
    } else {
        for (const QString &id : DEFAULT_PINNED)
            if (m_byId.contains(id)) ids << id;
    }
    m_pinned = ids;
    Q_EMIT pinnedChanged();
}

void Apps::savePinned()
{
    QDir().mkpath(QFileInfo(pinnedFile()).path());
    QSaveFile f(pinnedFile());
    if (!f.open(QIODevice::WriteOnly)) return;
    f.write("# y700-shellbar: the dock's pinned apps, one desktop id per line (the dock's app grid edits this)\n");
    for (const QString &id : m_pinned) f.write(id.toUtf8() + '\n');
    f.commit();
}

void Apps::togglePin(const QString &id)
{
    if (m_pinned.contains(id)) m_pinned.removeAll(id);
    else m_pinned << id;
    savePinned();
    Q_EMIT pinnedChanged();
}

void Apps::launch(const QString &id, QWindow *from)
{
    const QVariantMap e = m_byId.value(id).toMap();
    if (e.isEmpty()) { fprintf(stderr, "launch: no app %s\n", qPrintable(id)); return; }
    Q_EMIT launched(id);
    if (!from) { exec(e, {}); return; }
    // the token proves to KWin the launch came from a tap on us, so the new window gets raised and focused;
    // KWin answers at once, the timer only covers a lost answer
    auto *w = new QFutureWatcher<QString>(this);
    auto done = std::make_shared<bool>(false);
    auto go = [this, e, w, done](const QString &token) {
        if (*done) return;
        *done = true;
        exec(e, token);
        w->deleteLater();
    };
    connect(w, &QFutureWatcher<QString>::finished, this, [w, go] { go(w->future().isValid() && w->future().resultCount() ? w->future().result() : QString()); });
    QTimer::singleShot(500, this, [go] { go({}); });
    w->setFuture(KWaylandExtras::xdgActivationToken(from, id));
}

void Apps::exec(const QVariantMap &e, const QString &token)
{
    // Exec field codes: drop file/url placeholders (we open no file), %c name, %k path, %i icon dropped, %% = %
    QStringList args;
    for (QString a : QProcess::splitCommand(e.value("exec").toString())) {
        if (QStringList{"%f", "%F", "%u", "%U", "%d", "%D", "%n", "%N", "%v", "%m", "%i"}.contains(a)) continue;
        a.replace("%c", e.value("name").toString()).replace("%k", e.value("path").toString()).replace("%%", "%");
        args << a;
    }
    if (args.isEmpty()) return;
    if (e.value("terminal").toBool()) args = QStringList{"konsole", "-e"} + args;
    QString unit = e.value("id").toString();
    for (QChar &c : unit) if (!c.isLetterOrNumber() && c != '_' && c != '.' && c != '-') c = '_';
    unit = QString("app-y700-%1-%2-%3").arg(unit).arg(QCoreApplication::applicationPid()).arg(++m_seq);
    QStringList cmd = {"--user", "--scope", "--quiet", "--collect", "--slice=app.slice", "--unit=" + unit};
    cmd << "--" << args;
    QProcess p;
    // a scope runs the command in systemd-run's own process (it execs it), so the token goes in its environment.
    // The plain session environment, not ours: LayerShellQt::Shell::useLayerShell() put
    // QT_WAYLAND_SHELL_INTEGRATION=layer-shell into it (qputenv: /proc/self/environ does not show it), and a Qt
    // child inheriting that is a layer-shell surface (native: no title bar, nothing to close it with) or no window
    // at all (flatpak: no layer-shell plugin in the sandbox, "Could not load the Qt platform plugin wayland" -
    // Telegram from the dock, 10-22). QT_QPA_PLATFORM is our unit's. The control centre's childEnv() (backend.cpp)
    // drops the same two.
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    for (const char *k : {"QT_WAYLAND_SHELL_INTEGRATION", "QT_QPA_PLATFORM", "XDG_ACTIVATION_TOKEN", "DESKTOP_STARTUP_ID"}) env.remove(k);
    if (!token.isEmpty()) { env.insert("XDG_ACTIVATION_TOKEN", token); env.insert("DESKTOP_STARTUP_ID", token); }
    p.setProcessEnvironment(env);
    p.setProgram("systemd-run");
    p.setArguments(cmd);
    const QString wd = e.value("workdir").toString();
    p.setWorkingDirectory(wd.isEmpty() ? home() : wd);
    const bool ok = p.startDetached();
    fprintf(stderr, "launch %s: %s%s\n", qPrintable(e.value("id").toString()), qPrintable(args.join(' ')),
            ok ? (token.isEmpty() ? " (no token)" : "") : " FAILED to start");
}
