// The applications the dock and the app grid know: every .desktop file in the XDG application dirs (user first,
// then /usr/local, /usr, flatpak, snap) plus the ones only on the desktop (~/Desktop, e.g. CarPlay).
// Parsed here (no KService dev headers on the tablet; the [Desktop Entry] keys we need are few). Rescanned 2 s after
// any of those dirs changes. Pinned apps are a plain list of desktop ids in ~/.config/y700-shellbar/pinned.
// Launching runs the Exec line ourselves inside its own systemd scope (app-y700-<id>-<n>.scope, like Plasma's
// app-*.scope), so restarting y700-shellbar.service never takes a launched app down with it, and hands the new app
// an xdg-activation token so KWin raises it.
#pragma once
#include <QFileSystemWatcher>
#include <QObject>
#include <QStringList>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>

class QWindow;

class Apps : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QVariantList all READ all NOTIFY changed)            // [{id, name, icon, path, wmclass}], by name
    Q_PROPERTY(QVariantMap byKey READ byKey NOTIFY changed)          // lower-case id or StartupWMClass -> id
    Q_PROPERTY(QStringList pinned READ pinned NOTIFY pinnedChanged)
public:
    explicit Apps(QObject *parent = nullptr);
    QVariantList all() const { return m_all; }
    QVariantMap byKey() const { return m_byKey; }
    QStringList pinned() const { return m_pinned; }

    Q_INVOKABLE QVariantMap entry(const QString &id) const { return m_byId.value(id).toMap(); }
    Q_INVOKABLE void launch(const QString &id, QWindow *from);
    Q_INVOKABLE void togglePin(const QString &id);
    Q_INVOKABLE bool isPinned(const QString &id) const { return m_pinned.contains(id); }

Q_SIGNALS:
    void changed();
    void pinnedChanged();
    void launched(const QString &id);

private:
    void scan();
    void loadPinned();
    void savePinned();
    void exec(const QVariantMap &e, const QString &token);

    QVariantList m_all;
    QVariantMap m_byId, m_byKey;
    QStringList m_pinned;
    QFileSystemWatcher m_watch;
    QTimer m_rescan;
    int m_seq = 0;
};
