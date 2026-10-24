#!/usr/bin/env python3
"""ab-index-check.py [--root DIR ...] [--index FILE] [--repo DIR] [--since DAYS] [--quiet]: list the A/B slice
artifacts that have no verdict line in runs/ab/INDEX.md. Win11 offline tool, read-only, never touches the tablet
(plan linux/power/PLAN-deep-powersave.md: M-1 last bullet, section 3.5 row "裁决完整性", appendix C; 2026-10-19).

Slice artifact = a file that holds measured windows. Found by walking the roots (default: runs/ and
linux/power/cx-collapse/runs/ under the repo; --root DIR, repeatable, replaces the default list):
  summary.txt                     exp-collect.sh output inside a run directory (E3b-20261018-0758/summary.txt)
  slices*.txt                     hand-cut windows (day-20261018/slices-0840.txt)
  <YYYYMMDD>-<label>.txt | .json  fr-slice.py output (convention: runs/ab/20261020-n1.txt)
Not artifacts (nothing to judge, or raw material of a run that summary.txt already represents): cx-exp-*.txt,
flightrec-*.log.gz, cx-audit-*.txt and the diag snapshots (apps-pc-stuck-*, postboot-*), *.md reports, scripts.

INDEX entry = a list line that starts with a markdown link, appendix C shape:
  - [<日期> <主题>](<切片文件>) — <一句话结论>；<裁决口径（双侧 p / 代理）>；<未决>
A link target is resolved relative to the INDEX's own directory first, then relative to the repo root; "\\" is read
as "/"; on Windows paths compare case-insensitively; a target with spaces must use the markdown <...> form. Only the
FIRST link of an entry line names the artifact the line judges; a link to a run DIRECTORY covers every artifact inside
it, a link to a scanned root (or above) or to the INDEX's own directory covers nothing. A "；" inside parentheses
（…）/(...) is part of a citation, not a separator. A malformed entry still counts as indexed (the artifact has a
line); (c) reports the shape problem. The INDEX is read as UTF-8 (a BOM is tolerated).

Exclusion line = a list line `- 排除 [<名>](<文件或目录>) — <原因>`: that file, or every artifact under that directory, is
left out of (a) (a scanned root or anything above it still cannot be excluded); its target may be absent (a directory
not committed yet) without counting as dangling in (b). Exclusions are not entries: no shape check.

Reports:
  (a) artifacts without an entry, with their mtime date (--since DAYS: only artifacts modified in the last DAYS days)
  (b) links whose target does not exist (every link in the file, on entry lines or not)
  (c) entry lines not in the appendix C shape: no " — " after the link, or fewer than three non-empty "；"-separated parts
Exit 1 when (a) or (b) is non-empty, else 0 ((c) alone keeps exit 0); 2 for a missing INDEX or root, an INDEX that is
not UTF-8, or --since <= 0. --quiet prints only the problems (nothing at all when there are none).
"""
import argparse
import os
import re
import sys
import time
from pathlib import Path

DEFAULT_ROOTS = ("runs", os.path.join("linux", "power", "cx-collapse", "runs"))
DEFAULT_INDEX = os.path.join("runs", "ab", "INDEX.md")
SKIP_DIRS = {".git", "__pycache__"}
DASH = "—"        # EM DASH, the " — " before the conclusion
SEMI = "；"        # FULLWIDTH SEMICOLON, separates 结论 / 裁决口径 / 未决
LINK_RE = re.compile(r"!?\[([^\]]*)\]\((<[^>]*>|[^)\s]+)(?:\s+\"[^\"]*\")?\)")   # target: <may have spaces> or bare
ENTRY_RE = re.compile(r"^\s*-\s+!?\[[^\]]*\]\(")          # list item whose first thing is a link ("- [ ]" boxes do not match)
EXCL_RE = re.compile(r"^\s*-\s+排除\s+!?\[[^\]]*\]\(")    # "- 排除 [name](target) — reason": target left out of (a)
CODE_RE = re.compile(r"`[^`]*`")                          # inline code spans hold no links (the format example in the header)
PAREN_RE = re.compile(r"（[^（）]*）|\([^()]*\)")            # a citation such as （summary.txt:53，README.md:1561）
FRSLICE_RE = re.compile(r"^\d{8}-[^/\\]+\.(txt|json)$", re.I)
SCHEME_RE = re.compile(r"^[a-z][a-z0-9+.-]*:", re.I)


def norm(p):
    """Comparable key: absolute, normalised separators, case-folded on Windows."""
    return os.path.normcase(os.path.normpath(os.path.abspath(str(p))))


