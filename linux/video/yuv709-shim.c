// yuv709-shim.c: LD_PRELOAD shim that lets Chrome's hardware-decoded HD video be converted with BT.709 instead of
// BT.601. 2026-10-23, README "视频硬解" 「Chrome 硬解画面按 BT.601 上色」. Installed as /usr/local/lib/y700-yuv709.so in
// /etc/ld.so.preload by install-yuv709-shim.sh (so every process maps it; outside Chrome it only passes calls through).
//   gcc -O2 -Wall -Wextra -shared -fPIC -o y700-yuv709.so yuv709-shim.c -ldl
// Why: Chrome 155 passes EGL_YUV_COLOR_SPACE_HINT_EXT = EGL_ITU_REC601_EXT for every NV12 / YV12 / P010 dmabuf that is not
// BT.2020 (ui/ozone/common/native_pixmap_egl_binding.cc, InitializeFromNativePixmap: a ChromeOS DRM/KMS overlay
// workaround, TODO b/233667677, that desktop Linux inherits), and Mesa (zink and freedreno alike) honours the hint
// (nv12-egl-matrix.c). The frame's own colour space never reaches EGL, so this guesses the way mpv does for untagged
// video: HD (width >= 1280 or height > 576) is BT.709, SD stays BT.601. The range hint is Chrome's own and is left alone.
// How: interposes libgallium's dri2_from_dma_bufs (what eglCreateImage(EGL_LINUX_DMA_BUF_EXT) ends in; libEGL_mesa calls
// it through the PLT, so a preloaded definition wins) with a tail-call trampoline: it passes everything through
// whatever the signature is, and only rewrites when all of these hold: the process is Google Chrome (or Y700_YUV709=1),
// the libgallium is one whose layout was checked (26.0.x: the colour-space hint is the 2nd stacked argument; calibrated
// with gdb on 26.0.8 against nv12-egl-matrix.c's known hints), the format is NV12 / YV12 / P010, the hint is 601, the
// size is HD. Y700_YUV709=0 turns it off; Y700_YUV709_DEBUG=1 logs the first 20 rewrites and the activation to stderr.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <limits.h>
#include <link.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define FOURCC_NV12 0x3231564e
#define FOURCC_YV12 0x32315659
#define FOURCC_P010 0x30313050
#define HINT_601 0x327f
#define HINT_709 0x3280

static int want = -1, debug, logged;  // want: -1 not Chrome, 0 off, 1 on
static void *real;
static int layout_ok;

__attribute__((constructor)) static void init(void) {
	const char *e = getenv("Y700_YUV709"), *d = getenv("Y700_YUV709_DEBUG");
	char exe[256];
	ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
	debug = d && *d == '1';
	if (n > 0) exe[n] = 0; else exe[0] = 0;
	if (e && *e == '0') want = 0;
	else if (e && *e == '1') want = 1;
	else if (!strcmp(exe, "/opt/google/chrome/chrome")) want = 1;
}

// dl_iterate_phdr holds the loader's dl_load_write_lock while it runs the callback; dlopen / dlsym take dl_load_lock,
// and a dlopen in another thread holds dl_load_lock and then wants dl_load_write_lock: calling either from the
// callback is an ABBA deadlock (11-09, test KWin hung at its first dmabuf import while its QQmlThread loaded a QML
// plugin; linux/stage/README 踩坑 17). So the callback only copies the paths of the loaded libgallium-*, with no dl*,
// no malloc, no stdio, and they are opened after dl_iterate_phdr has returned.
#define MAX_GALLIUM 4
struct gallium_paths {
	int n;
	char path[MAX_GALLIUM][PATH_MAX];
};

static int find_gallium(struct dl_phdr_info *i, size_t sz, void *out) {
	(void)sz;
	struct gallium_paths *g = out;
	const char *b = strrchr(i->dlpi_name, '/');
	size_t len = strlen(i->dlpi_name);
	if (!b || strncmp(b + 1, "libgallium-", 11) || len >= PATH_MAX) return 0;
	memcpy(g->path[g->n], i->dlpi_name, len + 1);
	return ++g->n == MAX_GALLIUM;
}

