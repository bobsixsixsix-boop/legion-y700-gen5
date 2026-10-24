// y700-no-waitboost.c (2026-10-18): LD_PRELOAD shim that drops the GPU "wait boost" hints from a Chrome process's DRM
// ioctls. Why: on the msm driver every CPU wait on a GPU fence that carries a deadline of "now" (Mesa's Vulkan
// runtime sets DRM_SYNCOBJ_WAIT_FLAGS_WAIT_DEADLINE; freedreno GL uses MSM_WAIT_FENCE_BOOST / MSM_PREP_BOOST) makes
// msm_fence_set_deadline() boost the GPU to 2x its current clock for 50 ms (msm_devfreq_boost). Chrome on zink waits
// like this about three times per frame, so during a 60 fps video the boosts never lapse and the GPU sits at 1200 MHz
// (965 boosts in 5 s measured, floor = max = 1200 MHz). Waiting still works exactly the same; only the clock hint
// goes. Nothing else is touched: other processes (only "chrome" is matched, see below) and other deadline paths
// (e.g. SYNC_IOC_SET_DEADLINE on sync files). With the shim on, ~60 deadlines/s and 0 boosts remain during a video;
// presumably KWin's per-vblank deadline (60 Hz panel), the source was not traced.
// Status (README "视频播放功耗" conclusion 7): the storm showed up only in the owner's own Chrome session (real
// profile, ~180 boosts/s, GPU pinned at 1200 MHz); the kiosk runs of linux/video/chrome-video-power-ab.sh never had
// it. Loaded into that session the shim took the boosts to 0/s and the same full-screen video from 4.96 W to 3.64 W
// (5 interleaved switch-on/off windows, linux/gpu/no-waitboost-ab.sh). Installed for every Chrome start through
// /etc/ld.so.preload by linux/gpu/install-no-waitboost.sh (Plasma's session restore replays Chrome's own command line,
// so an env prefix in the launcher would not be enough); undo with `install-no-waitboost.sh --uninstall`.
//
// Only a process whose name is "chrome" does anything (so the library can sit in /etc/ld.so.preload without touching
// KWin, ssh, ...). Kill switch that needs no restart: byte 2 of $XDG_RUNTIME_DIR/y700-no-waitboost.ctl; the file reads
// "Y1" (drop the hints, the default; the first Chrome process creates it) or "Y0" (pass everything through, so the
// storm is back). Flip it with `printf Y0 > /run/user/1000/y700-no-waitboost.ctl`; processes look at it at most every
// 100 ms with pread() (no mmap: truncating the file must not be able to SIGBUS Chrome; the "Y" magic keeps a recycled
// fd number from being read as the switch). Anything unreadable leaves the hints dropped.
//   gcc -O2 -shared -fPIC -o y700-no-waitboost.so y700-no-waitboost.c -ldl
//   LD_PRELOAD=/path/y700-no-waitboost.so chrome ...
// Struct offsets from include/uapi/drm/{drm,msm_drm}.h (kernel 7.3 tree on the tablet):
//   drm_syncobj_wait.flags           u32 #5  (handles u64, timeout u64, count u32, flags u32)
//   drm_syncobj_timeline_wait.flags  u32 #7  (handles u64, points u64, timeout u64, count u32, flags u32)
//   drm_msm_wait_fence.flags         u32 #1  MSM_WAIT_FENCE_BOOST 0x1
//   drm_msm_gem_cpu_prep.op          u32 #1  MSM_PREP_BOOST 0x8
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/ioctl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define SYNCOBJ_WAIT_DEADLINE (1u << 3)
#define DRM_COMMAND_BASE 0x40
#define CTL_NAME "/y700-no-waitboost.ctl"
#define CTL_RECHECK_MS 100

static int (*real_ioctl)(int, unsigned long, ...);
static int active;	/* this process is Chrome */
static int ctl_fd = -1;
/* shared by Chrome's threads without a lock: aligned int/long loads and stores do not tear on aarch64, so the worst a
   race does is one extra pread or a switch seen one tick late */
static volatile int on = 1;
static volatile long next_check_ms;

static long now_ms(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC_COARSE, &t);
	return t.tv_sec * 1000L + t.tv_nsec / 1000000;
}

/* the switch, re-read at most every CTL_RECHECK_MS */
static int enabled(void)
{
	if (ctl_fd >= 0) {
		long n = now_ms();
		if (n >= next_check_ms) {
			char c[2];
			next_check_ms = n + CTL_RECHECK_MS;
			if (pread(ctl_fd, c, 2, 0) == 2 && c[0] == 'Y')
				on = c[1] != '0';
		}
	}
	return on;
}

__attribute__((constructor)) static void init(void)
{
	const char *dir;
	real_ioctl = (int (*)(int, unsigned long, ...))dlsym(RTLD_NEXT, "ioctl");
	active = program_invocation_short_name && !strcmp(program_invocation_short_name, "chrome");
	dir = secure_getenv("XDG_RUNTIME_DIR");	/* NULL in setuid processes: never trust their environment */
	if (active && dir && *dir) {
		char path[256], c[2];
		if (snprintf(path, sizeof path, "%s" CTL_NAME, dir) < (int)sizeof path) {
			ctl_fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0666);
			if (ctl_fd >= 0 && (pread(ctl_fd, c, 2, 0) != 2 || c[0] != 'Y') && pwrite(ctl_fd, "Y1", 2, 0) != 2) {
				close(ctl_fd);
				ctl_fd = -1;
			}
		}
	}
}

int ioctl(int fd, unsigned long req, ...)
{
	va_list ap;
	va_start(ap, req);
	void *arg = va_arg(ap, void *);
	va_end(ap);
	if (active && arg && _IOC_TYPE(req) == 'd') {
		uint32_t *a = arg;
		unsigned nr = _IOC_NR(req), sz = _IOC_SIZE(req);
		uint32_t *flags = 0, bit = 0;
		if (nr == 0xC3 && sz >= 24)
			flags = &a[5], bit = SYNCOBJ_WAIT_DEADLINE;
		else if (nr == 0xCA && sz >= 32)
			flags = &a[7], bit = SYNCOBJ_WAIT_DEADLINE;
		else if (nr == DRM_COMMAND_BASE + 0x07 && sz >= 8)
			flags = &a[1], bit = 0x1u;
		else if (nr == DRM_COMMAND_BASE + 0x04 && sz >= 8)
			flags = &a[1], bit = 0x8u;
		if (flags && enabled())
			*flags &= ~bit;
	}
	if (!real_ioctl)
		real_ioctl = (int (*)(int, unsigned long, ...))dlsym(RTLD_NEXT, "ioctl");
	return real_ioctl(fd, req, arg);
}