def is_artifact(name):
    low = name.lower()
    return low == "summary.txt" or (low.startswith("slices") and low.endswith(".txt")) or bool(FRSLICE_RE.match(name))


def find_artifacts(roots):
    found, seen = [], set()
    for root in roots:
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
            for fn in sorted(filenames):
                p = Path(dirpath) / fn
                if is_artifact(fn) and norm(p) not in seen:      # overlapping roots (--root runs --root runs/ab) list once
                    seen.add(norm(p))
                    found.append(p)
    return found


def resolve_link(raw, index_dir, repo):
    """Return (cleaned target, resolved Path or None). None for URLs and pure anchors."""
    if SCHEME_RE.match(raw) or raw.startswith("#"):
        return None, None
    target = raw.strip("<>").split("#", 1)[0].replace("\\", "/")
    if not target:
        return None, None
    for base in (index_dir, repo):
        cand = base / target
        if cand.exists():
            return target, cand
    return target, None


def shape_problem(rest):
    """rest = the entry line after its first link. Returns a reason string, or None when the line is well-formed."""
    m = re.match(r"\s*" + DASH + r"+\s*", rest)
    if not m:
        return 'no " %s " conclusion after the link' % DASH
    body = PAREN_RE.sub(lambda c: c.group().replace(SEMI, "，"), rest[m.end():])   # "；" inside （…） is not a separator
    parts = [p.strip() for p in body.split(SEMI)]
    if len(parts) < 3:
        return "needs 结论%s裁决口径%s未决 (%d part%s found)" % (SEMI, SEMI, len(parts), "" if len(parts) == 1 else "s")
    if any(not p for p in parts[:3]):
        return "empty part in 结论%s裁决口径%s未决" % (SEMI, SEMI)
    return None


def parse_index(index_path, repo):
    """Returns (entry_targets, excluded, dangling, malformed, n_entries, n_links, n_excl).
    entry_targets: resolved Paths named by the first link of well-formed or malformed entry lines.
    excluded: resolved Paths (file or directory) named by the first link of exclusion lines.
    dangling: (lineno, target) for every link in the file whose target is missing.
    malformed: (lineno, reason) for entry lines off the appendix C shape."""
    entry_targets, excluded, dangling, malformed = [], [], [], []
    n_entries = n_links = n_excl = 0
    text = index_path.read_text(encoding="utf-8-sig")       # "-sig": a BOM (Notepad default) must not hide line 1
    for lineno, raw_line in enumerate(text.splitlines(), 1):
        line = CODE_RE.sub(lambda m: " " * len(m.group()), raw_line)      # same length: offsets stay valid
        is_entry = bool(ENTRY_RE.match(line))
        is_excl = bool(EXCL_RE.match(line))
        first = None
        for m in LINK_RE.finditer(line):
            target, resolved = resolve_link(m.group(2), index_path.parent, repo)
            if target is None:
                continue
            n_links += 1
            if resolved is None and not (is_excl and first is None):      # an exclusion's own target may not exist yet
                dangling.append((lineno, target))
            if first is None:
                first = (m, resolved)
        if is_excl:
            n_excl += 1
            if first is not None and first[1] is not None:
                excluded.append(first[1])
            continue
        if not is_entry:
            continue
        n_entries += 1
        if first is None:          # cannot happen with ENTRY_RE, kept for safety
            malformed.append((lineno, "entry without a path link"))
            continue
        m, resolved = first
        if resolved is not None:
            entry_targets.append(resolved)
        reason = shape_problem(line[m.end():])
        if reason:
            malformed.append((lineno, reason))
    return entry_targets, excluded, dangling, malformed, n_entries, n_links, n_excl


def covered(artifact, linked_files, linked_dirs, root_keys):
    if norm(artifact) in linked_files:
        return True
    p = artifact.parent
    while True:
        key = norm(p)
        if key in root_keys:           # the scanned root itself (or above) never covers
            return False
        if key in linked_dirs:
            return True
        if p.parent == p:
            return False
        p = p.parent


def rel(p, repo):
    try:
        return os.path.relpath(p, repo).replace("\\", "/")
    except ValueError:               # different drive on Windows
        return str(p).replace("\\", "/")


