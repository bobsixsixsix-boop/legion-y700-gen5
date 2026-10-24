// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * dczva-stress.c - DC ZVA x cluster/system power-collapse reproducer for the
 * Y700 Gen5 (kaanapali, Oryon v3, part 0x002) idle experiment E2 (PROTOCOL.md
 * §3 E2, RESEARCH.md §2.4 H2 and §3.4). Hypothesis H2: a DC ZVA erratum like the
 * one icecream95/x1e-crash reproduces on Snapdragon X Elite (Oryon X1, part
 * 0x001). This reproduces the x1e-crash instruction sequence AND adds a data
 * check around a real cluster-idle window, so it can report BOTH outcomes:
 *
 *   (1) hang/reset   - the SoC hangs and the firmware resets it. This program
 *                      cannot print after that; the last mismatch record (if
 *                      any) and the flight recorder's last line are the
 *                      evidence. We write to /dev/pmsg0 when it is writable so
 *                      the record survives the reset (pstore pmsg ring).
 *   (2) corruption   - a block zeroed with DC ZVA loses its zeros (stale,
 *                      pre-ZVA data reappears) after the cluster powered down
 *                      and back up. This is the erratum signature and it is
 *                      caught by the second compare below; it does NOT need a
 *                      reset to be observed.
 *
 * Per-thread sequence (one thread pinned per CPU), matching RESEARCH.md §3.4:
 *   - pick a target block (DC ZVA block size, from DCZID_EL0) in a PRIVATE
 *     anonymous mapping; store a pointer to it in a SEPARATE cache line (ref),
 *     the "another address/line" the 64 bytes are read back through, as in
 *     x1e-crash (str/ref/alloc dance);
 *   - fill the target with a non-zero per-iteration pattern, so that after the
 *     clean below DRAM holds that pattern: if the zeroed line is dropped across
 *     the power event the stale pattern reappears and we can see it;
 *   - DC CIVAC the ref line and the target (clean+invalidate to PoC): the
 *     pattern is pushed to DRAM and the lines are invalidated. DC CIVAC from
 *     EL0 is allowed when SCTLR_EL1.UCI=1, which Linux sets; if it were unset
 *     the kernel emulates DC CIVAC in its EL0 cache-maintenance trap handler,
 *     so this never faults on Linux;
 *   - store 0 to the first byte (as x1e-crash does), then DC ZVA the block;
 *   - dsb ish so the zeroing is complete, then the FIRST dependent read: load
 *     s = *ref and byte-compare s[0..bs) with zero (immediate check: catches a
 *     broken DC ZVA right away, before any idle);
 *   - all threads rendezvous on a barrier and clock_nanosleep together for
 *     --idle-ms ms (default 12 ms > 10.15 ms ss3 min-residency, > 9.144 ms cl5)
 *     so the whole cluster/system really idles and powers down;
 *   - after the idle, a hardware+compiler barrier, then the SECOND dependent
 *     read of the same block: byte-compare with zero again. A non-zero byte
 *     here is the erratum signature (zeros lost / stale data after the cluster
 *     power event).
 *
 * The compare reads go through VOLATILE pointers and are separated from the
 * idle by an external call (clock_nanosleep), a pthread barrier and an explicit
 * "dsb ish"/"memory" barrier, so the compiler cannot hoist the second compare
 * before the idle nor fold the two compares together. See the self-review notes
 * at the end of this file.
 *
 * Unprivileged: anonymous mmap, sched_setaffinity, clock_nanosleep, sync() -
 * no root, no sysfs writes. /dev/pmsg0 is opened best-effort (0220, needs the
 * flightrec group or root) and is simply skipped when it cannot be opened.
 *
 * Build (on the tablet, clang 18 or gcc):   cc -O2 -pthread -o dczva-stress dczva-stress.c
 * Self-test (no reset expected):            ./dczva-stress -t 20        (expect "0 mismatches", exit 0)
 *
 * Options:
 *   -t SECONDS     total run time (default 1800)
 *   -c CPULIST     e.g. 0,1,2,6 or 0-5 (default: every CPU in the affinity mask)
 *   --cluster 0|1  only that cluster's CPUs (cluster 0 = the 6 medium cores,
 *                  cluster 1 = the 2 prime cores on kaanapali; derived from
 *                  sysfs topology, with a documented fallback). The single-
 *                  cluster variant of RESEARCH.md §3.2.
 *   --idle-ms N    idle window in ms between bursts (default 12)
 *   --no-idle      continuous mode: no idle window (the old mode); only the
 *                  immediate compare runs, so the cross-idle signature cannot
 *                  appear - use as the E1-like control.
 *   -m MiB         private buffer per thread (default 4)
 *   -o FILE        mismatch record file (default ./dczva-mismatch.log)
 *   -k             keep going after a mismatch (default: stop on the first)
 *   -q             quiet (no periodic status line)
 *   -h             help
 *
 * Exit code: 0 clean, 2 at least one mismatch, 1 usage / DC ZVA prohibited.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

