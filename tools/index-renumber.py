#!/usr/bin/env python3
"""index-renumber.py --old REF|FILE [--readme PATH] [--apply] INDEX [INDEX ...]
Re-pin every `README.md:N` / `README.md:N-M` citation in an index file (runs/ab/INDEX.md and the like) after README.md
grew or shrank. Each cited line of the OLD README is found again by content in the current README; among identical
lines the one nearest to the old number plus the local shift wins (the shift is taken from the nearest line that is
unique in both versions). Win11 offline; read-only without --apply.

--old REF    the git revision whose README.md the citations were written against: `git show REF:README.md` in the repo
             (the parent of tools/). runs/ab/INDEX.md's header says which revision: the commit that last changed the
             INDEX itself (`git log -1 --format=%h -- runs/ab/INDEX.md`), since README and INDEX move in one commit.
--old FILE   a saved copy of that README instead of a revision.
--readme     the current README (default <repo>/README.md).
Dry run (default) prints every citation that changes, plus UNMAPPED for a cited line that no longer exists verbatim in
the current README (then fix that citation by hand). --apply rewrites each INDEX in place (UTF-8, LF) only when it has
no unmapped citation. Exit 0 when done or nothing to change, 1 when something is unmapped, 2 on a usage error.
Example (2026-10-19 P0 closing commit): README gained rows above the cited section; 48 citations moved by +9.
"""
import argparse
import bisect
import io
import os
import re
import subprocess
import sys

CIT = re.compile(r"README\.md:(\d+)(?:-(\d+))?")


def split_lines(text):
    lines = text.split("\n")
    if lines and lines[-1] == "":          # a trailing newline is not a line
        lines.pop()
    return lines


def read_old(spec, repo):
    if os.path.isfile(spec):
        return split_lines(io.open(spec, encoding="utf-8-sig").read())
    p = subprocess.run(["git", "-C", repo, "show", "%s:README.md" % spec], capture_output=True)
    if p.returncode != 0:
        sys.exit("index-renumber: --old %r is neither a file nor a revision with README.md (%s)"
                 % (spec, p.stderr.decode("utf-8", "replace").strip()))
    return split_lines(p.stdout.decode("utf-8-sig").replace("\r\n", "\n"))


class Mapper:
    def __init__(self, old, new):
        self.old = old
        self.pos = {}
        for i, l in enumerate(new, 1):
            self.pos.setdefault(l, []).append(i)
        old_count = {}
        for l in old:
            old_count[l] = old_count.get(l, 0) + 1
        # anchors: lines that occur exactly once in both versions -> exact local shift
        self.anchors = [(i, self.pos[l][0]) for i, l in enumerate(old, 1)
                        if l.strip() and old_count[l] == 1 and len(self.pos.get(l, ())) == 1]
        self.anchor_old = [a[0] for a in self.anchors]

    def shift_at(self, n):
        if not self.anchors:
            return 0
        k = bisect.bisect_right(self.anchor_old, n) - 1
        if k < 0:
            k = 0
        return self.anchors[k][1] - self.anchors[k][0]

    def map_line(self, n):
        if n < 1 or n > len(self.old):
            return None
        cands = self.pos.get(self.old[n - 1])
        if not cands:
            return None
        hint = n + self.shift_at(n)
        return min(cands, key=lambda c: abs(c - hint))


def renumber(text, mapper):
    changes, unmapped = [], []

    def repl(m):
        a = int(m.group(1))
        b = int(m.group(2)) if m.group(2) else None
        na = mapper.map_line(a)
        nb = mapper.map_line(b) if b else None
        if na is None or (b and nb is None):
            unmapped.append(m.group(0))
            return m.group(0)
        s = "README.md:%d" % na + ("-%d" % nb if b else "")
        if s != m.group(0):
            changes.append((m.group(0), s))
        return s

    return CIT.sub(repl, text), changes, unmapped


def main(argv=None):
    ap = argparse.ArgumentParser(description="re-pin README.md:N citations in an index after README.md changed")
    ap.add_argument("--old", required=True, metavar="REF|FILE", help="git revision or saved copy of the README the citations match")
    ap.add_argument("--readme", help="current README (default: <repo>/README.md)")
    ap.add_argument("--repo", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))), help="repo root (default: parent of tools/)")
    ap.add_argument("--apply", action="store_true", help="rewrite the index files in place")
    ap.add_argument("index", nargs="+", help="index file(s) holding README.md:N citations")
    args = ap.parse_args(argv)
    readme = args.readme or os.path.join(args.repo, "README.md")
    if not os.path.isfile(readme):
        ap.error("README not found: %s" % readme)
    old = read_old(args.old, args.repo)
    new = split_lines(io.open(readme, encoding="utf-8-sig").read())
    mapper = Mapper(old, new)
    bad = 0
    for idx in args.index:
        if not os.path.isfile(idx):
            ap.error("index not found: %s" % idx)
        text = io.open(idx, encoding="utf-8-sig").read()
        out, changes, unmapped = renumber(text, mapper)
        print("%s: old README %d lines, current %d lines, %d anchors; %d citation%s changed, %d unmapped" % (
            idx, len(old), len(new), len(mapper.anchors), len(changes), "" if len(changes) == 1 else "s", len(unmapped)))
        for o, n in changes:
            print("  %s -> %s" % (o, n))
        for u in unmapped:
            print("  UNMAPPED %s" % u)
        if unmapped:
            bad += 1
        elif args.apply and changes:
            io.open(idx, "w", encoding="utf-8", newline="\n").write(out)
            print("  written")
    return 1 if bad else 0


if __name__ == "__main__":
    if (sys.stdout.encoding or "").lower().replace("-", "") != "utf8":
        sys.stdout.reconfigure(errors="replace")
    sys.exit(main())
