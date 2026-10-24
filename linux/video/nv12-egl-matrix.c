// nv12-egl-matrix.c: which YUV -> RGB matrix / range the GL driver applies to an imported NV12 / P010 dmabuf
// sampled through GL_TEXTURE_EXTERNAL_OES, for each EGL_YUV_COLOR_SPACE_HINT_EXT / EGL_SAMPLE_RANGE_HINT_EXT.
// 2026-10-23, the "Chrome 硬解画面按 BT.601 上色" line in README "视频硬解". Run as the desktop user on the tablet:
//   gcc -O1 -o /tmp/nv12m nv12-egl-matrix.c -I/usr/include/libdrm -ldl -lm
//   MESA_LOADER_DRIVER_OVERRIDE=zink /tmp/nv12m        (what Chrome's GL is; msm = freedreno for comparison)
// The buffer comes from the system dma-heap (foreign to the GPU, like libva-v4l2's V4L2 buffers), filled with 4
// stripes: BT.709 limited red, green, blue and Y=U=V=128. Each import is drawn to an RGBA8 FBO and read back; the line
// says which of BT.601 / BT.709 / BT.2020 x limited / full the stripes fit best (mean abs error over the 12 values).
// Args, any order: nv12 (default) | p010; mod (pass DRM_FORMAT_MOD_LINEAR explicitly, as Chrome does for a VA-API
// surface); WxH (default 256x64; e.g. 1280x720 to check yuv709-shim.c, which only touches HD sizes; W a multiple of 64,
// the pitch is W: turnip refuses a 720-byte linear pitch with VK_ERROR_INVALID_DRM_FORMAT_MODIFIER_PLANE_LAYOUT_EXT).
// 10-23, Mesa 26.0.8: zink and freedreno both follow the hints; no hint = BT.601 limited, which is exactly what Chrome
// shows for hardware frames (BT.709 red -> (233,0,2)); freedreno needs the explicit modifier, zink takes either.
#define _GNU_SOURCE
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <drm_fourcc.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <linux/dma-heap.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

