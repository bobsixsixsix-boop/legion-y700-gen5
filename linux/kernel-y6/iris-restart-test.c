// Stateful V4L2 decoder check for the ArmadaOS iris fixes 1030/1031 (kernel y6).
//
// Feeds an Annex B H.264/HEVC elementary stream (access units split at AUD NALs, one per buffer) to the iris
// decoder. With --restart it behaves like the Steam streaming client: after the first SOURCE_CHANGE it sets up
// the capture queue, restarts the bitstream (OUTPUT) port and replays the stream from the first access unit.
// Before 1030/1031 the driver sent POC type 0 and the AV1 tier on that restart, so an H.264 stream with POC
// type 1/2 or a High tier HEVC stream raised the same SOURCE_CHANGE again (Steam restarts again: a loop, green
// screen). Any second SOURCE_CHANGE in --restart mode is reported as that failure.
//
// build: gcc -O2 -Wall -o iris-restart-test iris-restart-test.c
// usage: iris-restart-test /dev/video0 h264|hevc WIDTH HEIGHT file.es [--restart]
// prints one RESULT line; exit 0 = every access unit decoded, 1 = source-change loop / stall / missing frames.
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define OUT V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE
#define CAP V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE
#define NOUT 4
#define OUTSZ (4 << 20)
#define MAXAU 100000

static int fd, hevc, restart, nau, next_au, cap_on, cap_planes, stopped;
static uint8_t *es;
static size_t eslen, au_off[MAXAU + 1];
static void *outmap[NOUT];

static void die(const char *m)
{
	perror(m);
	exit(2);
}

static int xioctl(unsigned long r, void *a)
{
	int e;

	do
		e = ioctl(fd, r, a);
	while (e < 0 && errno == EINTR);
	return e;
}

