#!/usr/bin/env python3
# Auto-updates sidestep-apps.json: for each app, find the newest release with an
# .ipa in its source GitHub repo (parsed from the current downloadURL) and, if it
# changed, update version + downloadURL + size. Runs in GitHub Actions (free on
# public repos) via the built-in GITHUB_TOKEN. Icons are left as-is.
import json, os, re, sys, urllib.request

CATALOG = "sidestep-apps.json"

def api(url):
    req = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json", "User-Agent": "sidestep-catalog-bot"})
    tok = os.environ.get("GH_TOKEN")
    if tok:
        req.add_header("Authorization", f"Bearer {tok}")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)

def latest_ipa(owner, repo):
    """Newest release (newest-first) that carries an .ipa asset."""
    for rel in api(f"https://api.github.com/repos/{owner}/{repo}/releases?per_page=30"):
        for a in rel.get("assets", []):
            if a["name"].lower().endswith(".ipa"):
                return rel["tag_name"], a["browser_download_url"], a["size"]
    return None

def main():
    d = json.load(open(CATALOG))
    changed = False
    for app in d.get("apps", []):
        vers = app.get("versions") or []
        if not vers:
            continue
        v = vers[0]
        m = re.match(r"https://github\.com/([^/]+)/([^/]+)/releases/", v.get("downloadURL", ""))
        if not m:
            print(f"skip {app.get('name')}: non-GitHub downloadURL")
            continue
        owner, repo = m.group(1), m.group(2)
        try:
            got = latest_ipa(owner, repo)
        except Exception as e:
            print(f"skip {app.get('name')}: {e}")
            continue
        if not got:
            print(f"skip {app.get('name')}: no .ipa release found in {owner}/{repo}")
            continue
        tag, url, size = got
        newver = tag[1:] if tag.startswith("v") else tag
        if url != v.get("downloadURL"):
            print(f"update {app.get('name')}: {v.get('version')} -> {newver}")
            v["version"], v["downloadURL"], v["size"] = newver, url, size
            changed = True
        else:
            print(f"ok     {app.get('name')}: already {v.get('version')}")
    if changed:
        with open(CATALOG, "w") as f:
            json.dump(d, f, indent=2, ensure_ascii=False)
            f.write("\n")
        print("catalog updated")
    else:
        print("no changes")

if __name__ == "__main__":
    main()
