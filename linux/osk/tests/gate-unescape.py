"""Print the last N lines of a busctl string reply (y700-osk `debug gate`), unescaped and indented."""
import sys

s = sys.stdin.read()
if '"' in s:
    s = s[s.index('"') + 1:s.rindex('"')].encode().decode("unicode_escape")
n = int(sys.argv[1]) if len(sys.argv) > 1 else 7
for line in s.splitlines()[-n:]:
    print("   | " + line)
