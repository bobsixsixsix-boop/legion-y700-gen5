#!/usr/bin/env python3
"""test-ab-index-check.py [SCRIPT]: offline test of ab-index-check.py on a temp tree (the repo's own runs/ are not read).

Every case writes <tmp>/runs/ab/INDEX.md and artifacts under <tmp>/runs and <tmp>/cx, then runs the script as a
subprocess (python -X utf8 -I ... --repo <tmp> --root <tmp>/runs --root <tmp>/cx) and checks the exit code and the paths
it lists:
  problems  a run dir covered by a directory link, an unindexed summary.txt, an unindexed slices file, a dangling link,
            four malformed entries (no " — ", two parts, empty part, one real part plus "；" only inside parentheses):
            exit 1; (a) names exactly the two unindexed files, (b) only the dangling target (the link-shaped format
            example inside backticks is not a link), (c) the four line numbers; cx-exp-*.txt, cx-audit-*.txt,
            slices.sh, *.md and INDEX.md itself are never listed as artifacts; overlapping roots (runs + runs/ab) do
            not list an artifact twice
  clean     every artifact covered (directory link, repo-relative file link, bare fr-slice name, backslashes and, on
            Windows, wrong case, a <...> target with a space); one line judged "无裁决，待 6 窗" and one whose
            citation parentheses hold "；" are well-formed: exit 0, --quiet prints nothing
  since     an unindexed artifact 30 days old is listed with its date; --since 7 hides it (exit 0)
  nocover   a link to a scanned root, to the repo root, to the INDEX's own directory ".", and a prose (non-entry) link
            to a run dir cover nothing: exit 1
  config    missing INDEX or missing root: exit 2; --since 0: exit 2; an INDEX that is not UTF-8: exit 2; a BOM
            does not hide an entry on line 1
Prints ALL PASS.
"""
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SCRIPT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "ab-index-check.py")
FAILS = []


def check(cond, what):
    if not cond:
        FAILS.append(what)
        print("FAIL:", what)


def run(repo, *extra, roots=("runs", "cx")):
    cmd = [sys.executable, "-X", "utf8", "-I", SCRIPT, "--repo", str(repo)]
    for r in roots:
        cmd += ["--root", str(repo / r)]
    p = subprocess.run(cmd + list(extra), capture_output=True, text=True, encoding="utf-8")
    return p.returncode, p.stdout, p.stderr


def mk(repo, relpath, text="x\n"):
    p = repo / relpath
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding="utf-8", newline="\n")
    return p


def section(out, tag):
    """The indented lines that follow the '(a)' / '(b)' / '(c)' header line."""
    lines, on = [], False
    for line in out.splitlines():
        if line.startswith("("):
            on = line.startswith(tag)
        elif on and line.startswith("  "):
            lines.append(line.strip())
    return lines


def tree(repo):
    mk(repo, "README.md", "# stub\n")
    mk(repo, "runs/ab/20261020-noop.txt", "noop:15 x12 windows\n")
    mk(repo, "runs/status-20261020.md", "# report, not an artifact\n")
    mk(repo, "cx/E3a-20261020-0100/summary.txt", "bat mean 300 mW over 900 rows\n")
    mk(repo, "cx/E3a-20261020-0100/cx-exp-E3a.txt")
    mk(repo, "cx/E3b-20261020-0200/summary.txt", "bat mean 290 mW over 900 rows\n")
    mk(repo, "cx/day-20261020/slices-0900.txt", "off 07:00:00-07:10:00 rows 60 bat 330 mW\n")
    mk(repo, "cx/day-20261020/slices.sh", "#!/bin/bash\n")
    mk(repo, "cx/cx-audit-0100.txt", "snapshot, not an artifact\n")


