// ftouch: drive a (test) KWin with fake touch / keys over org_kde_kwin_fake_input, from a script on stdin.
// Only for the headless test KWin of linux/gesture/tests/ts-bed.sh: the live session refuses the
// interface to clients without the permission (KWIN_WAYLAND_NO_PERMISSION_CHECKS=1 there only).
//
//   d ID X Y     touch down (logical px)        m ID X Y   touch motion
//   u ID         touch up                        c          touch cancel
//   k KEY        key press + release (evdev code, e.g. 1 = Esc, 28 = Enter, 105/106 = left/right)
//   s MS         sleep                           # ...      comment
//   swipe X0 Y0 X1 Y1 MS [HOLD]   one finger from (X0,Y0) to (X1,Y1) in MS (8 ms steps, ease-out),
//                                 resting HOLD ms before lifting (default 0)
// A touch frame follows every down / motion / up.
// Build: wayland-scanner client-header fake-input.xml fake-input.h; wayland-scanner private-code
//        fake-input.xml fake-input.c; cc -O2 -o ftouch ftouch.c fake-input.c -lwayland-client -lm
#define _POSIX_C_SOURCE 200809L
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wayland-client.h>
#include "fake-input.h"

static struct org_kde_kwin_fake_input *fi;

static void reg_global(void *data, struct wl_registry *r, uint32_t name, const char *iface, uint32_t ver)
{
    (void)data;
    if (!strcmp(iface, org_kde_kwin_fake_input_interface.name))
        fi = wl_registry_bind(r, name, &org_kde_kwin_fake_input_interface, ver < 4 ? ver : 4);
}
static void reg_remove(void *data, struct wl_registry *r, uint32_t name) { (void)data; (void)r; (void)name; }
static const struct wl_registry_listener reg_l = { reg_global, reg_remove };

static void msleep(long ms)
{
    struct timespec t = { ms / 1000, (ms % 1000) * 1000000L };
    nanosleep(&t, NULL);
}

int main(void)
{
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "ftouch: no wayland display\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &reg_l, NULL);
    wl_display_roundtrip(dpy);
    if (!fi) { fprintf(stderr, "ftouch: compositor offers no org_kde_kwin_fake_input (permission?)\n"); return 1; }
    org_kde_kwin_fake_input_authenticate(fi, "ftouch", "y700 task switcher test");
    wl_display_roundtrip(dpy);

    char line[256];
    while (fgets(line, sizeof line, stdin)) {
        unsigned id; double x, y, x1, y1; long ms, hold; unsigned key;
        if (line[0] == '#' || line[0] == '\n') continue;
        if (sscanf(line, "swipe %lf %lf %lf %lf %ld %ld", &x, &y, &x1, &y1, &ms, &hold) >= 5) {
            if (sscanf(line, "swipe %*f %*f %*f %*f %*d %ld", &hold) != 1) hold = 0;
            org_kde_kwin_fake_input_touch_down(fi, 0, wl_fixed_from_double(x), wl_fixed_from_double(y));
            org_kde_kwin_fake_input_touch_frame(fi);
            wl_display_flush(dpy);
            int n = ms / 8 > 0 ? ms / 8 : 1;
            for (int i = 1; i <= n; i++) {
                double t = (double)i / n, e = 1 - pow(1 - t, 3);
                msleep(8);
                org_kde_kwin_fake_input_touch_motion(fi, 0, wl_fixed_from_double(x + (x1 - x) * e),
                                                     wl_fixed_from_double(y + (y1 - y) * e));
                org_kde_kwin_fake_input_touch_frame(fi);
                wl_display_flush(dpy);
            }
            if (hold > 0) msleep(hold);
            org_kde_kwin_fake_input_touch_up(fi, 0);
            org_kde_kwin_fake_input_touch_frame(fi);
        } else if (sscanf(line, "d %u %lf %lf", &id, &x, &y) == 3) {
            org_kde_kwin_fake_input_touch_down(fi, id, wl_fixed_from_double(x), wl_fixed_from_double(y));
            org_kde_kwin_fake_input_touch_frame(fi);
        } else if (sscanf(line, "m %u %lf %lf", &id, &x, &y) == 3) {
            org_kde_kwin_fake_input_touch_motion(fi, id, wl_fixed_from_double(x), wl_fixed_from_double(y));
            org_kde_kwin_fake_input_touch_frame(fi);
        } else if (sscanf(line, "u %u", &id) == 1) {
            org_kde_kwin_fake_input_touch_up(fi, id);
            org_kde_kwin_fake_input_touch_frame(fi);
        } else if (line[0] == 'c') {
            org_kde_kwin_fake_input_touch_cancel(fi);
        } else if (sscanf(line, "k %u", &key) == 1) {
            org_kde_kwin_fake_input_keyboard_key(fi, key, 1);
            wl_display_flush(dpy);
            msleep(20);
            org_kde_kwin_fake_input_keyboard_key(fi, key, 0);
        } else if (sscanf(line, "s %ld", &ms) == 1) {
            wl_display_flush(dpy);
            msleep(ms);
        } else {
            fprintf(stderr, "ftouch: ? %s", line);
        }
        wl_display_flush(dpy);
    }
    wl_display_roundtrip(dpy);
    wl_display_disconnect(dpy);
    return 0;
}
