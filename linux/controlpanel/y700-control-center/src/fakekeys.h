// Key presses for the "back" edge gesture, through KWin's org_kde_kwin_fake_input (version 4 has keyboard_key).
// They go into KWin's input pipeline like a real keyboard's, so they reach the focused window and no uinput
// device has to appear first (a new device takes a while before libinput hands its first key to KWin).
// KWin allows the interface only to a client whose executable has a desktop file listing it in
// X-KDE-Wayland-Interfaces: install.sh writes /usr/local/share/applications/y700-control-center.desktop.
// Our own wl_display connection, not Qt's: nothing to share with Qt's event queue, and a dead connection
// (KWin restarted) is simply reopened on the next press.
#pragma once
#include <QList>
#include <QString>

struct wl_display;
struct wl_registry;
struct org_kde_kwin_fake_input;

class FakeKeys
{
public:
    ~FakeKeys();
    // press the keys in order, release them in reverse (evdev codes, e.g. {KEY_LEFTALT, KEY_LEFT})
    bool chord(const QList<int> &keys, QString *err);

private:
    bool connect(QString *err);
    void drop();
    wl_display *m_dpy = nullptr;
    wl_registry *m_reg = nullptr;
    org_kde_kwin_fake_input *m_fake = nullptr;
    friend struct FakeKeysRegistry;
};
