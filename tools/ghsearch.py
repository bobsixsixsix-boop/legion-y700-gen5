import json, sys, time, urllib.request, urllib.parse
qs = sys.argv[1:]
for q in qs:
    url = "https://api.github.com/search/repositories?" + urllib.parse.urlencode({"q": q, "sort": "updated", "per_page": 30})
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "y700-search"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            d = json.load(r)
    except Exception as e:
        print("!!", q, e); continue
    print("==", q, d.get("total_count"))
    for it in d.get("items", []):
        print("  %-55s c=%s p=%s ★%s %s" % (it["full_name"], it["created_at"][:10], it["pushed_at"][:10], it["stargazers_count"], (it["description"] or "")[:90]))
    time.sleep(7)