OK_TAIL = " — 一句话结论；每臂 1 窗，无双侧 p；无\n"   # a well-formed tail: em dash, three fullwidth-semicolon parts
HEADER = ("# A/B 裁决\n\n格式见 [README](../../README.md)："
          "`- [<日期> <主题>](<切片文件>) — 结论；口径；未决`。\n\n"
          "- [ ] 不是条目的复选框\n\n")       # prose link, a link-shaped code span (not a link), a checkbox line
L_E3A_DIR = "- [2026-10-20 E3a](../../cx/E3a-20261020-0100/)" + OK_TAIL
L_E3B_FILE = "- [2026-10-20 E3b](cx/E3b-20261020-0200/summary.txt)" + OK_TAIL                                  # repo-relative target
L_NOOP = "- [2026-10-20 noop](20261020-noop.txt) — 12 窗空 A/B；无裁决，待 6 窗；fr-slice 周报\n"
if os.name == "nt":
    L_SLICES = "- [2026-10-20 slices](..\\..\\CX\\Day-20261020\\SLICES-0900.txt)" + OK_TAIL                    # backslashes + wrong case
else:
    L_SLICES = "- [2026-10-20 slices](..\\..\\cx\\day-20261020\\slices-0900.txt)" + OK_TAIL                    # backslashes only
L_DANGLING = "- [2026-10-20 gone](../../cx/E9-20261020-0300/summary.txt)" + OK_TAIL
L_PAREN_OK = "- [2026-10-20 noop](20261020-noop.txt) — 12 窗（a:1；b:2）；无裁决，待 6 窗（c:3；d:4）；周报\n"   # "；" in （…） is text
L_SPACE = "- [2026-10-20 space](<../../cx/E9 x/summary.txt>)" + OK_TAIL                                      # <...> target with a space
L_BAD_NODASH = "- [2026-10-20 noop](20261020-noop.txt) ran fine\n"
L_BAD_2PARTS = "- [2026-10-20 noop](20261020-noop.txt) — ran fine；无裁决\n"
L_BAD_EMPTY = "- [2026-10-20 noop](20261020-noop.txt) — ran fine；；无\n"
L_BAD_PARENSEMI = "- [2026-10-20 noop](20261020-noop.txt) — 结论（a:1；b:2；c:3）\n"                          # one real part


def case_problems(repo):
    tree(repo)
    index = HEADER + L_E3A_DIR + L_DANGLING + L_BAD_NODASH + L_BAD_2PARTS + L_BAD_EMPTY + L_BAD_PARENSEMI
    mk(repo, "runs/ab/INDEX.md", index)
    rc, out, err = run(repo)
    check(rc == 1, "problems: exit 1, got %d\n%s%s" % (rc, out, err))
    a = section(out, "(a)")
    paths = [l.split("  ", 1)[1] for l in a]
    check(paths == ["cx/E3b-20261020-0200/summary.txt", "cx/day-20261020/slices-0900.txt"], "problems: (a) paths %r" % paths)
    check(all(l[:10].count("-") == 2 and l[:4].isdigit() for l in a), "problems: (a) lines carry a date: %r" % a)
    b = section(out, "(b)")
    check(b == ["INDEX.md:8  ../../cx/E9-20261020-0300/summary.txt"], "problems: (b) %r" % b)
    c = section(out, "(c)")
    check([l.split("  ")[0] for l in c] == ["INDEX.md:9", "INDEX.md:10", "INDEX.md:11", "INDEX.md:12"], "problems: (c) lines %r" % c)
    check(len(c) == 4 and "conclusion" in c[0] and "2 parts" in c[1] and "empty" in c[2] and "1 part found" in c[3],
          "problems: (c) reasons %r" % c)
    for never in ("cx-exp-E3a.txt", "cx-audit", "slices.sh", "status-20261020.md", "ab/INDEX.md", "README.md"):
        check(never not in "\n".join(a), "problems: %s listed as an artifact" % never)
    check("artifacts: 4, indexed: 2" in out, "problems: summary line\n%s" % out)
    rc2, out2, err2 = run(repo, roots=("runs", "runs/ab", "cx"))                 # overlapping roots: same answer, no duplicates
    check(rc2 == 1 and "artifacts: 4, indexed: 2" in out2 and section(out2, "(a)") == a,
          "problems: overlapping roots rc=%d\n%s%s" % (rc2, out2, err2))