def main(argv=None):
    ap = argparse.ArgumentParser(description="list A/B slice artifacts that have no verdict line in runs/ab/INDEX.md")
    ap.add_argument("--repo", default=str(Path(__file__).resolve().parent.parent), help="repo root (default: parent of tools/)")
    ap.add_argument("--index", help="INDEX file (default: <repo>/runs/ab/INDEX.md)")
    ap.add_argument("--root", action="append", help="directory to scan for artifacts; repeatable; replaces the defaults "
                    "(<repo>/runs, <repo>/linux/power/cx-collapse/runs)")
    ap.add_argument("--since", type=float, metavar="DAYS", help="list only unindexed artifacts modified in the last DAYS days")
    ap.add_argument("--quiet", action="store_true", help="print only the problems")
    args = ap.parse_args(argv)
    if args.since is not None and not args.since > 0:
        ap.error("--since DAYS must be > 0 (got %g)" % args.since)       # exit 2; 0 or negative would hide every artifact

    repo = Path(args.repo).resolve()
    index_path = Path(args.index).resolve() if args.index else repo / DEFAULT_INDEX
    roots = [Path(r).resolve() for r in args.root] if args.root else [repo / r for r in DEFAULT_ROOTS]
    if not index_path.is_file():
        print("ab-index-check: INDEX not found: %s" % index_path, file=sys.stderr)
        return 2
    missing = [r for r in roots if not r.is_dir()]
    if missing:
        print("ab-index-check: root not found: %s" % ", ".join(str(r) for r in missing), file=sys.stderr)
        return 2

    artifacts = find_artifacts(roots)
    try:
        entry_targets, excluded, dangling, malformed, n_entries, n_links, n_excl = parse_index(index_path, repo)
    except UnicodeDecodeError as e:
        print("ab-index-check: INDEX is not UTF-8: %s (%s)" % (index_path, e), file=sys.stderr)
        return 2
    linked_files = {norm(t) for t in entry_targets if t.is_file()}
    linked_dirs = {norm(t) for t in entry_targets if t.is_dir()}
    linked_files |= {norm(t) for t in excluded if t.is_file()}       # exclusion lines cover like entries do,
    linked_dirs |= {norm(t) for t in excluded if t.is_dir()}         # and the root rule below still applies to them
    root_keys = {norm(r) for r in roots}
    root_keys.add(norm(index_path.parent))      # one "- [all](.)" line must not silence every fr-slice output in runs/ab/
    # the parents of a root never cover either (a link to "linux/power/" must not silence every run under it)
    for r in roots:
        p = r.parent
        while p != p.parent:
            root_keys.add(norm(p))
            p = p.parent

    unindexed = [a for a in artifacts if not covered(a, linked_files, linked_dirs, root_keys)]
    hidden = 0
    if args.since is not None:
        cutoff = time.time() - args.since * 86400
        recent = [a for a in unindexed if a.stat().st_mtime >= cutoff]
        hidden = len(unindexed) - len(recent)
        unindexed = recent
    unindexed.sort(key=lambda a: (time.strftime("%Y-%m-%d", time.localtime(a.stat().st_mtime)), rel(a, repo)))

    if not args.quiet:
        print("ab-index-check: index %s: %d entr%s, %d link%s, %d exclusion%s; roots: %s; artifacts: %d, indexed: %d" % (
            rel(index_path, repo), n_entries, "y" if n_entries == 1 else "ies", n_links, "" if n_links == 1 else "s",
            n_excl, "" if n_excl == 1 else "s",
            ", ".join(rel(r, repo) for r in roots), len(artifacts), len(artifacts) - len(unindexed) - hidden))
    if unindexed or not args.quiet:
        suffix = "" if args.since is None else " (--since %g: %d older one%s hidden)" % (args.since, hidden, "" if hidden == 1 else "s")
        print("(a) artifacts without a verdict line: %d%s" % (len(unindexed), suffix))
        for a in unindexed:
            print("  %s  %s" % (time.strftime("%Y-%m-%d", time.localtime(a.stat().st_mtime)), rel(a, repo)))
    if dangling or not args.quiet:
        print("(b) INDEX links whose target does not exist: %d" % len(dangling))
        for lineno, target in dangling:
            print("  %s:%d  %s" % (index_path.name, lineno, target))
    if malformed or not args.quiet:
        print("(c) INDEX entry lines not in the appendix C shape: %d" % len(malformed))
        for lineno, reason in malformed:
            print("  %s:%d  %s" % (index_path.name, lineno, reason))
    return 1 if (unindexed or dangling) else 0


if __name__ == "__main__":
    if (sys.stdout.encoding or "").lower().replace("-", "") != "utf8":
        sys.stdout.reconfigure(errors="replace")      # run with "python -X utf8" for exact output
    sys.exit(main())
