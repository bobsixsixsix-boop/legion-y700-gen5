// dczva-selftest.c: EL0 self-test for the Qualcomm Oryon DC ZVA workaround (kernel patch 1044, y11).
//
// Build on the tablet:  cc -O2 -o dczva-selftest dczva-selftest.c      (clang 18 or gcc; no root needed to build)
// Run:                  dczva-selftest [--expect-dze] [-n ITER]       (root only for the debugfs counter check)
//
// Default mode (workaround expected active):
//   DCZID_EL0.DZP reads 1 at EL0 (SCTLR_EL1.DZE clear);  a "dc zva" still zeroes exactly one block (the kernel
//   emulates the trapped instruction), also through a TBI-tagged pointer;  dc zva on a read-only page gets
//   SIGSEGV/SEGV_ACCERR and on an unmapped page SIGSEGV (si_code not asserted: the kernel's arm64_notify_segfault()
//   reports MAPERR only for holes above the last mapping, native hardware reports MAPERR always);  the counter
//   /sys/kernel/debug/qcom_oryon_dc_zva_emulated grows by the number of dc zva executed (only checked when readable);
//   prints the measured cost per emulated instruction.
// --expect-dze (kernel booted with qcom_oryon_dc_zva=off, or without 1044):
//   DZP reads 0, dc zva runs natively (same functional checks), the debugfs counter file must be absent.
// Exit 0 = every check passed, 1 = at least one FAIL. One PASS/FAIL/INFO line per check, grep-friendly.
#define _GNU_SOURCE
#include <errno.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static sigjmp_buf jb;
static volatile int got_sig, got_code;
static volatile uintptr_t got_addr;

static void on_sig(int sig, siginfo_t *si, void *uc)
{
	(void)uc;
	got_sig = sig;
	got_code = si->si_code;
	got_addr = (uintptr_t)si->si_addr;
	siglongjmp(jb, 1);
}

static inline uint64_t read_dczid(void)
{
	uint64_t v;
	asm volatile("mrs %0, dczid_el0" : "=r"(v));
	return v;
}

static inline void dc_zva(const void *p)
{
	asm volatile("dc zva, %0" : : "r"(p) : "memory");
}

static long read_counter(void)
{
	FILE *f = fopen("/sys/kernel/debug/qcom_oryon_dc_zva_emulated", "r");
	long v = -1;

	if (!f)
		return -1;
	if (fscanf(f, "%ld", &v) != 1)
		v = -1;
	fclose(f);
	return v;
}

static int fail;
#define CHECK(cond, ...) do { int _ok = !!(cond); printf("%s  ", _ok ? "PASS" : "FAIL"); printf(__VA_ARGS__); printf("\n"); if (!_ok) fail = 1; } while (0)
#define INFO(...) do { printf("INFO  "); printf(__VA_ARGS__); printf("\n"); } while (0)

/* run dc_zva(p) under the signal catcher; returns 0 if it completed, else the signal number */
static int try_zva(const void *p)
{
	got_sig = 0;
	if (sigsetjmp(jb, 1) == 0) {
		dc_zva(p);
		asm volatile("dsb ish" ::: "memory");
		return 0;
	}
	return got_sig;
}

static int all_bytes(const unsigned char *p, size_t n, unsigned char v)
{
	for (size_t i = 0; i < n; i++)
		if (p[i] != v)
			return 0;
	return 1;
}