def case_clean(repo):
    tree(repo)
    mk(repo, "cx/E9 x/summary.txt", "bat mean 280 mW over 900 rows\n")
    mk(repo, "runs/ab/INDEX.md", HEADER + L_E3A_DIR + L_E3B_FILE + L_NOOP + L_PAREN_OK + L_SLICES + L_SPACE)
    rc, out, err = run(repo)
    check(rc == 0, "clean: exit 0, got %d\n%s%s" % (rc, out, err))
    check("6 entries, 7 links" in out and "artifacts: 5, indexed: 5" in out, "clean: summary line\n%s" % out)
    check(section(out, "(a)") == [] and section(out, "(b)") == [] and section(out, "(c)") == [], "clean: output\n%s" % out)
    rc, out, err = run(repo, "--quiet")
    check(rc == 0 and out == "" and err == "", "clean --quiet: expected silence, got rc=%d\n%s%s" % (rc, out, err))


def case_since(repo):
    tree(repo)
    mk(repo, "runs/ab/INDEX.md", HEADER + L_E3A_DIR + L_NOOP + L_SLICES)
    old = time.time() - 30 * 86400
    os.utime(repo / "cx/E3b-20261020-0200/summary.txt", (old, old))
    rc, out, err = run(repo)
    a = section(out, "(a)")
    check(rc == 1 and a == ["%s  cx/E3b-20261020-0200/summary.txt" % time.strftime("%Y-%m-%d", time.localtime(old))],
          "since: without --since, rc=%d (a)=%r" % (rc, a))
    rc, out, err = run(repo, "--since", "7")
    check(rc == 0 and section(out, "(a)") == [] and "1 older one hidden" in out, "since: --since 7 rc=%d\n%s%s" % (rc, out, err))
    rc, out, err = run(repo, "--since", "7", "--quiet")
    check(rc == 0 and out == "", "since: --since 7 --quiet rc=%d\n%s" % (rc, out))


def case_nocover(repo):
    tree(repo)
    index = (HEADER + "- [2026-10-20 root](../../cx/)" + OK_TAIL + "- [2026-10-20 repo](../../)" + OK_TAIL
             + "- [2026-10-20 all](.)" + OK_TAIL                                  # the INDEX's own directory (runs/ab)
             + "看 [E3a](../../cx/E3a-20261020-0100/) 的目录。\n" + L_SLICES)
    mk(repo, "runs/ab/INDEX.md", index)
    rc, out, err = run(repo)
    paths = [l.split("  ", 1)[1] for l in section(out, "(a)")]
    check(rc == 1 and paths == ["cx/E3a-20261020-0100/summary.txt", "cx/E3b-20261020-0200/summary.txt", "runs/ab/20261020-noop.txt"],
          "nocover: rc=%d (a)=%r\n%s" % (rc, paths, err))
    check(section(out, "(b)") == [] and section(out, "(c)") == [], "nocover: (b)/(c) must be empty\n%s" % out)


L_EXCL_DIR = "- 排除 [串流](../streaming/) — 另一组串流基准，不是切片\n"                                   # directory exclusion
L_EXCL_FILE = "- 排除 [E8](../../cx/E8-20261020-0400/summary.txt) — 坏文件\n"                           # file exclusion
L_EXCL_ROOT = "- 排除 [全部](../../cx/) — 扫描根不能排除\n"
L_EXCL_GONE = "- 排除 [gone](../gone/) — 还没提交的目录，不算失效\n"


