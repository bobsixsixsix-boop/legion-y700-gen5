/* chase.c: dependent-load pointer chasing = memory latency per access (ns). A random cyclic permutation
 * over the working set defeats prefetchers; every load depends on the previous one. Used to see whether
 * the memlat firmware still raises DDR/LLCC for memory-bound code once the Android IPM ceilings (kernel
 * patch 1042) are in (2026-10-15). Build: cc -O2 -o chase chase.c. Usage: chase MiB [seconds] */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }

int main(int argc, char **argv)
{
	size_t mib = argc > 1 ? strtoul(argv[1], 0, 10) : 64;
	double secs = argc > 2 ? atof(argv[2]) : 3;
	size_t n = mib * 1024 * 1024 / 64;         /* one pointer per cache line */
	uint32_t *next = malloc(n * 64);
	if (!next) { perror("malloc"); return 1; }
	/* Sattolo's algorithm: a single cycle through all lines, in random order */
	for (size_t i = 0; i < n; i++) next[i * 16] = (uint32_t)i;
	srand(12345);
	for (size_t i = n - 1; i > 0; i--) {
		size_t j = ((size_t)rand() * 65536 + rand()) % i;
		uint32_t t = next[i * 16]; next[i * 16] = next[j * 16]; next[j * 16] = t;
	}
	volatile uint32_t sink = 0;
	uint32_t p = 0;
	size_t hops = 0;
	double t0 = now(), t1;
	do {
		for (int k = 0; k < 100000; k++) p = next[(size_t)p * 16];
		hops += 100000;
		t1 = now();
	} while (t1 - t0 < secs);
	sink = p;
	printf("%zu MiB: %.1f ns per dependent load (%.0f M loads in %.1f s)\n", mib, (t1 - t0) * 1e9 / hops, hops / 1e6, t1 - t0);
	return sink == 0xffffffff;
}
