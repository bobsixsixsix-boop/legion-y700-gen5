#!/bin/bash
# test-yuv709-loader-lock.sh SHIM.so [RUNS]: the loader deadlock of 2026-11-09 (linux/stage/README 踩坑 17) as a quick,
# repeatable test for yuv709-shim.c. On the tablet, any user, needs gcc; no GPU, no Mesa, nothing installed or changed.
# install-yuv709-shim.sh runs it as one of its shim tests (20 runs). Each run is a fresh process, because the shim looks
# up the real dri2_from_dma_bufs once per process, at its first call:
#   - a fake libgallium-0.0.0-locktest.so (defines dri2_from_dma_bufs, returns a marker) is dlopened RTLD_LOCAL, the way
#     libglvnd brings in libEGL_mesa and libgallium, so only the shim's own lookup can find it
#   - a second thread dlopens and dlcloses a small library in a loop: it holds the loader's dl_load_lock most of the
#     time, like the QQmlThread loading QML plugins in the test KWin that hung
#   - the main thread calls the shim's dri2_from_dma_bufs (the one LD_PRELOAD puts first in the global scope; dladdr
#     checks that it is SHIM's): its first call runs dl_iterate_phdr. The 10-23 shim called dlopen / dlsym from inside
#     the callback, under dl_load_write_lock: ABBA with the other thread, and the process hangs.
# A run that has not finished after 5 s counts as hung (killed). Prints "RUNS n ok a hung b other c", then LOCKTEST_OK
# only when every run came back with the fake's marker. Negative control, the 10-23 shim:
#   git show 02d4909:linux/video/yuv709-shim.c > old.c && gcc -O2 -shared -fPIC -o old.so old.c -ldl  -> must hang
#   (11-09 on the tablet, glibc 2.43: the 10-23 shim hung 30 of 30 runs, the fixed one passed 200 of 200 in 5.5 s)
set -u
SHIM=$(readlink -f "${1:-}"); RUNS=${2:-200}
[ -f "$SHIM" ] || { echo "LOCKTEST_FAIL: shim '${1:-}' not found"; exit 2; }
W=$(mktemp -d /tmp/yuv709-locktest.XXXX); trap 'rm -rf $W' EXIT
echo 'void *dri2_from_dma_bufs(void) { return (void *)0x7007; }' > $W/fake.c
echo 'int locktest_other = 1;' > $W/other.c
cat > $W/race.c <<'EOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
typedef void *(*fn)(void *, int, int, int, unsigned long, int *, int, int *, int *, int, int, int, int, unsigned,
                    unsigned *, void *);
static const char *other;
static volatile int stop, spun;
static void *spin(void *a) {
	(void)a;
	while (!stop) {
		void *h = dlopen(other, RTLD_NOW | RTLD_LOCAL);
		if (h) dlclose(h);
		spun = 1;
	}
	return NULL;
}
int main(int argc, char **argv) { // SHIM FAKE OTHER
	if (argc < 4) return 2;
	other = argv[3];
	if (!dlopen(argv[2], RTLD_NOW | RTLD_LOCAL)) { printf("fake libgallium: %s\n", dlerror()); return 2; }
	fn f = (fn)dlsym(RTLD_DEFAULT, "dri2_from_dma_bufs");
	Dl_info di;
	if (!f || !dladdr((void *)f, &di) || strcmp(di.dli_fname, argv[1])) {
		printf("dri2_from_dma_bufs is not the shim's: %s\n", f && dladdr((void *)f, &di) ? di.dli_fname : "none");
		return 2;
	}
	pthread_t t;
	pthread_create(&t, NULL, spin, NULL);
	while (!spun) ;
	unsigned e = 0;
	void *r = f(NULL, 1920, 1080, 0x3231564e, 0, NULL, 2, NULL, NULL, 0x327f, 0x3283, 0, 0, 0, &e, NULL);
	stop = 1;
	pthread_join(t, NULL);
	puts(r == (void *)0x7007 ? "real" : "not the fake's marker");
	return r != (void *)0x7007;
}
EOF
gcc -shared -fPIC -o $W/libgallium-0.0.0-locktest.so $W/fake.c && gcc -shared -fPIC -o $W/liblocktest-other.so $W/other.c &&
	gcc -O1 -Wall -o $W/race $W/race.c -ldl -lpthread || { echo "LOCKTEST_FAIL: could not build the test"; exit 2; }
ok=0 hung=0 other=0
for i in $(seq "$RUNS"); do
	out=$(LD_PRELOAD=$SHIM timeout -s KILL 5 $W/race "$SHIM" $W/libgallium-0.0.0-locktest.so $W/liblocktest-other.so 2>&1)
	rc=$?
	if [ $rc = 0 ] && [ "$out" = real ]; then ok=$((ok + 1))
	elif [ $rc = 124 ] || [ $rc = 137 ]; then hung=$((hung + 1))   # timed out (coreutils exits 124 even for -s KILL)
	else other=$((other + 1)); [ $other -le 3 ] && echo "run $i: exit $rc: $out"; fi
done
echo "RUNS $RUNS ok $ok hung $hung other $other"
[ $ok = "$RUNS" ] && echo LOCKTEST_OK || { echo LOCKTEST_FAIL; exit 1; }