def case_exclude(repo):
    tree(repo)
    mk(repo, "runs/streaming/wpr-1/summary.txt", "a streaming benchmark\n")
    mk(repo, "runs/streaming/notes.md", "# not an artifact anyway\n")
    mk(repo, "cx/E8-20261020-0400/summary.txt", "bat mean 0 mW (broken run)\n")
    mk(repo, "runs/ab/INDEX.md", HEADER + L_E3A_DIR + L_E3B_FILE + L_NOOP + L_SLICES + L_EXCL_DIR + L_EXCL_FILE + L_EXCL_GONE)
    rc, out, err = run(repo)
    check(rc == 0, "exclude: exit 0, got %d\n%s%s" % (rc, out, err))
    check("4 entries, 8 links, 3 exclusions" in out and "artifacts: 6, indexed: 6" in out, "exclude: summary line\n%s" % out)
    check(section(out, "(a)") == [] and section(out, "(b)") == [] and section(out, "(c)") == [], "exclude: output\n%s" % out)
    # a root cannot be excluded: a new run under it is still listed; a dangling link elsewhere on the line is still (b)
    mk(repo, "cx/E7-20261020-0500/summary.txt", "bat mean 1 mW\n")
    mk(repo, "runs/ab/INDEX.md", HEADER + L_E3A_DIR + L_E3B_FILE + L_NOOP + L_SLICES + L_EXCL_DIR + L_EXCL_FILE + L_EXCL_ROOT
       + "- 排除 [E8](../../cx/E8-20261020-0400/summary.txt) — 见 [报告](../../cx/missing.md)\n")
    rc, out, err = run(repo)
    paths = [l.split("  ")[1] for l in section(out, "(a)")]
    check(rc == 1 and paths == ["cx/E7-20261020-0500/summary.txt"], "exclude: root exclusion must not cover; got rc=%d %r\n%s" % (rc, paths, out))
    check(section(out, "(b)") == ["INDEX.md:14  ../../cx/missing.md"], "exclude: (b) %r" % section(out, "(b)"))
    check("4 exclusions" in out, "exclude: count\n%s" % out)


def case_config(repo):
    tree(repo)
    rc, out, err = run(repo)
    check(rc == 2 and "INDEX not found" in err, "config: missing INDEX rc=%d err=%r" % (rc, err))
    mk(repo, "runs/ab/INDEX.md", HEADER)
    rc, out, err = run(repo, roots=("runs", "nowhere"))
    check(rc == 2 and "root not found" in err, "config: missing root rc=%d err=%r" % (rc, err))
    for bad in ("0", "-1"):
        rc, out, err = run(repo, "--since", bad)
        check(rc == 2 and "--since DAYS must be > 0" in err, "config: --since %s rc=%d err=%r" % (bad, rc, err))
    (repo / "runs/ab/INDEX.md").write_bytes(b"\xef\xbb\xbf" + L_E3A_DIR.encode("utf-8"))        # BOM, entry on line 1
    rc, out, err = run(repo)
    check(rc == 1 and "1 entry, 1 link" in out and "artifacts: 4, indexed: 1" in out,
          "config: BOM INDEX rc=%d\n%s%s" % (rc, out, err))
    (repo / "runs/ab/INDEX.md").write_bytes(b"- [2026-10-20 gbk](20261020-noop.txt) \xa1\xaa \xbd\xe1\xc2\xdb\n")   # not UTF-8
    rc, out, err = run(repo)
    check(rc == 2 and "INDEX is not UTF-8" in err, "config: non-UTF-8 INDEX rc=%d err=%r" % (rc, err))


for case in (case_problems, case_clean, case_since, case_nocover, case_exclude, case_config):
    with tempfile.TemporaryDirectory(prefix="abidx-") as tmp:
        case(Path(tmp))
    print("%-14s %s" % (case.__name__[5:], "FAIL" if FAILS else "ok"))

if FAILS:
    print("%d FAILED" % len(FAILS))
    sys.exit(1)
print("ALL PASS")