/* ----- architecture primitives ------------------------------------------- */
#if defined(__aarch64__)
static inline void dc_civac(void *p) { __asm__ volatile("dc civac, %0" : : "r"(p) : "memory"); }
static inline void dc_zva(void *p)   { __asm__ volatile("dc zva, %0"   : : "r"(p) : "memory"); }
static inline void dsb_ish(void)     { __asm__ volatile("dsb ish"      : : : "memory"); }
static inline void isb_(void)        { __asm__ volatile("isb"          : : : "memory"); }
static inline uint64_t read_dczid(void)
{
	uint64_t v;
	__asm__ volatile("mrs %0, dczid_el0" : "=r"(v));
	return v;
}
#else
/*
 * Host fallback: lets the C logic be syntax-/logic-checked on a non-aarch64
 * box. It is NOT a real reproducer (plain memset, no cache maintenance, no
 * power events) and the tablet build always takes the __aarch64__ path above.
 */
#warning "dczva-stress built for a non-aarch64 host: logic-test stub only, not a reproducer"
static inline void dc_civac(void *p) { (void)p; __asm__ volatile("" : : : "memory"); }
static inline void dc_zva(void *p)   { /* emulate: zero a 64-byte block */ memset((void *)((uintptr_t)p & ~(uintptr_t)63), 0, 64); __asm__ volatile("" : : : "memory"); }
static inline void dsb_ish(void)     { __asm__ volatile("" : : : "memory"); }
static inline void isb_(void)        { __asm__ volatile("" : : : "memory"); }
static inline uint64_t read_dczid(void) { return 4; /* BS=4 -> 64-byte block, DZP=0 */ }
#endif

/* ----- configuration & shared state -------------------------------------- */
#define GUARD		4096u		/* pattern-filled guard band each side */
#define GUARD_BYTE	0x5Au		/* guard fill */
#define WORK_ALIGN	4096u		/* align the ZVA work region to a page */

static size_t g_bufbytes = (size_t)4 << 20;	/* -m: private buffer per thread */
static int    g_secs = 1800;			/* -t */
static int    g_idle_ms = 12;			/* --idle-ms */
static int    g_no_idle = 0;			/* --no-idle */
static int    g_keep_going = 0;			/* -k */
static int    g_quiet = 0;			/* -q */
static const char *g_recfile = "dczva-mismatch.log";	/* -o */

static size_t g_bs;			/* DC ZVA block size, bytes (uniform SoC) */
static uint64_t g_t_end_ns;
static int g_nthreads;			/* actual thread count == barrier count */

static atomic_ulong g_iters;		/* total target blocks tested */
static atomic_ulong g_mismatches;
static atomic_int g_stop;		/* set by a worker (mismatch) or main */
static atomic_int g_go;			/* start gate: workers wait for main */

static pthread_barrier_t g_bar;		/* idle-mode rendezvous */
static int g_round_stop;		/* written only by the serial thread between B1/B2 (B3/B4) */

static int g_pmsg = -1;			/* /dev/pmsg0, or -1 */
static FILE *g_rec;			/* mismatch record file, opened on first hit */
static pthread_mutex_t g_rec_lock = PTHREAD_MUTEX_INITIALIZER;

static uint64_t now_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* Sleep to an absolute CLOCK_MONOTONIC deadline, restarting on EINTR so the
 * whole idle window is spent asleep even if a signal fires. */