static double now(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

static int is_aud(const uint8_t *p)
{
	return hevc ? ((p[0] >> 1) & 0x3f) == 35 : (p[0] & 0x1f) == 9;
}

static void split(void)
{
	for (size_t i = 0; i + 4 < eslen; i++)
		if (es[i] == 0 && es[i + 1] == 0 && es[i + 2] == 1 && is_aud(es + i + 3)) {
			if (nau == MAXAU)
				break;
			au_off[nau++] = (i > 0 && es[i - 1] == 0) ? i - 1 : i;
			i += 3;
		}
	au_off[nau] = eslen;
}

static int queue_out(int idx)
{
	struct v4l2_plane pl = {0};
	struct v4l2_buffer b = {0};
	size_t len;

	if (next_au >= nau)
		return 0;
	len = au_off[next_au + 1] - au_off[next_au];
	if (len > OUTSZ) {
		fprintf(stderr, "access unit %d is %zu bytes\n", next_au, len);
		exit(2);
	}
	memcpy(outmap[idx], es + au_off[next_au], len);
	b.type = OUT;
	b.memory = V4L2_MEMORY_MMAP;
	b.index = idx;
	b.m.planes = &pl;
	b.length = 1;
	b.timestamp.tv_sec = next_au;
	pl.bytesused = len;
	if (xioctl(VIDIOC_QBUF, &b))
		die("QBUF output");
	next_au++;
	return 1;
}

static void stop_if_done(void)
{
	struct v4l2_decoder_cmd cmd = {.cmd = V4L2_DEC_CMD_STOP};

	if (next_au < nau || stopped)
		return;
	if (xioctl(VIDIOC_DECODER_CMD, &cmd))
		die("DECODER_CMD stop");
	stopped = 1;
}

static void cap_setup(void)
{
	struct v4l2_requestbuffers r = {.type = CAP, .memory = V4L2_MEMORY_MMAP};
	struct v4l2_control c = {.id = V4L2_CID_MIN_BUFFERS_FOR_CAPTURE};
	struct v4l2_format f = {.type = CAP};
	int t = CAP;

	if (cap_on && xioctl(VIDIOC_STREAMOFF, &t))
		die("STREAMOFF capture");
	cap_on = 0;
	if (xioctl(VIDIOC_REQBUFS, &r))
		die("REQBUFS capture 0");
	if (xioctl(VIDIOC_G_FMT, &f))
		die("G_FMT capture");
	cap_planes = f.fmt.pix_mp.num_planes;
	r.count = (xioctl(VIDIOC_G_CTRL, &c) ? 4 : c.value) + 4;
	if (xioctl(VIDIOC_REQBUFS, &r))
		die("REQBUFS capture");
	printf("  capture %ux%u %.4s, %u buffers\n", f.fmt.pix_mp.width, f.fmt.pix_mp.height,
	       (char *)&f.fmt.pix_mp.pixelformat, r.count);
	for (unsigned i = 0; i < r.count; i++) {
		struct v4l2_plane pl[VIDEO_MAX_PLANES] = {0};
		struct v4l2_buffer b = {.type = CAP, .memory = V4L2_MEMORY_MMAP, .index = i,
					.m.planes = pl, .length = cap_planes};
		if (xioctl(VIDIOC_QBUF, &b))
			die("QBUF capture");
	}
	if (xioctl(VIDIOC_STREAMON, &t))
		die("STREAMON capture");
	cap_on = 1;
}

static void out_restart(void)
{
	int t = OUT;

	if (xioctl(VIDIOC_STREAMOFF, &t))
		die("STREAMOFF output");
	next_au = 0; /* replay from the first access unit (parameter sets + IDR) */
	stopped = 0;
	for (int i = 0; i < NOUT; i++)
		queue_out(i);
	if (xioctl(VIDIOC_STREAMON, &t))
		die("STREAMON output");
}

int main(int argc, char **argv)
{
	struct v4l2_format f = {.type = OUT};
	struct v4l2_requestbuffers r = {.type = OUT, .memory = V4L2_MEMORY_MMAP, .count = NOUT};
	struct v4l2_event_subscription sub = {.type = V4L2_EVENT_SOURCE_CHANGE};
	int sc = 0, frames = 0, last = 0, t = OUT, ok;
	const char *why = "done";
	double progress;
	struct stat st;
	int in;

	if (argc < 6) {
		fprintf(stderr, "usage: %s /dev/videoN h264|hevc WIDTH HEIGHT file.es [--restart]\n", argv[0]);
		return 2;
	}
	hevc = !strcmp(argv[2], "hevc");
	restart = argc > 6 && !strcmp(argv[6], "--restart");
	in = open(argv[5], O_RDONLY);
	if (in < 0 || fstat(in, &st))
		die(argv[5]);
	eslen = st.st_size;
	es = mmap(NULL, eslen, PROT_READ, MAP_PRIVATE, in, 0);
	if (es == MAP_FAILED)
		die("mmap input");
	split();
	if (!nau) {
		fprintf(stderr, "no AUD found: encode with access unit delimiters\n");
		return 2;
	}

	fd = open(argv[1], O_RDWR | O_NONBLOCK);
	if (fd < 0)
		die(argv[1]);
	f.fmt.pix_mp.pixelformat = hevc ? V4L2_PIX_FMT_HEVC : V4L2_PIX_FMT_H264;
	f.fmt.pix_mp.width = atoi(argv[3]);
	f.fmt.pix_mp.height = atoi(argv[4]);
	f.fmt.pix_mp.num_planes = 1;
	f.fmt.pix_mp.plane_fmt[0].sizeimage = OUTSZ;
	if (xioctl(VIDIOC_S_FMT, &f))
		die("S_FMT output");
	if (xioctl(VIDIOC_REQBUFS, &r) || r.count < NOUT)
		die("REQBUFS output");
	for (int i = 0; i < NOUT; i++) {
		struct v4l2_plane pl = {0};
		struct v4l2_buffer b = {.type = OUT, .memory = V4L2_MEMORY_MMAP, .index = i, .m.planes = &pl, .length = 1};
		if (xioctl(VIDIOC_QUERYBUF, &b))
			die("QUERYBUF output");
		outmap[i] = mmap(NULL, pl.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, pl.m.mem_offset);
		if (outmap[i] == MAP_FAILED)
			die("mmap output");
	}
	if (xioctl(VIDIOC_SUBSCRIBE_EVENT, &sub))
		die("subscribe source change");
	sub.type = V4L2_EVENT_EOS;
	xioctl(VIDIOC_SUBSCRIBE_EVENT, &sub);

	printf("%s %s: %d access units, %s\n", argv[2], argv[5], nau, restart ? "restart on source change" : "normal");
	for (int i = 0; i < NOUT; i++)
		queue_out(i);
	if (xioctl(VIDIOC_STREAMON, &t))
		die("STREAMON output");
	stop_if_done();
	progress = now();

	while (!last) {
		struct pollfd p = {.fd = fd, .events = POLLIN | POLLOUT | POLLPRI};
		struct v4l2_event ev;

		if (poll(&p, 1, 100) < 0)
			die("poll");
		if (now() - progress > 5) {
			why = "stall (no event or picture for 5 s)";
			break;
		}
		if (p.revents & POLLPRI) {
			while (!xioctl(VIDIOC_DQEVENT, &ev)) {
				if (ev.type != V4L2_EVENT_SOURCE_CHANGE)
					continue;
				printf("  SOURCE_CHANGE #%d (changes 0x%x) after %d access units\n", ++sc,
				       ev.u.src_change.changes, next_au);
				progress = now();
				if (restart && sc > 1) {
					/* The stream did not change: the firmware re-raised it because the restart
					 * sent it the wrong properties. A client that restarts here again (Steam)
					 * loops forever; iris also refuses a bitstream STREAMOFF in this DRC state. */
					why = "source change raised again after restarting the bitstream port";
					goto end;
				}
				cap_setup();
				if (restart)
					out_restart();
			}
		}
		if (p.revents & POLLOUT) {
			for (;;) {
				struct v4l2_plane pl = {0};
				struct v4l2_buffer b = {.type = OUT, .memory = V4L2_MEMORY_MMAP, .m.planes = &pl, .length = 1};
				if (xioctl(VIDIOC_DQBUF, &b))
					break;
				queue_out(b.index);
				stop_if_done();
			}
		}
		if ((p.revents & POLLIN) && cap_on) {
			for (;;) {
				struct v4l2_plane pl[VIDEO_MAX_PLANES] = {0};
				struct v4l2_buffer b = {.type = CAP, .memory = V4L2_MEMORY_MMAP, .m.planes = pl,
							.length = cap_planes};
				if (xioctl(VIDIOC_DQBUF, &b)) {
					if (errno == EPIPE)
						last = 1;
					break;
				}
				if (pl[0].bytesused) {
					frames++;
					progress = now();
				}
				if (b.flags & V4L2_BUF_FLAG_LAST) {
					last = 1;
					break;
				}
				if (xioctl(VIDIOC_QBUF, &b))
					die("re-QBUF capture");
			}
		}
		if (p.revents & POLLERR)
			usleep(10000);
	}
end:
	ok = last && frames >= nau && sc == 1;
	printf("RESULT %s source_changes=%d frames=%d/%d %s (%s)\n", argv[2], sc, frames, nau,
	       ok ? "PASS" : "FAIL", last ? "drained" : why);
	return ok ? 0 : 1;
}
