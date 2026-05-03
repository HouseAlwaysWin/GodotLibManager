extends RefCounted
class_name GdlmRegistryLoader

## Merges remote registry JSON files and manual owner/repo entries.
## Each entry: { name, owner, repo, description, addon_dir }


## Accepts `owner/repo` or full URLs like `https://github.com/owner/repo` or `.../tree/main`.
static func parse_owner_repo(s: String) -> Dictionary:
	var t := s.strip_edges()
	if t.is_empty():
		return {}
	var q := t.find("?")
	if q >= 0:
		t = t.substr(0, q)
	var h := t.find("#")
	if h >= 0:
		t = t.substr(0, h)
	t = t.strip_edges()
	var tl := t.to_lower()
	# Bare host with no repository path.
	if tl in ["https://github.com", "http://github.com", "https://www.github.com", "http://www.github.com", "github.com"]:
		return {}
	var prefixes := [
		"https://github.com/",
		"http://github.com/",
		"https://www.github.com/",
		"http://www.github.com/",
	]
	for p in prefixes:
		if tl.begins_with(p):
			t = t.substr(p.length())
			break
	tl = t.to_lower()
	if tl.begins_with("github.com/"):
		t = t.substr("github.com/".length())
	t = t.trim_suffix("/")
	t = t.trim_suffix(".git")
	var segments: Array = []
	for part in t.split("/", false):
		var seg := str(part).strip_edges()
		if not seg.is_empty():
			segments.append(seg)
	if segments.size() < 2:
		return {}
	var owner_s := str(segments[0])
	var repo_s := str(segments[1])
	# Reject `https://github.com`-style splits (owner would contain ":").
	if ":" in owner_s:
		return {}
	if owner_s.is_empty() or repo_s.is_empty():
		return {}
	return {"owner": owner_s, "repo": repo_s}


## Returns canonical `owner/repo` or "" if invalid.
static func canonical_owner_repo(s: String) -> String:
	var d := parse_owner_repo(s)
	if d.is_empty():
		return ""
	return "%s/%s" % [str(d.get("owner", "")), str(d.get("repo", ""))]


static func _entry_from_registry_dict(d: Dictionary) -> Dictionary:
	var owner := str(d.get("owner", "")).strip_edges()
	var repo := str(d.get("repo", "")).strip_edges()
	if owner.is_empty() or repo.is_empty():
		return {}
	var name := str(d.get("name", "%s/%s" % [owner, repo])).strip_edges()
	var repo_url := str(d.get("repo_html_url", "")).strip_edges()
	if repo_url.is_empty():
		repo_url = "https://github.com/%s/%s" % [owner, repo]
	return {
		"name": name,
		"owner": owner,
		"repo": repo,
		"description": str(d.get("description", "")),
		"addon_dir": str(d.get("addon_dir", "")).strip_edges(),
		"repo_html_url": repo_url,
	}


static func _dedupe_by_source(items: Array) -> Array:
	var seen := {}
	var out: Array = []
	for it in items:
		if not it is Dictionary:
			continue
		var d: Dictionary = it
		var o := str(d.get("owner", "")).strip_edges()
		var r := str(d.get("repo", "")).strip_edges()
		var key := GdlmSettings.source_key(o, r)
		if o.is_empty() or r.is_empty():
			continue
		if seen.has(key):
			continue
		seen[key] = true
		out.append(d)
	return out


## client.fetch_text must work. registries: PackedStringArray of URLs.
## Not static: requires await.
func load_registries(client: GdlmGithubClient, urls: PackedStringArray) -> Array:
	var merged: Array = []
	for url in urls:
		var u := str(url).strip_edges()
		if u.is_empty():
			continue
		var res: Dictionary = await client.fetch_text(u)
		if not res.get("ok", false):
			push_warning("GdlmRegistryLoader: failed to load %s — %s" % [u, res.get("error", "")])
			continue
		var parsed: Variant = JSON.parse_string(res.text)
		if parsed == null:
			push_warning("GdlmRegistryLoader: invalid JSON at %s" % u)
			continue
		if parsed is Array:
			for el in parsed:
				if el is Dictionary:
					var e := _entry_from_registry_dict(el)
					if not e.is_empty():
						merged.append(e)
		elif parsed is Dictionary:
			var root: Dictionary = parsed
			var plugins: Variant = root.get("plugins", [])
			if plugins is Array:
				for el in plugins:
					if el is Dictionary:
						var e2 := _entry_from_registry_dict(el)
						if not e2.is_empty():
							merged.append(e2)
	return _dedupe_by_source(merged)


static func load_manual_entries(repos: PackedStringArray) -> Array:
	var out: Array = []
	for line in repos:
		var pr := parse_owner_repo(str(line))
		if pr.is_empty():
			push_warning("GdlmRegistryLoader: skip invalid manual repo (fix or remove in Settings): %s" % str(line))
			continue
		var owner: String = str(pr.get("owner", ""))
		var repo: String = str(pr.get("repo", ""))
		out.append(
			{
				"name": "%s/%s" % [owner, repo],
				"owner": owner,
				"repo": repo,
				"description": "",
				"addon_dir": "",
				"repo_html_url": "https://github.com/%s/%s" % [owner, repo],
			}
		)
	return _dedupe_by_source(out)


func load_all(client: GdlmGithubClient, registries: PackedStringArray, manual: PackedStringArray) -> Array:
	var a := await load_registries(client, registries)
	var b := GdlmRegistryLoader.load_manual_entries(manual)
	var seen := {}
	for it in a:
		var d: Dictionary = it
		seen[GdlmSettings.source_key(str(d.get("owner", "")), str(d.get("repo", "")))] = true
	for it in b:
		var d2: Dictionary = it
		var k := GdlmSettings.source_key(str(d2.get("owner", "")), str(d2.get("repo", "")))
		if not seen.has(k):
			a.append(d2)
			seen[k] = true
	return a
