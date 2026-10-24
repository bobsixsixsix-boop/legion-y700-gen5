/* y700-gst-colorimetry.c -- LD_PRELOAD for LIVI's gst-host (LIVI_GST_PRELOAD, set by /usr/local/bin/y700-carplay).
 *
 * The iPhone's CarPlay video (HEVC 1152x720) says, in its VUI, full-range BT.709 with the sRGB transfer function:
 * colorimetry "1:3:7:1". GStreamer's v4l2 decoders (v4l2h265dec on iris) only take the colorimetries they probed
 * from the driver, a fixed candidate list that has 1:3:5:1 and 1:4:7:1 but not 1:3:7:1, so the parser's caps are
 * refused, the pipeline fails not-negotiated and CarPlay stays black (LIVI has the same kind of fix-up only for the
 * Raspberry Pi's 1:4:5:1). h264parse/h265parse write that string with gst_video_colorimetry_to_string(); this
 * reports the BT.709 transfer instead whenever the matrix is BT.709 and the transfer sRGB, i.e. 1:3:5:1 (or bt709
 * for limited range), which the decoder takes. The picture is unchanged because nothing in this pipeline uses the
 * transfer function: glcolorconvert's YUV->RGB takes only range and matrix, videoconvert defaults to gamma-mode=none.
 * The two curves are NOT close (sRGB-coded mid-grey 128 read as BT.709 is ~115): if an element that converts gamma,
 * or a colour-managed YUV path to the compositor, is ever added, this relabel becomes a visible midtone shift.
 *
 * Build (on the tablet, no GStreamer headers needed - GstVideoColorimetry is four enums):
 *   gcc -O2 -Wall -shared -fPIC -o /usr/local/lib/y700-carplay/y700-gst-colorimetry.so y700-gst-colorimetry.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stddef.h>

typedef struct { int range, matrix, transfer, primaries; } Colorimetry;   /* GstVideoColorimetry */
enum { MATRIX_BT709 = 3, TRANSFER_BT709 = 5, TRANSFER_SRGB = 7 };          /* GstVideoColorMatrix / ...TransferFunction */
typedef char *(*to_string_fn)(const Colorimetry *);
char *gst_video_colorimetry_to_string(const Colorimetry *c);

static to_string_fn real_to_string(void)
{
    static to_string_fn real;
    to_string_fn f = __atomic_load_n(&real, __ATOMIC_ACQUIRE);
    if (f)
        return f;
    /* libgstvideo arrives with the plugins, which GStreamer opens RTLD_LOCAL, so RTLD_NEXT need not see it; by the
     * time anything calls this it is loaded, and a handle to it finds its own definition, not this one. */
    void *h = dlopen("libgstvideo-1.0.so.0", RTLD_LAZY | RTLD_NOLOAD);
    f = (to_string_fn)dlsym(h ? h : RTLD_NEXT, "gst_video_colorimetry_to_string");
    if (f == gst_video_colorimetry_to_string || f == NULL)
        return NULL;
    __atomic_store_n(&real, f, __ATOMIC_RELEASE);
    return f;
}

char *gst_video_colorimetry_to_string(const Colorimetry *c)
{
    to_string_fn real = real_to_string();
    if (!real)
        return NULL;                        /* callers treat NULL as "no colorimetry" */
    if (c && c->matrix == MATRIX_BT709 && c->transfer == TRANSFER_SRGB) {
        Colorimetry fixed = *c;
        fixed.transfer = TRANSFER_BT709;
        return real(&fixed);
    }
    return real(c);
}
