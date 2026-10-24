// The game performance numbers for the status bar (10-22: the performance overlay moves onto the status bar):
// qml/HudLine.qml in an app, qml/HudWidget.qml on the desktop. The numbers are the game overlay's (linux/games/hud):
// its sampler, `y700-hud-overlay --sampler` (y700-hud-overlay.service), writes $XDG_RUNTIME_DIR/y700-hud.txt.kv on
// every sample (1 s with a game drawing, 6 s idle, nothing with the screen off) and y700-hud-toggle writes the step
// (full | mini) to y700-hud.mode. Nothing is sampled here: the runtime directory is watched (inotify; the sampler
// replaces the file by rename, so a watch on the file itself would be gone with the first sample) and the mode
// file too; one sample is four directory events (two tmp files, two renames), re-read once 60 ms after the first.
// `on` = the .kv file exists: the service's ExecStopPost and y700-hud-toggle off remove it. Not its age: the
// sampler writes nothing while the screen is off, and an age limit made the widget vanish in the dark and pop in
// a second after every wake (the old numbers until then are the lesser evil; a hung sampler would freeze them).
#pragma once
#include <QFileSystemWatcher>
#include <QObject>
#include <QTimer>
#include <QVariantMap>

class Hud : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool on READ on NOTIFY changed)          // the sampler is writing: show the line
    Q_PROPERTY(QString mode READ mode NOTIFY changed)   // "full" | "mini" (y700-hud.mode)
    Q_PROPERTY(QVariantMap kv READ kv NOTIFY changed)   // the sampler's key=value pairs (sampler.rs Kv::pairs)
public:
    explicit Hud(QObject *parent = nullptr);
    bool on() const { return m_on; }
    QString mode() const { return m_mode; }
    QVariantMap kv() const { return m_kv; }

Q_SIGNALS:
    void changed();

private:
    void reread();
    void watchMode();

    QString m_dir, m_kvPath, m_modePath;
    bool m_on = false;
    QString m_mode = QStringLiteral("full");
    QVariantMap m_kv;
    QFileSystemWatcher m_watch;
    QTimer m_settle;
};
