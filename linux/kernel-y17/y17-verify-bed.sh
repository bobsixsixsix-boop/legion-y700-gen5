# y17-verify.sh's boot-log part against made-up y17 boots (on the tablet, as root; 11-01). A journalctl stub serves the
# real -o short --no-hostname kernel log of this (y16) boot edited into a y17 one (python below); tune2fs is stubbed to
# "clean". Cases: ok -> the 7 root lines PASS; each mutant -> the named line FAILs.
#   scp linux/kernel-y17/y17-verify.sh to /root/y17-verify.sh and this file anywhere; bash y17-verify-bed.sh (about 1 min;
#   the rest of y17-verify.sh runs for real each time, only these lines are printed). 11-01 on y16: ok 0 FAIL, every
#   mutant exactly its line (j4 f4 f32: exits; nojournal: 3; fullafter journalafter: order; remount noe2fsck: trouble;
#   errafter: after the full check; witherrors: tune2fs).
set -u
B=/tmp/y17v-bed; rm -rf $B; mkdir -p $B/bin
REALJ=$(command -v journalctl)
journalctl -k -b --no-pager -o short --no-hostname > $B/real.txt
cat > $B/bin/journalctl <<EOF
#!/bin/bash
case " \$* " in *" --no-hostname "*) cat $B/cur.txt ;; *) exec $REALJ "\$@" ;; esac
EOF
cat > $B/bin/tune2fs <<EOF
#!/bin/bash
cat $B/tune2fs.txt
EOF
chmod +x $B/bin/*
mk() {   # mk CASE: write cur.txt and tune2fs.txt for CASE
python3 - $B/real.txt $B/cur.txt $1 <<'PY'
import re, sys
src, dst, case = sys.argv[1:]
L = open(src).read().splitlines()
ts = L[0][:15]
def b(msg): return ts + " baldur:  " + msg
bad = re.compile(r"Couldn't remount RDWR|clearing orphan list|start not counted|error count since|initial error at|last error at|mounting fs with errors")
L = [l for l in L if not bad.search(l)]
first = next(i for i, l in enumerate(L) if "kernel: EXT4-fs (sda15): " in l)
jex = {"j4": 4}.get(case, 0)
J = [b("fsck baldur-root (/dev/sda15): e2fsck -p -E journal_only, usually seconds; do not power off"),
     b("  baldur-root: recovering journal"),
     b("fsck baldur-root (/dev/sda15): exit %d (%s), 0 s" % (jex, "clean" if jex == 0 else "ERRORS LEFT, needs e2fsck -f by hand"))]
if case == "nojournal":
    J = []
fex = {"f4": 4, "f32": 32}.get(case, 1)
F = [b("fsck baldur-root (/dev/sda15): e2fsck -p, usually seconds; do not power off"),
     b("  baldur-root: 300000/6000000 files (0.5% non-contiguous), 26000000/24000000 blocks"),
     b("fsck baldur-root (/dev/sda15): exit %d (%s), 2 s" % (fex, {1: "errors fixed", 4: "ERRORS LEFT, needs e2fsck -f by hand", 32: "stopped"}[fex]))]
T = [b("kernel 7.3.0-tb323fu-t52-y17 on trial: start 1 of 2 (kept when you press Keep)")]
W = [ts + " kernel: EXT4-fs (sda15): warning: mounting fs with errors, running e2fsck is recommended"]
sw = next(i for i, l in enumerate(L) if " baldur:  switching to root " in l)
um = next(i for i, l in enumerate(L) if "kernel: EXT4-fs (sda15): unmounting" in l)
if case == "fullafter":   # the full check after the switch
    out = L[:first] + J + L[first:um] + T + W + L[um:sw + 1] + F + L[sw + 1:]
elif case == "journalafter":   # the journal-only check after the first mount
    out = L[:first + 4] + J + L[first + 4:um] + T + W + L[um:sw] + F + L[sw:]
else:
    out = L[:first] + J + L[first:um] + T + W + L[um:sw] + F + L[sw:]
if case == "remount":
    out.insert(first + 4, ts + " kernel: EXT4-fs (sda15): Couldn't remount RDWR because of unprocessed orphan inode list.  Please umount/remount instead")
if case == "errafter":
    out.append(ts + " kernel: EXT4-fs error (device sda15): ext4_lookup:1820: inode #2: comm ls: deleted inode referenced: 12")
if case == "noe2fsck":
    out.insert(first, b("fsck baldur-root (/dev/sda15): no e2fsck in this image, not checked"))
open(dst, "w").write("\n".join(out) + "\n")
PY
if [ "$1" = witherrors ]; then printf 'Filesystem state:         clean with errors\nFS Error count:           1\n' > $B/tune2fs.txt
else printf 'Filesystem state:         clean\n' > $B/tune2fs.txt; fi
}
for c in ok j4 f4 f32 nojournal fullafter journalafter remount errafter noe2fsck witherrors; do
    mk $c
    out=$(PATH=$B/bin:$PATH bash /root/y17-verify.sh 2>&1 | grep -E "init switched|e2fsck runs|both exited|^(PASS|FAIL)  order|10-31/11-01|after the full check|tune2fs|before the full check")
    nf=$(grep -c "^FAIL" <<<"$out")
    echo "== $c: $nf FAIL"
    grep -E "^FAIL|^INFO" <<<"$out" | cut -c1-150
done
rm -rf $B