// the first loaded libgallium-* that defines dri2_from_dma_bufs, or NULL; sets layout_ok for it. No loader lock held
// here (see above), so dlopen / dlsym may wait for another thread's dlopen but cannot deadlock with it.
static void *lookup_real(void) {
	struct gallium_paths g;
	g.n = 0;
	dl_iterate_phdr(find_gallium, &g);
	for (int k = 0; k < g.n; k++) {
		// RTLD_NOLOAD: only a reference to the copy already mapped (never dlclosed: the pointer must stay valid)
		void *h = dlopen(g.path[k], RTLD_NOW | RTLD_NOLOAD);
		void *f = h ? dlsym(h, "dri2_from_dma_bufs") : NULL;
		if (!f) continue;
		const char *b = strrchr(g.path[k], '/') + 1;
		layout_ok = !strncmp(b, "libgallium-26.0.", 16);
		if (debug && want == 1)
			fprintf(stderr, "y700-yuv709: %s in pid %d, %s\n", b, getpid(),
			        layout_ok ? "HD 601 -> 709 active" : "unknown argument layout, passing through");
		return f;
	}
	return NULL;
}

// called by the trampoline with the caller's stack pointer (the stacked arguments) and the 3 int arguments it needs;
// returns the real dri2_from_dma_bufs
// No libgallium defines it (a loader this shim does not know): the import fails (NULL, *error left alone) instead of
// taking the process down; preloaded everywhere, an abort here would hit whatever program that is.
static void *no_import(void) { return NULL; }

__attribute__((visibility("hidden"), used)) void *y700_yuv709_fixup(uint64_t *stack, int width, int height, int fourcc) {
	void *f = __atomic_load_n(&real, __ATOMIC_ACQUIRE);
	if (!f) {
		f = lookup_real();
		if (!f) {
			static int told;
			if (!__atomic_exchange_n(&told, 1, __ATOMIC_RELAXED))
				fprintf(stderr, "y700-yuv709: no libgallium defines dri2_from_dma_bufs, failing the import\n");
			return (void *)no_import;
		}
		__atomic_store_n(&real, f, __ATOMIC_RELEASE);
	}
	if (want == 1 && layout_ok && (fourcc == FOURCC_NV12 || fourcc == FOURCC_YV12 || fourcc == FOURCC_P010) &&
	    (uint32_t)stack[1] == HINT_601 && (width >= 1280 || height > 576)) {
		stack[1] = (stack[1] & ~0xffffffffULL) | HINT_709;
		if (debug && logged < 20) {
			logged++;
			fprintf(stderr, "y700-yuv709: %dx%d fourcc 0x%x: BT.601 hint -> BT.709\n", width, height, fourcc);
		}
	}
	return f;
}

// dri2_from_dma_bufs(screen, width, height, fourcc, modifier, fds, num_fds, strides | offsets, yuv_color_space,
// sample_range, ...): x0-x7 in registers, the rest on the stack. Save x0-x8, ask the fixup for the real function, restore,
// tail-call it with the caller's own return address and stack (x16: a valid BTI target for BR).
__asm__(".text\n"
        ".global dri2_from_dma_bufs\n"
        ".type dri2_from_dma_bufs, %function\n"
        "dri2_from_dma_bufs:\n"
        "  bti c\n"
        "  stp x29, x30, [sp, #-96]!\n"
        "  mov x29, sp\n"
        "  stp x0, x1, [sp, #16]\n"
        "  stp x2, x3, [sp, #32]\n"
        "  stp x4, x5, [sp, #48]\n"
        "  stp x6, x7, [sp, #64]\n"
        "  str x8, [sp, #80]\n"
        "  add x0, sp, #96\n"
        "  ldr w1, [sp, #24]\n"
        "  ldr w2, [sp, #32]\n"
        "  ldr w3, [sp, #40]\n"
        "  bl y700_yuv709_fixup\n"
        "  mov x16, x0\n"
        "  ldp x0, x1, [sp, #16]\n"
        "  ldp x2, x3, [sp, #32]\n"
        "  ldp x4, x5, [sp, #48]\n"
        "  ldp x6, x7, [sp, #64]\n"
        "  ldr x8, [sp, #80]\n"
        "  ldp x29, x30, [sp], #96\n"
        "  br x16\n"
        ".size dri2_from_dma_bufs, .-dri2_from_dma_bufs\n");
