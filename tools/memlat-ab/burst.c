/* burst.c: the "light interactive" CPU pattern - short compute bursts that touch little memory (what
 * scrolling, UI and JIT code look like): BURST_MS of integer work every PERIOD_MS, for SECONDS. With the
 * RFC memlat ceilings (ipm_ceil 20000000) every burst also pulls DDR/LLCC up with cpufreq; with the
 * Android ceilings (patch 1042) it should not. Build: cc -O2 -o burst burst.c. Usage: burst [seconds] [burst_ms] [period_ms] */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }

int main(int argc, char **argv)
{
	double secs = argc > 1 ? atof(argv[1]) : 60, burst = (argc > 2 ? atof(argv[2]) : 30) / 1e3, period = (argc > 3 ? atof(argv[3]) : 100) / 1e3;
	uint64_t x = 88172645463325252ull, n = 0;
	double t0 = now(), busy = 0;
	while (now() - t0 < secs) {
		double b0 = now();
		while (now() - b0 < burst) {                 /* xorshift + multiply: ALU-bound, L1-resident */
			for (int i = 0; i < 20000; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; x *= 0x9E3779B97F4A7C15ull; }
			n += 20000;
		}
		busy += now() - b0;
		struct timespec ts = { 0, (long)((period - burst) * 1e9) };
		if (ts.tv_nsec > 0) nanosleep(&ts, 0);
	}
	printf("burst: %.0f s, duty %.0f %%, %.1f G iterations (x=%llu)\n", now() - t0, 100 * busy / (now() - t0), n / 1e9, (unsigned long long)x);
	return 0;
}
