// test-no-waitboost.c: unit test for y700-no-waitboost.so, run on the tablet (needs gcc); the shim only acts in a process
// named "chrome", so build the test under two names. Calls ioctl() on /dev/null (fails with ENOTTY, but the shim edits
// the argument first) and checks the flag words. Uses a private XDG_RUNTIME_DIR so the owner's switch file is not touched:
//   gcc -O2 -shared -fPIC -o y700-no-waitboost.so y700-no-waitboost.c -ldl
//   gcc -O2 -o chrome test-no-waitboost.c && cp chrome other; mkdir -p /tmp/nwb-rt
//   XDG_RUNTIME_DIR=/tmp/nwb-rt LD_PRELOAD=$PWD/y700-no-waitboost.so ./chrome active /tmp/nwb-rt/y700-no-waitboost.ctl
//   XDG_RUNTIME_DIR=/tmp/nwb-rt LD_PRELOAD=$PWD/y700-no-waitboost.so ./other      # inert
//   env -u XDG_RUNTIME_DIR LD_PRELOAD=$PWD/y700-no-waitboost.so ./chrome active   # no switch file: always on
// With the shim in /etc/ld.so.preload (the tablet since 10-18) the installed copy would load too and hide a broken one under
// test, so the first check wants exactly one copy mapped. Run isolated (root): prefix each command with
//   unshare -m --propagation private sh -c 'mount --bind /dev/null /etc/ld.so.preload && exec "$@"' _
// (install-no-waitboost.sh does this).
#include <errno.h>
#include <fcntl.h>
#include <linux/ioctl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static int fails;
#define W(x) do { if ((x) < 0) perror(#x); } while (0)
#define CHECK(c, m) do { if (!(c)) { printf("FAIL %s\n", m); fails++; } else printf("ok   %s\n", m); } while (0)

/* how many different files named *y700-no-waitboost* this process has mapped */
static int shim_copies(void)
{
	char line[512], seen[4][256];
	int n = 0, i;
	FILE *f = fopen("/proc/self/maps", "r");
	if (!f)
		return -1;
	while (fgets(line, sizeof line, f)) {
		char *p = strchr(line, '/');
		if (!p || !strstr(p, "y700-no-waitboost"))
			continue;
		p[strcspn(p, "\n")] = 0;
		for (i = 0; i < n && strcmp(seen[i], p); i++)
			;
		if (i == n && n < 4)
			snprintf(seen[n++], sizeof seen[0], "%s", p);
	}
	fclose(f);
	return n;
}

static uint32_t wait(int fd, unsigned nr, unsigned size, int idx, uint32_t flags)
{
	uint32_t buf[16];
	memset(buf, 0, sizeof buf);
	buf[idx] = flags;
	ioctl(fd, _IOC(_IOC_READ | _IOC_WRITE, 'd', nr, size), buf);
	return buf[idx];
}

int main(int argc, char **argv)
{
	int fd = open("/dev/null", O_RDWR);
	int expect_active = argc > 1 && !strcmp(argv[1], "active");
	const char *ctl = argc > 2 ? argv[2] : 0;
	uint32_t all = 0xffu;
	CHECK(shim_copies() == 1, "exactly one copy of the shim mapped (an installed one would hide a broken one under test)");
	if (expect_active) {
		/* real struct sizes (uapi drm.h / msm_drm.h): syncobj_wait 40, timeline_wait 48, wait_fence 24, cpu_prep 16 */
		CHECK(wait(fd, 0xC3, 40, 5, all) == (all & ~8u), "SYNCOBJ_WAIT deadline bit dropped, others kept");
		CHECK(wait(fd, 0xCA, 48, 7, all) == (all & ~8u), "TIMELINE_WAIT deadline bit dropped, others kept");
		CHECK(wait(fd, 0x40 + 0x07, 24, 1, all) == (all & ~1u), "MSM_WAIT_FENCE boost dropped");
		CHECK(wait(fd, 0x40 + 0x04, 16, 1, all) == (all & ~8u), "MSM_GEM_CPU_PREP boost dropped");
		CHECK(wait(fd, 0xC3, 16, 5, all) == all, "undersized struct untouched");
		CHECK(wait(fd, 0xCA, 28, 7, all) == all, "undersized timeline struct untouched");
		CHECK(wait(fd, 0xC4, 40, 5, all) == all, "other nr untouched");
		{
			uint32_t buf[16];
			memset(buf, 0xff, sizeof buf);
			ioctl(fd, _IOC(_IOC_READ | _IOC_WRITE, 'X', 0xCA, 48), buf);
			CHECK(buf[7] == 0xffffffffu, "other ioctl type untouched");
			errno = 0;
			CHECK(ioctl(fd, _IOC(_IOC_READ | _IOC_WRITE, 'd', 0xCA, 48), buf) == -1 && errno == ENOTTY,
			      "result and errno of the real ioctl passed back");
			CHECK(ioctl(fd, _IOC(_IOC_READ | _IOC_WRITE, 'd', 0xCA, 48), (void *)0) == -1, "NULL argument: no crash");
		}
		if (ctl) {
			int c = open(ctl, O_RDWR);
			W(pwrite(c, "Y0", 2, 0));
			usleep(250000);
			CHECK(wait(fd, 0xCA, 48, 7, all) == all, "Y0: hints pass through");
			W(ftruncate(c, 0));
			usleep(250000);
			CHECK(wait(fd, 0xCA, 48, 7, all) == all, "truncated switch: last state kept (no crash)");
			W(pwrite(c, "Y1", 2, 0));
			usleep(250000);
			CHECK(wait(fd, 0xCA, 48, 7, all) == (all & ~8u), "Y1: hints dropped again");
			W(pwrite(c, "Y0", 2, 0));
			usleep(250000);
			CHECK(wait(fd, 0xCA, 48, 7, all) == all, "Y0 again: hints pass through");
			usleep(250000);
			W(pwrite(c, "Xx", 2, 0));
			usleep(250000);
			CHECK(wait(fd, 0xCA, 48, 7, all) == all, "bad magic: last state kept");
			W(pwrite(c, "Y1", 2, 0));
		}
	} else {
		CHECK(wait(fd, 0xC3, 40, 5, all) == all, "inert process: SYNCOBJ_WAIT untouched");
		CHECK(wait(fd, 0xCA, 48, 7, all) == all, "inert process: TIMELINE_WAIT untouched");
		CHECK(wait(fd, 0x40 + 0x07, 24, 1, all) == all, "inert process: MSM_WAIT_FENCE untouched");
	}
	printf("%s\n", fails ? "FAILED" : "PASSED");
	return fails != 0;
}