int main(int argc, char **argv)
{
	int expect_dze = 0;
	long iters = 200000;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--expect-dze"))
			expect_dze = 1;
		else if (!strcmp(argv[i], "-n") && i + 1 < argc)
			iters = atol(argv[++i]);
		else {
			fprintf(stderr, "usage: %s [--expect-dze] [-n ITER]\n", argv[0]);
			return 2;
		}
	}

	struct sigaction sa = { 0 };
	sa.sa_sigaction = on_sig;
	sa.sa_flags = SA_SIGINFO;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGSEGV, &sa, NULL);
	sigaction(SIGBUS, &sa, NULL);
	sigaction(SIGILL, &sa, NULL);

	uint64_t id = read_dczid();
	int dzp = (id >> 4) & 1;
	size_t bs = (size_t)4 << (id & 0xf);
	INFO("DCZID_EL0=0x%llx: block size %zu bytes, DZP=%d (%s)", (unsigned long long)id, bs, dzp,
	     dzp ? "EL0 sees DC ZVA prohibited" : "DC ZVA enabled at EL0");
	if (expect_dze)
		CHECK(dzp == 0, "DZP=0: workaround off, DC ZVA native (expected with qcom_oryon_dc_zva=off / no 1044)");
	else
		CHECK(dzp == 1, "DZP=1: SCTLR_EL1.DZE is clear, user space is told not to use DC ZVA (1044 active)");
	long pg = sysconf(_SC_PAGESIZE);
	CHECK(bs >= 16 && bs <= 2048 && (long)bs < pg, "plausible block size %zu (page %ld)", bs, pg);
	if (!(bs >= 16 && bs <= 2048 && (long)bs < pg)) {
		printf("SOME FAILED\n");
		return 1;
	}
	unsigned char *m = mmap(NULL, 3 * pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (m == MAP_FAILED) {
		perror("mmap");
		return 2;
	}
	memset(m, 0xA5, 3 * pg);
	long c0 = read_counter();
	long zvas = 0;

	/* 1. functional: an unaligned pointer inside a block of page 1 zeroes exactly that block. Page 0 below and page 2
	 * above stay 0xA5, so blk[-1] / blk[bs] are always inside the mapping; the offsets are clamped so that this block
	 * and blk2 (test 2) stay inside page 1 for any block size up to the page size. */
	size_t off = (8 * bs <= (size_t)pg / 2) ? 8 * bs : 0;
	unsigned char *blk = (unsigned char *)(((uintptr_t)(m + pg) + off) & ~(uintptr_t)(bs - 1));
	int sig = try_zva(blk + 5);
	zvas++;
	CHECK(sig == 0, "dc zva on a writable page completes without a signal%s", sig ? " (got signal)" : "");
	if (sig == 0) {
		CHECK(all_bytes(blk, bs, 0), "the %zu-byte block containing the address is all zero", bs);
		CHECK(blk[-1] == 0xA5 && blk[bs] == 0xA5, "the bytes just outside the block are untouched (0xA5)");
	}

	/* 2. TBI: a pointer with a top-byte tag must zero the same way (the trap handler untags; hardware ignores TBI bits) */
	unsigned char *blk2 = blk + ((off + 5 * bs <= (size_t)pg) ? 4 * bs : bs);
	uintptr_t tagged = (uintptr_t)blk2 | ((uintptr_t)0x5a << 56);
	sig = try_zva((const void *)tagged);
	zvas++;
	CHECK(sig == 0 && all_bytes(blk2, bs, 0) && blk2[-1] == 0xA5 && blk2[bs] == 0xA5,
	      "dc zva through a tagged pointer (top byte 0x5a) zeroes exactly one block");

	/* 3a. read-only page: SIGSEGV with SEGV_ACCERR, fault address inside that page */
	unsigned char *ro = m + 2 * pg;
	if (mprotect(ro, pg, PROT_READ) != 0) {
		perror("mprotect");
		return 2;
	}
	sig = try_zva(ro + bs);
	zvas++;
	CHECK(sig == SIGSEGV && got_code == SEGV_ACCERR, "dc zva on a read-only page -> SIGSEGV/SEGV_ACCERR (got sig %d code %d)", sig, got_code);
	CHECK(sig && got_addr >= (uintptr_t)ro && got_addr < (uintptr_t)ro + pg, "fault address 0x%lx lies in the read-only page", (unsigned long)got_addr);
	CHECK(all_bytes(ro, pg, 0xA5), "read-only page unchanged");

	/* 3b. unmapped page: SIGSEGV. si_code is informational only: emulated, arm64_notify_segfault() derives it from
	 * find_vma(), which yields SEGV_ACCERR for a hole that has a mapping above it; native hardware says SEGV_MAPERR. */
	unsigned char *gone = mmap(NULL, pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (gone == MAP_FAILED || munmap(gone, pg) != 0) {
		perror("mmap/munmap");
		return 2;
	}
	sig = try_zva(gone + ((2 * bs < (size_t)pg) ? 2 * bs : 0));   /* stay inside the unmapped page for any block size */
	zvas++;
	CHECK(sig == SIGSEGV, "dc zva on an unmapped page -> SIGSEGV (got sig %d, si_code %d = %s)", sig, got_code,
	      got_code == SEGV_MAPERR ? "MAPERR" : got_code == SEGV_ACCERR ? "ACCERR (emulation quirk, fine)" : "other");

	/* 4. cost: iters x dc zva on one block; with the workaround each one is a trap + emulation */
	struct timespec t0, t1;
	clock_gettime(CLOCK_MONOTONIC, &t0);
	for (long i = 0; i < iters; i++)
		dc_zva(blk);
	asm volatile("dsb ish" ::: "memory");
	clock_gettime(CLOCK_MONOTONIC, &t1);
	zvas += iters;
	double ns = ((t1.tv_sec - t0.tv_sec) * 1e9 + (t1.tv_nsec - t0.tv_nsec)) / (double)iters;
	INFO("%ld x dc zva: %.1f ns each (%.0f MB/s of zeroing)%s", iters, ns, bs * 1e9 / ns / 1e6,
	     dzp ? "  <- trap + emulation cost" : "  <- native");
	CHECK(all_bytes(blk, bs, 0), "block still zero after the loop");

	/* 5. the debugfs counter (root): must grow by exactly our count, give or take other processes' traps */
	long c1 = read_counter();
	if (expect_dze) {
		CHECK(c0 < 0 && c1 < 0, "/sys/kernel/debug/qcom_oryon_dc_zva_emulated absent (workaround not active)");
	} else if (c0 < 0) {
		if (geteuid() == 0)
			CHECK(0, "/sys/kernel/debug/qcom_oryon_dc_zva_emulated not readable as root: workaround not active or debugfs not mounted");
		else
			INFO("counter check skipped (not root); as root it must grow by %ld", zvas);
	} else {
		CHECK(c1 - c0 >= zvas, "debugfs counter grew by %ld (we executed %ld dc zva)", c1 - c0, zvas);
		CHECK(c1 - c0 <= zvas + 1000, "and not by wildly more (%ld): nothing else is hammering DC ZVA", c1 - c0);
	}

	printf("%s\n", fail ? "SOME FAILED" : "ALL PASS");
	return fail;
}