static void sleep_until(uint64_t deadline_ns)
{
	struct timespec dl = { (time_t)(deadline_ns / 1000000000ull),
			       (long)(deadline_ns % 1000000000ull) };
	int r;
	do {
		r = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &dl, NULL);
	} while (r == EINTR);
}

/* ----- mismatch reporting ------------------------------------------------- */
static void report_mismatch(int cpu, int cluster, const char *phase,
			    unsigned long iter, const void *target,
			    size_t off, unsigned expected, unsigned seen)
{
	char msg[256];
	int n;

	n = snprintf(msg, sizeof msg,
		     "DCZVA MISMATCH cpu=%d cluster=%d phase=%s iter=%lu target=%p "
		     "off=0x%zx expected=0x%02x seen=0x%02x bs=%zu total_iters=%lu\n",
		     cpu, cluster, phase, iter, target, off, expected, seen,
		     g_bs, (unsigned long)atomic_load(&g_iters));
	if (n < 0)
		return;
	if ((size_t)n >= sizeof msg)
		n = (int)sizeof msg - 1;

	pthread_mutex_lock(&g_rec_lock);
	fputs(msg, stderr);
	fflush(stderr);
	if (!g_rec) {
		g_rec = fopen(g_recfile, "ae");	/* append, close-on-exec */
		if (g_rec) {
			time_t t = time(NULL);
			char ts[64];
			struct tm tmv;
			if (localtime_r(&t, &tmv) &&
			    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", &tmv))
				fprintf(g_rec, "# run start-of-record %s\n", ts);
		}
	}
	if (g_rec) {
		fputs(msg, g_rec);
		fflush(g_rec);
	}
	if (g_pmsg >= 0) {
		ssize_t w = write(g_pmsg, msg, (size_t)n);
		(void)w;
	}
	pthread_mutex_unlock(&g_rec_lock);

	atomic_fetch_add(&g_mismatches, 1);
	if (!g_keep_going)
		atomic_store(&g_stop, 1);
}

/* ----- worker ------------------------------------------------------------- */
struct worker {
	int cpu;
	int cluster;
	pthread_t th;
	int created;
	uint8_t *base;		/* mmap'd buffer, allocated by main */
	unsigned long iters;
};

/*
 * Compare the target block, read back through the dependent pointer stored in
 * the ref line (a volatile load, so it is a real reload from memory). Returns
 * the offset of the first non-zero byte, or (size_t)-1 if all zero. 'seen' is
 * filled with the offending byte.
 */
static size_t compare_zero(uint8_t *const volatile *ref, unsigned *seen)
{
	const volatile uint8_t *s = *ref;	/* dependent load */
	size_t i;
	for (i = 0; i < g_bs; i++) {
		uint8_t b = s[i];		/* volatile: real load, ordered */
		if (b) {
			*seen = b;
			return i;
		}
	}
	return (size_t)-1;
}

static int guard_ok(const uint8_t *base, size_t total)
{
	size_t i;
	for (i = 0; i < GUARD; i++)
		if (base[i] != GUARD_BYTE || base[total - 1 - i] != GUARD_BYTE)
			return 0;
	return 1;
}

static void *worker_fn(void *arg)
{
	struct worker *w = arg;
	cpu_set_t set;
	size_t total = g_bufbytes;
	uint8_t *base = w->base;
	/* layout: [GUARD][ref line (64B)][gap to WORK_ALIGN][work region][GUARD] */
	size_t work_off = (GUARD + 64 + (WORK_ALIGN - 1)) & ~(size_t)(WORK_ALIGN - 1);
	uint8_t *work = base + work_off;
	size_t work_bytes = total - work_off - GUARD;
	size_t nblocks = work_bytes / g_bs;
	/* ref lives in its own cache line just after the front guard */
	uint8_t *const volatile *refpp;
	uint8_t **refslot = (uint8_t **)(base + GUARD);
	unsigned long blk = 0;

	refpp = (uint8_t *const volatile *)refslot;

	CPU_ZERO(&set);
	CPU_SET(w->cpu, &set);
	if (sched_setaffinity(0, sizeof set, &set))
		fprintf(stderr, "cpu%d: warning: sched_setaffinity: %s (running unpinned)\n",
			w->cpu, strerror(errno));

	if (nblocks == 0) {
		fprintf(stderr, "cpu%d: buffer too small for one ZVA block\n", w->cpu);
		atomic_store(&g_stop, 1);
		nblocks = 1;	/* avoid divide-by-zero below; loop will exit on g_stop */
	}

	/* wait for main to finish setup / barrier init */
	while (!atomic_load(&g_go))
		sleep_until(now_ns() + 1000000ull);	/* 1 ms */

	for (;;) {
		uint8_t *target = work + (blk % nblocks) * g_bs;
		uint8_t pat = (uint8_t)(0x80u | (blk & 0x7fu));	/* non-zero, varies */
		size_t off;
		unsigned seen = 0;

		if (pat == 0)
			pat = 0xA5;

		/* prepare: pattern -> target, pointer -> ref, both into DRAM */
		memset(target, pat, g_bs);
		*refslot = target;			/* ref -> target (separate line) */
		(void)*(volatile uint8_t *)target;	/* touch (x1e-crash ACCESS) */
		dc_civac(refslot);			/* clean+invalidate ref line */
		dc_civac(target);			/* clean+invalidate target: pat now in DRAM */
		dsb_ish();
		isb_();

		/* the sequence under test */
		*(volatile uint8_t *)target = 0;	/* x1e-crash: *alloc = 0 */
		isb_();
		dc_zva(target);				/* zero the whole block */
		isb_();
		dsb_ish();				/* ZVA complete before the read */

		/* FIRST compare: immediate, through the dependent ref pointer */
		off = compare_zero(refpp, &seen);
		if (off != (size_t)-1)
			report_mismatch(w->cpu, w->cluster, "after-zva", w->iters,
					target, off, 0, seen);

		w->iters++;
		atomic_fetch_add(&g_iters, 1);
		blk++;

		if (g_no_idle) {
			if (atomic_load(&g_stop) || now_ns() >= g_t_end_ns)
				break;
			continue;
		}

		/* ---- barrier-synchronised idle so the whole cluster powers down ---- */
		{
			int s = pthread_barrier_wait(&g_bar);		/* B1 */
			if (s == PTHREAD_BARRIER_SERIAL_THREAD)
				g_round_stop = atomic_load(&g_stop) || now_ns() >= g_t_end_ns;
			pthread_barrier_wait(&g_bar);			/* B2: publish */
			if (g_round_stop)
				break;
		}

		sleep_until(now_ns() + (uint64_t)g_idle_ms * 1000000ull);

		/* order everything after the idle: compiler + hardware barrier */
		__asm__ volatile("" : : : "memory");
		dsb_ish();

		/* SECOND compare: the erratum signature (zeros lost across the idle) */
		off = compare_zero(refpp, &seen);
		if (off != (size_t)-1)
			report_mismatch(w->cpu, w->cluster, "after-idle", w->iters - 1,
					target, off, 0, seen);

		/* guard bands intact? (cheap, catches a stray ZVA address) */
		if (!guard_ok(base, total))
			report_mismatch(w->cpu, w->cluster, "guard", w->iters - 1,
					base, 0, GUARD_BYTE, 0);

		{
			int s = pthread_barrier_wait(&g_bar);		/* B3 */
			if (s == PTHREAD_BARRIER_SERIAL_THREAD)
				g_round_stop = atomic_load(&g_stop) || now_ns() >= g_t_end_ns;
			pthread_barrier_wait(&g_bar);			/* B4: publish */
			if (g_round_stop)
				break;
		}
	}
	return NULL;
}

/* ----- CPU list / topology ------------------------------------------------ */
static int cpu_online_mask(cpu_set_t *mask)
{
	CPU_ZERO(mask);
	if (sched_getaffinity(0, sizeof *mask, mask) == 0)
		return CPU_COUNT(mask);
	return 0;
}

static int read_cluster_id(int cpu)
{
	char path[128];
	FILE *f;
	int id = -1;
	snprintf(path, sizeof path,
		 "/sys/devices/system/cpu/cpu%d/topology/cluster_id", cpu);
	f = fopen(path, "re");
	if (f) {
		if (fscanf(f, "%d", &id) != 1)
			id = -1;
		fclose(f);
	}
	return id;
}

/*
 * Fill cpus[] with the CPUs of the given cluster (0 or 1). Prefer sysfs
 * topology/cluster_id (the k-th distinct id in ascending order). If that is
 * unavailable or degenerate, fall back to the documented kaanapali split:
 * cluster 0 = cpu0..5 (medium), cluster 1 = cpu6..7 (prime).
 */
static int cpus_of_cluster(int which, const cpu_set_t *avail, int *cpus, int max)
{
	int ids[CPU_SETSIZE], nids = 0, c, n = 0;
	int target_id = -1;

	for (c = 0; c < CPU_SETSIZE; c++) {
		if (!CPU_ISSET(c, avail))
			continue;
		int id = read_cluster_id(c);
		if (id < 0) { nids = 0; break; }	/* bail to fallback */
		int j, found = 0;
		for (j = 0; j < nids; j++)
			if (ids[j] == id) { found = 1; break; }
		if (!found && nids < CPU_SETSIZE)
			ids[nids++] = id;
	}
	if (nids >= 2) {
		/* sort distinct ids ascending (tiny, insertion) */
		for (int i = 1; i < nids; i++) {
			int k = ids[i], j = i - 1;
			while (j >= 0 && ids[j] > k) { ids[j + 1] = ids[j]; j--; }
			ids[j + 1] = k;
		}
		if (which < nids)
			target_id = ids[which];
	}
	if (target_id >= 0) {
		for (c = 0; c < CPU_SETSIZE && n < max; c++)
			if (CPU_ISSET(c, avail) && read_cluster_id(c) == target_id)
				cpus[n++] = c;
		return n;
	}
	/* fallback: documented kaanapali split at cpu6 */
	for (c = 0; c < CPU_SETSIZE && n < max; c++) {
		if (!CPU_ISSET(c, avail))
			continue;
		if ((which == 0 && c <= 5) || (which == 1 && c >= 6))
			cpus[n++] = c;
	}
	fprintf(stderr, "note: cluster_id topology unavailable; using fallback split (cluster0=cpu0-5, cluster1=cpu6-7)\n");
	return n;
}

static int parse_cpulist(const char *s, int *cpus, int max)
{
	int n = 0;
	char *dup = strdup(s), *tok, *save = NULL;
	if (!dup)
		return 0;
	for (tok = strtok_r(dup, ",", &save); tok && n < max; tok = strtok_r(NULL, ",", &save)) {
		char *dash = strchr(tok, '-');
		int a = atoi(tok), b = dash ? atoi(dash + 1) : a;
		for (int c = a; c <= b && n < max; c++)
			if (c >= 0 && c < CPU_SETSIZE)
				cpus[n++] = c;
	}
	free(dup);
	return n;
}

static void usage(const char *argv0)
{
	fprintf(stderr,
		"usage: %s [-t secs] [-c cpulist] [--cluster 0|1] [--idle-ms N]\n"
		"          [--no-idle] [-m MiB] [-o file] [-k] [-q]\n", argv0);
}

enum { OPT_CLUSTER = 1000, OPT_IDLE_MS, OPT_NO_IDLE };

int main(int argc, char **argv)
{
	static const struct option longopts[] = {
		{ "cluster", required_argument, NULL, OPT_CLUSTER },
		{ "idle-ms", required_argument, NULL, OPT_IDLE_MS },
		{ "no-idle", no_argument,       NULL, OPT_NO_IDLE },
		{ 0, 0, 0, 0 }
	};
	int cpus[CPU_SETSIZE], ncpu = 0, opt, cluster = -1;
	const char *cpulist = NULL;
	cpu_set_t avail;
	struct worker *ws;
	uint64_t dczid, t_start;
	uint64_t next_status;
	int i;

	while ((opt = getopt_long(argc, argv, "t:c:m:o:kqh", longopts, NULL)) != -1) {
		switch (opt) {
		case 't': g_secs = atoi(optarg); break;
		case 'c': cpulist = optarg; break;
		case 'm': g_bufbytes = (size_t)atoi(optarg) << 20; break;
		case 'o': g_recfile = optarg; break;
		case 'k': g_keep_going = 1; break;
		case 'q': g_quiet = 1; break;
		case OPT_CLUSTER: cluster = atoi(optarg); break;
		case OPT_IDLE_MS: g_idle_ms = atoi(optarg); break;
		case OPT_NO_IDLE: g_no_idle = 1; break;
		case 'h': usage(argv[0]); return 0;
		default: usage(argv[0]); return 1;
		}
	}
	if (g_secs <= 0 || g_idle_ms <= 0 || g_bufbytes < (1u << 20)) {
		fprintf(stderr, "bad -t/--idle-ms/-m\n");
		return 1;
	}
	if (cluster >= 0 && cpulist) {
		fprintf(stderr, "use either -c or --cluster, not both\n");
		return 1;
	}

	dczid = read_dczid();
	if (dczid & (1u << 4)) {	/* DZP: DC ZVA prohibited at EL0 */
		fprintf(stderr,
			"DC ZVA is prohibited at EL0 (DCZID_EL0.DZP=1): the Oryon DC ZVA\n"
			"workaround (SCTLR_EL1.DZE cleared) is active, or this CPU does not\n"
			"allow EL0 DC ZVA. Nothing to reproduce; exiting.\n");
		return 1;
	}
	g_bs = (size_t)4 << (dczid & 0xf);	/* block size in bytes */

	cpu_online_mask(&avail);
	if (cluster >= 0)
		ncpu = cpus_of_cluster(cluster, &avail, cpus, CPU_SETSIZE);
	else if (cpulist)
		ncpu = parse_cpulist(cpulist, cpus, CPU_SETSIZE);
	else
		for (i = 0; i < CPU_SETSIZE; i++)
			if (CPU_ISSET(i, &avail))
				cpus[ncpu++] = i;
	/* keep only CPUs we are actually allowed to run on */
	{
		int keep = 0;
		for (i = 0; i < ncpu; i++)
			if (CPU_ISSET(cpus[i], &avail))
				cpus[keep++] = cpus[i];
			else
				fprintf(stderr, "note: cpu%d not in affinity mask, dropped\n", cpus[i]);
		ncpu = keep;
	}
	if (ncpu <= 0) {
		fprintf(stderr, "no usable CPUs\n");
		return 1;
	}

	ws = calloc((size_t)ncpu, sizeof *ws);
	if (!ws)
		return 1;

	/* allocate and pre-fault each buffer in MAIN so workers cannot fail setup
	 * (that would wreck the barrier count). */
	for (i = 0; i < ncpu; i++) {
		uint8_t *b = mmap(NULL, g_bufbytes, PROT_READ | PROT_WRITE,
				  MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE, -1, 0);
		if (b == MAP_FAILED) {
			fprintf(stderr, "mmap (%zu bytes) for cpu%d: %s\n",
				g_bufbytes, cpus[i], strerror(errno));
			return 1;
		}
		memset(b, GUARD_BYTE, g_bufbytes);	/* fill guards + fault pages in */
		ws[i].cpu = cpus[i];
		ws[i].cluster = read_cluster_id(cpus[i]);
		ws[i].base = b;
	}

	g_pmsg = open("/dev/pmsg0", O_WRONLY | O_CLOEXEC);	/* best effort */

	if (!g_quiet)
		printf("dczva-stress: %d cpus, zva block %zu B, %zu MiB/thread, "
		       "%s, idle %d ms, %d s\n",
		       ncpu, g_bs, g_bufbytes >> 20,
		       g_no_idle ? "NO-IDLE (control)" : "barrier-idle",
		       g_idle_ms, g_secs);

	/* create threads (gated), then size the barrier to the real count */
	atomic_store(&g_go, 0);
	for (i = 0; i < ncpu; i++) {
		int e = pthread_create(&ws[i].th, NULL, worker_fn, &ws[i]);
		if (e) {
			fprintf(stderr, "pthread_create cpu%d: %s\n", cpus[i], strerror(e));
			ws[i].created = 0;
		} else {
			ws[i].created = 1;
			g_nthreads++;
		}
	}
	if (g_nthreads == 0) {
		fprintf(stderr, "no threads started\n");
		return 1;
	}
	if (!g_no_idle)
		pthread_barrier_init(&g_bar, NULL, (unsigned)g_nthreads);

	t_start = now_ns();
	g_t_end_ns = t_start + (uint64_t)g_secs * 1000000000ull;
	next_status = t_start + 30000000000ull;

	sync();				/* flush filesystems before we risk a reset */
	atomic_store(&g_go, 1);		/* release the workers */

	/* main status loop: print, and set g_stop at the deadline as a safety net
	 * (workers only ACT on g_stop at synchronised points, so this is race-free). */
	while (!atomic_load(&g_stop) && now_ns() < g_t_end_ns) {
		sleep_until(now_ns() + 200000000ull);	/* 200 ms */
		if (!g_quiet && now_ns() >= next_status) {
			printf("  +%4llus iters %lu mismatches %lu\n",
			       (unsigned long long)((now_ns() - t_start) / 1000000000ull),
			       (unsigned long)atomic_load(&g_iters),
			       (unsigned long)atomic_load(&g_mismatches));
			fflush(stdout);
			next_status += 30000000000ull;
		}
	}
	atomic_store(&g_stop, 1);

	for (i = 0; i < ncpu; i++)
		if (ws[i].created)
			pthread_join(ws[i].th, NULL);

	if (!g_no_idle)
		pthread_barrier_destroy(&g_bar);
	for (i = 0; i < ncpu; i++)
		munmap(ws[i].base, g_bufbytes);
	if (g_pmsg >= 0)
		close(g_pmsg);
	if (g_rec)
		fclose(g_rec);

	printf("dczva-stress: done, %lu iterations, %lu mismatches in %llu s\n",
	       (unsigned long)atomic_load(&g_iters),
	       (unsigned long)atomic_load(&g_mismatches),
	       (unsigned long long)((now_ns() - t_start) / 1000000000ull));
	free(ws);
	return atomic_load(&g_mismatches) ? 2 : 0;
}

/*
 * ---- Self-review (done twice, per the task) -----------------------------
 *
 * UB / data races:
 *  - Each thread owns its own mmap'd buffer (ws[i].base); no two threads touch
 *    the same bytes, so the pattern/ZVA/compare traffic is race-free.
 *  - Shared state is atomic (g_iters, g_mismatches, g_stop, g_go) or guarded:
 *    the mismatch file and /dev/pmsg0 writes are under g_rec_lock; g_round_stop
 *    is written by exactly one thread (the barrier's serial thread) between two
 *    barriers and read by all after the second, so pthread_barrier_wait's
 *    happens-before makes it data-race-free without being atomic.
 *  - Target reads/writes use char-type (uint8_t) pointers, which may alias any
 *    object, so no strict-aliasing UB. The ref slot holds a uint8_t* and is
 *    pointer-aligned (base+GUARD, GUARD=4096). sizes/offsets are size_t.
 *  - DC ZVA zeroes the naturally-aligned block of size g_bs that contains the
 *    address; target = work + k*g_bs is g_bs-aligned (work is page-aligned and
 *    g_bs | page), and target+g_bs <= work+work_bytes, so no OOB. The compare
 *    reads exactly [target, target+g_bs).
 *  - Barrier deadlock: the barrier count equals the number of threads that
 *    actually started (g_nthreads); every thread executes the SAME number of
 *    barrier waits each iteration and only ever breaks right after a barrier at
 *    which the serial thread published g_round_stop, so all threads leave the
 *    loop together. A thread that fails to pin still runs (unpinned) and still
 *    participates in every barrier. Setup that could fail (mmap) is done in
 *    main before any barrier exists.
 *
 * Compiler NOT reordering the second compare before the idle:
 *  - compare_zero() loads through `const volatile uint8_t *`, so every byte is
 *    a real, ordered memory access the compiler may not elide, cache in a
 *    register, or reorder past another volatile access.
 *  - Between the first and second compare sit: an external, non-inlinable call
 *    (pthread_barrier_wait, twice), another external call (clock_nanosleep via
 *    sleep_until), and an explicit asm volatile("" ::: "memory") plus dsb ish.
 *    Each is a compiler barrier the volatile loads cannot move across, and the
 *    buffer pointer has escaped (mmap, passed to libc), so the compiler must
 *    assume those calls can read/write it. The second compare therefore happens
 *    strictly after the idle, in program order, at run time.
 *  - The dependent pointer itself is reloaded via `*ref` where ref is
 *    `uint8_t *const volatile *`, so the post-idle load re-reads the ref line
 *    rather than reusing a cached value - matching the x1e-crash dependency.
 */
