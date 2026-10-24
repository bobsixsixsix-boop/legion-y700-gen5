#include "fakekeys.h"
#include "fake-input-client-protocol.h"
#include <cstring>
#include <wayland-client.h>

struct FakeKeysRegistry {
    static void global(void *data, wl_registry *reg, uint32_t name, const char *iface, uint32_t version)
    {
        auto *self = static_cast<FakeKeys *>(data);
        if (!self->m_fake && strcmp(iface, org_kde_kwin_fake_input_interface.name) == 0 && version >= 4)
            self->m_fake = static_cast<org_kde_kwin_fake_input *>(wl_registry_bind(reg, name, &org_kde_kwin_fake_input_interface, 4));
    }
    static void remove(void *, wl_registry *, uint32_t) {}
};
static const wl_registry_listener kRegistry = {FakeKeysRegistry::global, FakeKeysRegistry::remove};

FakeKeys::~FakeKeys() { drop(); }

void FakeKeys::drop()
{
    if (m_fake) org_kde_kwin_fake_input_destroy(m_fake);
    if (m_reg) wl_registry_destroy(m_reg);
    if (m_dpy) wl_display_disconnect(m_dpy);
    m_fake = nullptr; m_reg = nullptr; m_dpy = nullptr;
}

bool FakeKeys::connect(QString *err)
{
    if (m_dpy && wl_display_get_error(m_dpy) == 0 && m_fake) return true;
    drop();
    m_dpy = wl_display_connect(nullptr);
    if (!m_dpy) { *err = "连不上 Wayland"; return false; }
    m_reg = wl_display_get_registry(m_dpy);
    wl_registry_add_listener(m_reg, &kRegistry, this);
    wl_display_roundtrip(m_dpy);
    // KWin hides a restricted global from clients that may not use it, so a missing one = no permission
    if (!m_fake) { *err = "KWin 不给 fake_input（桌面文件 y700-control-center.desktop？）"; drop(); return false; }
    org_kde_kwin_fake_input_authenticate(m_fake, "y700-control-center", "edge swipe = back key");
    wl_display_roundtrip(m_dpy);
    if (wl_display_get_error(m_dpy)) { *err = "fake_input 连接出错"; drop(); return false; }
    return true;
}

bool FakeKeys::chord(const QList<int> &keys, QString *err)
{
    if (keys.isEmpty() || !connect(err)) return false;
    for (int k : keys) org_kde_kwin_fake_input_keyboard_key(m_fake, k, WL_KEYBOARD_KEY_STATE_PRESSED);
    for (int i = keys.size() - 1; i >= 0; --i) org_kde_kwin_fake_input_keyboard_key(m_fake, keys[i], WL_KEYBOARD_KEY_STATE_RELEASED);
    if (wl_display_roundtrip(m_dpy) < 0) {
        // KWin went away under us: one retry on a fresh connection
        drop();
        if (!connect(err)) return false;
        for (int k : keys) org_kde_kwin_fake_input_keyboard_key(m_fake, k, WL_KEYBOARD_KEY_STATE_PRESSED);
        for (int i = keys.size() - 1; i >= 0; --i) org_kde_kwin_fake_input_keyboard_key(m_fake, keys[i], WL_KEYBOARD_KEY_STATE_RELEASED);
        if (wl_display_roundtrip(m_dpy) < 0) { *err = "fake_input 发送失败"; drop(); return false; }
    }
    return true;
}