static int W = 256, H = 64;
#define NS 4
static const double SRC[NS][3] = {{255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {-1, -1, -1}};  // -1: Y=U=V=128
static int yuv709[NS][3];

static void *(*gpa)(const char *);
#define P(t, n) t n = (t)gpa(#n)

static void to709(const double rgb[3], int out[3]) {  // BT.709 limited range, 8-bit
	double kr = 0.2126, kb = 0.0722, r = rgb[0] / 255, g = rgb[1] / 255, b = rgb[2] / 255;
	double y = kr * r + (1 - kr - kb) * g + kb * b;
	out[0] = (int)lround(16 + 219 * y);
	out[1] = (int)lround(128 + 224 * (b - y) / (2 * (1 - kb)));
	out[2] = (int)lround(128 + 224 * (r - y) / (2 * (1 - kr)));
}
// what a decoder with matrix m (601 / 709 / 2020) and range (0 limited / 1 full) gives for 8-bit Y, Cb, Cr
static void model(int m, int full, const int yuv[3], double rgb[3]) {
	double kr = m == 601 ? 0.299 : m == 709 ? 0.2126 : 0.2627, kb = m == 601 ? 0.114 : m == 709 ? 0.0722 : 0.0593;
	double y = full ? yuv[0] / 255.0 : (yuv[0] - 16) / 219.0;
	double cb = full ? (yuv[1] - 128) / 255.0 : (yuv[1] - 128) / 224.0, cr = full ? (yuv[2] - 128) / 255.0 : (yuv[2] - 128) / 224.0;
	double r = y + 2 * (1 - kr) * cr, b = y + 2 * (1 - kb) * cb, g = (y - kr * r - kb * b) / (1 - kr - kb);
	double v[3] = {r, g, b};
	for (int i = 0; i < 3; i++) rgb[i] = fmin(255, fmax(0, v[i] * 255));
}

int main(int argc, char **argv) {
	int p010 = 0, mod = 0;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "p010")) p010 = 1;
		else if (!strcmp(argv[i], "mod")) mod = 1;
		else if (sscanf(argv[i], "%dx%d", &W, &H) != 2 || W < 64 || H < 16 || W % 64 || H % 2) {
			fprintf(stderr, "usage: %s [nv12|p010] [mod] [WxH, W a multiple of 64]\n", argv[0]); return 2;
		}
	}
	int bpp = p010 ? 2 : 1, pitch = W * bpp, ysz = pitch * H, total = ysz + pitch * H / 2;
	for (int s = 0; s < NS; s++) {
		if (SRC[s][0] < 0) yuv709[s][0] = yuv709[s][1] = yuv709[s][2] = 128;
		else to709(SRC[s], yuv709[s]);
	}
	int heap = open("/dev/dma_heap/system", O_RDWR | O_CLOEXEC);
	if (heap < 0) { perror("open /dev/dma_heap/system"); return 2; }
	struct dma_heap_allocation_data al = {.len = (total + 4095) & ~4095, .fd_flags = O_RDWR | O_CLOEXEC};
	if (ioctl(heap, DMA_HEAP_IOCTL_ALLOC, &al)) { perror("DMA_HEAP_IOCTL_ALLOC"); return 2; }
	int fd = al.fd;
	uint8_t *m = mmap(0, al.len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (m == MAP_FAILED) { perror("mmap"); return 2; }
	for (int y = 0; y < H; y++)
		for (int x = 0; x < W; x++) {
			int s = x * NS / W, v = yuv709[s][0];
			if (p010) ((uint16_t *)(m + y * pitch))[x] = v << 8;  // 10-bit value v*4 in the top 10 bits
			else m[y * pitch + x] = v;
		}
	for (int y = 0; y < H / 2; y++)
		for (int x = 0; x < W / 2; x++) {
			int s = 2 * x * NS / W;
			if (p010) {
				uint16_t *row = (uint16_t *)(m + ysz + y * pitch);
				row[2 * x] = yuv709[s][1] << 8, row[2 * x + 1] = yuv709[s][2] << 8;
			} else m[ysz + y * pitch + 2 * x] = yuv709[s][1], m[ysz + y * pitch + 2 * x + 1] = yuv709[s][2];
		}
	munmap(m, al.len);

	void *egl = dlopen("libEGL.so.1", RTLD_NOW | RTLD_GLOBAL);
	if (!egl) { fprintf(stderr, "dlopen libEGL: %s\n", dlerror()); return 2; }
	gpa = (void *(*)(const char *))dlsym(egl, "eglGetProcAddress");
	P(PFNEGLGETPLATFORMDISPLAYEXTPROC, eglGetPlatformDisplayEXT);
	P(PFNEGLINITIALIZEPROC, eglInitialize);
	P(PFNEGLCHOOSECONFIGPROC, eglChooseConfig);
	P(PFNEGLBINDAPIPROC, eglBindAPI);
	P(PFNEGLCREATECONTEXTPROC, eglCreateContext);
	P(PFNEGLMAKECURRENTPROC, eglMakeCurrent);
	P(PFNEGLCREATEIMAGEKHRPROC, eglCreateImageKHR);
	P(PFNEGLDESTROYIMAGEKHRPROC, eglDestroyImageKHR);
	P(PFNEGLGETERRORPROC, eglGetError);
	P(PFNEGLQUERYDMABUFMODIFIERSEXTPROC, eglQueryDmaBufModifiersEXT);
	EGLDisplay d = eglGetPlatformDisplayEXT(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
	EGLint ma, mi;
	if (!eglInitialize(d, &ma, &mi)) { fprintf(stderr, "eglInitialize 0x%x\n", eglGetError()); return 2; }
	EGLint ca[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_NONE}, n;
	EGLConfig cfg;
	eglChooseConfig(d, ca, &cfg, 1, &n);
	eglBindAPI(EGL_OPENGL_ES_API);
	EGLint cta[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
	EGLContext c = eglCreateContext(d, n ? cfg : NULL, EGL_NO_CONTEXT, cta);
	if (!c || !eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, c)) { fprintf(stderr, "context 0x%x\n", eglGetError()); return 2; }
	P(PFNGLGETSTRINGPROC, glGetString);
	P(PFNGLEGLIMAGETARGETTEXTURE2DOESPROC, glEGLImageTargetTexture2DOES);
	P(PFNGLGENTEXTURESPROC, glGenTextures);
	P(PFNGLBINDTEXTUREPROC, glBindTexture);
	P(PFNGLTEXPARAMETERIPROC, glTexParameteri);
	P(PFNGLTEXIMAGE2DPROC, glTexImage2D);
	P(PFNGLGENFRAMEBUFFERSPROC, glGenFramebuffers);
	P(PFNGLBINDFRAMEBUFFERPROC, glBindFramebuffer);
	P(PFNGLFRAMEBUFFERTEXTURE2DPROC, glFramebufferTexture2D);
	P(PFNGLCHECKFRAMEBUFFERSTATUSPROC, glCheckFramebufferStatus);
	P(PFNGLCREATESHADERPROC, glCreateShader);
	P(PFNGLSHADERSOURCEPROC, glShaderSource);
	P(PFNGLCOMPILESHADERPROC, glCompileShader);
	P(PFNGLGETSHADERIVPROC, glGetShaderiv);
	P(PFNGLGETSHADERINFOLOGPROC, glGetShaderInfoLog);
	P(PFNGLCREATEPROGRAMPROC, glCreateProgram);
	P(PFNGLATTACHSHADERPROC, glAttachShader);
	P(PFNGLBINDATTRIBLOCATIONPROC, glBindAttribLocation);
	P(PFNGLLINKPROGRAMPROC, glLinkProgram);
	P(PFNGLUSEPROGRAMPROC, glUseProgram);
	P(PFNGLVERTEXATTRIBPOINTERPROC, glVertexAttribPointer);
	P(PFNGLENABLEVERTEXATTRIBARRAYPROC, glEnableVertexAttribArray);
	P(PFNGLVIEWPORTPROC, glViewport);
	P(PFNGLDRAWARRAYSPROC, glDrawArrays);
	P(PFNGLREADPIXELSPROC, glReadPixels);
	P(PFNGLFINISHPROC, glFinish);
	P(PFNGLGETERRORPROC, glGetError);
	printf("GL_RENDERER %s; %s %dx%d, pitch %d%s\n", glGetString(GL_RENDERER), p010 ? "P010" : "NV12", W, H, pitch,
	       mod ? ", explicit LINEAR modifier" : "");
	int fourcc = p010 ? DRM_FORMAT_P010 : DRM_FORMAT_NV12;
	if (eglQueryDmaBufModifiersEXT) {
		EGLuint64KHR mods[64]; EGLBoolean ext[64]; EGLint nm = 0;
		eglQueryDmaBufModifiersEXT(d, fourcc, 64, mods, ext, &nm);
		printf("modifiers for this format (external_only):");
		for (int i = 0; i < nm; i++) printf(" 0x%llx(%d)", (unsigned long long)mods[i], ext[i]);
		printf("%s\n", nm ? "" : " none");
	}
	const char *vs = "attribute vec2 p; varying vec2 t; void main(){ t = p * 0.5 + 0.5; gl_Position = vec4(p, 0.0, 1.0); }";
	const char *fs = "#extension GL_OES_EGL_image_external : require\nprecision highp float; varying vec2 t; uniform samplerExternalOES s;"
	                 " void main(){ gl_FragColor = texture2D(s, t); }";
	GLuint sh[2] = {glCreateShader(GL_VERTEX_SHADER), glCreateShader(GL_FRAGMENT_SHADER)}, prog = glCreateProgram();
	const char *src[2] = {vs, fs};
	for (int i = 0; i < 2; i++) {
		GLint ok; char lg[512];
		glShaderSource(sh[i], 1, &src[i], NULL); glCompileShader(sh[i]); glGetShaderiv(sh[i], GL_COMPILE_STATUS, &ok);
		if (!ok) { glGetShaderInfoLog(sh[i], sizeof lg, NULL, lg); fprintf(stderr, "shader: %s\n", lg); return 2; }
		glAttachShader(prog, sh[i]);
	}
	glBindAttribLocation(prog, 0, "p"); glLinkProgram(prog); glUseProgram(prog);
	static const float quad[] = {-1, -1, 1, -1, -1, 1, 1, 1};
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, quad); glEnableVertexAttribArray(0);
	GLuint rt, fb; glGenTextures(1, &rt); glBindTexture(GL_TEXTURE_2D, rt);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
	glGenFramebuffers(1, &fb); glBindFramebuffer(GL_FRAMEBUFFER, fb);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, rt, 0);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) { fprintf(stderr, "FBO incomplete\n"); return 2; }
	glViewport(0, 0, W, H);

	static const struct { const char *n; EGLint v; } CS[] = {{"none", 0}, {"601", EGL_ITU_REC601_EXT}, {"709", EGL_ITU_REC709_EXT}, {"2020", EGL_ITU_REC2020_EXT}};
	static const struct { const char *n; EGLint v; } RG[] = {{"none", 0}, {"narrow", EGL_YUV_NARROW_RANGE_EXT}, {"full", EGL_YUV_FULL_RANGE_EXT}};
	for (unsigned ci = 0; ci < 4; ci++)
		for (unsigned ri = 0; ri < 3; ri++) {
			EGLint a[64], k = 0;
#define A(x, y) (a[k++] = (x), a[k++] = (y))
			A(EGL_WIDTH, W); A(EGL_HEIGHT, H); A(EGL_LINUX_DRM_FOURCC_EXT, fourcc);
			A(EGL_DMA_BUF_PLANE0_FD_EXT, fd); A(EGL_DMA_BUF_PLANE0_OFFSET_EXT, 0); A(EGL_DMA_BUF_PLANE0_PITCH_EXT, pitch);
			A(EGL_DMA_BUF_PLANE1_FD_EXT, fd); A(EGL_DMA_BUF_PLANE1_OFFSET_EXT, ysz); A(EGL_DMA_BUF_PLANE1_PITCH_EXT, pitch);
			if (mod) {
				A(EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, 0); A(EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, 0);
				A(EGL_DMA_BUF_PLANE1_MODIFIER_LO_EXT, 0); A(EGL_DMA_BUF_PLANE1_MODIFIER_HI_EXT, 0);
			}
			if (CS[ci].v) A(EGL_YUV_COLOR_SPACE_HINT_EXT, CS[ci].v);
			if (RG[ri].v) A(EGL_SAMPLE_RANGE_HINT_EXT, RG[ri].v);
			a[k] = EGL_NONE;
			EGLImageKHR img = eglCreateImageKHR(d, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, a);
			printf("hint %-4s range %-6s: ", CS[ci].n, RG[ri].n);
			if (!img) { printf("eglCreateImage failed 0x%x\n", eglGetError()); continue; }
			GLuint t; glGenTextures(1, &t); glBindTexture(GL_TEXTURE_EXTERNAL_OES, t);
			glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
			glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
			glEGLImageTargetTexture2DOES(GL_TEXTURE_EXTERNAL_OES, img);
			glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
			uint8_t px[NS][4];
			for (int s = 0; s < NS; s++) glReadPixels(W * s / NS + W / NS / 2, H / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px[s]);
			glFinish();
			GLenum e = glGetError();
			for (int s = 0; s < NS; s++) printf("(%3d,%3d,%3d) ", px[s][0], px[s][1], px[s][2]);
			const char *best = "?"; double be = 1e9;
			static char nm[16][16];
			int mm[3] = {601, 709, 2020};
			for (int mi2 = 0; mi2 < 3; mi2++)
				for (int f = 0; f < 2; f++) {
					double err = 0, rgb[3];
					for (int s = 0; s < NS; s++) {
						model(mm[mi2], f, yuv709[s], rgb);
						for (int i = 0; i < 3; i++) err += fabs(rgb[i] - px[s][i]);
					}
					err /= NS * 3;
					if (err < be) { be = err; snprintf(nm[0], sizeof nm[0], "%d %s", mm[mi2], f ? "full" : "limited"); best = nm[0]; }
				}
			printf("-> %s (err %.1f)%s\n", best, be, e ? " GL error" : "");
			glBindTexture(GL_TEXTURE_EXTERNAL_OES, 0);
			eglDestroyImageKHR(d, img);
		}
	printf("source stripes (BT.709 limited Y,Cb,Cr):");
	for (int s = 0; s < NS; s++) printf(" (%d,%d,%d)", yuv709[s][0], yuv709[s][1], yuv709[s][2]);
	printf("\n");
	return 0;
}
