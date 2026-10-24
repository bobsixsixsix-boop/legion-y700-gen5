#include "hud.h"
#include <QFile>

Hud::Hud(QObject *parent) : QObject(parent)
{
    m_dir = qEnvironmentVariable("XDG_RUNTIME_DIR", QStringLiteral("/tmp"));
    m_kvPath = m_dir + QStringLiteral("/y700-hud.txt.kv");
    m_modePath = m_dir + QStringLiteral("/y700-hud.mode");
    m_settle.setSingleShot(true);
    m_settle.setInterval(60);
    connect(&m_settle, &QTimer::timeout, this, &Hud::reread);
    // the directory: every sample lands as a rename into it (and so does the file's removal); the mode file is
    // rewritten in place by y700-hud-toggle, so its own watch survives and fires for full <-> mini at once. Not
    // restarted by later events: a busy runtime directory must not hold the numbers back
    auto soon = [this] { if (!m_settle.isActive()) m_settle.start(); };
    connect(&m_watch, &QFileSystemWatcher::directoryChanged, this, soon);
    connect(&m_watch, &QFileSystemWatcher::fileChanged, this, soon);
    m_watch.addPath(m_dir);
    reread();
}

void Hud::watchMode()
{
    if (!m_watch.files().contains(m_modePath) && QFile::exists(m_modePath)) m_watch.addPath(m_modePath);
}

void Hud::reread()
{
    watchMode();
    bool on = false;
    QVariantMap kv;
    QFile f(m_kvPath);
    if (f.open(QIODevice::ReadOnly)) {
        on = true;
        const QList<QByteArray> lines = f.readAll().split('\n');
        for (const QByteArray &l : lines) {
            const int eq = l.indexOf('=');
            if (eq > 0) kv.insert(QString::fromUtf8(l.left(eq)), QString::fromUtf8(l.mid(eq + 1)).trimmed());
        }
    }
    QString mode = QStringLiteral("full");
    QFile m(m_modePath);
    if (m.open(QIODevice::ReadOnly) && m.readAll().trimmed() == "mini") mode = QStringLiteral("mini");
    if (on != m_on || mode != m_mode || kv != m_kv) {
        m_on = on; m_mode = mode; m_kv = kv;
        Q_EMIT changed();
    }
}
