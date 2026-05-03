extends RefCounted
class_name GdlmGithubClient

const API_BASE := "https://api.github.com"
const ASSET_LIB_API := "https://godotengine.org/asset-library/api"

## Last parsed rate limit (updated after each request).
var rate_limit_remaining: int = -1
var rate_limit_reset_unix: int = -1

var _parent: Node
var _token: String = ""


func _init(parent: Node) -> void:
	_parent = parent


func set_token(token: String) -> void:
	_token = token.strip_edges()


func _build_headers(for_api: bool) -> PackedStringArray:
	var h: PackedStringArray = PackedStringArray()
	if for_api:
		h.append("Accept: application/vnd.github+json")
		h.append("X-GitHub-Api-Version: 2022-11-28")
	else:
		h.append("Accept: application/octet-stream")
	if not _token.is_empty():
		h.append("Authorization: Bearer %s" % _token)
	# GitHub rejects requests without a User-Agent.
	h.append("User-Agent: GodotLibManager/0.1 (Godot Editor)")
	return h


func _parse_rate_limit_headers(headers: PackedStringArray) -> void:
	rate_limit_remaining = -1
	rate_limit_reset_unix = -1
	for line in headers:
		var lower := line.to_lower()
		if lower.begins_with("x-ratelimit-remaining:"):
			var parts := line.split(":", false, 1)
			if parts.size() >= 2:
				rate_limit_remaining = int(parts[1].strip_edges())
		elif lower.begins_with("x-ratelimit-reset:"):
			var parts2 := line.split(":", false, 1)
			if parts2.size() >= 2:
				rate_limit_reset_unix = int(parts2[1].strip_edges())


func _do_request(url: String, for_api: bool) -> Dictionary:
	var http := HTTPRequest.new()
	_parent.add_child(http)
	var err: Error = http.request(url, _build_headers(for_api), HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return {
			"ok": false,
			"code": 0,
			"body": PackedByteArray(),
			"text": "",
			"error": "request_failed: %s" % str(err),
		}
	var result: Array = await http.request_completed
	http.queue_free()
	var response_code: int = result[1]
	var response_headers: PackedStringArray = result[2]
	var response_body: PackedByteArray = result[3]
	_parse_rate_limit_headers(response_headers)
	var text := response_body.get_string_from_utf8()
	return {
		"ok": response_code >= 200 and response_code < 300,
		"code": response_code,
		"body": response_body,
		"text": text,
		"error": "" if response_code >= 200 and response_code < 300 else "http_%s" % str(response_code),
	}


## Generic GET for non-GitHub JSON APIs (no GitHub auth / rate-limit headers).
func _do_request_json(url: String) -> Dictionary:
	var http := HTTPRequest.new()
	_parent.add_child(http)
	var h := PackedStringArray()
	h.append("Accept: application/json")
	h.append("User-Agent: GodotLibManager/0.1 (Godot Editor)")
	var err: Error = http.request(url, h, HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return {
			"ok": false,
			"code": 0,
			"text": "",
			"error": "request_failed: %s" % str(err),
		}
	var result: Array = await http.request_completed
	http.queue_free()
	var response_code: int = result[1]
	var response_body: PackedByteArray = result[3]
	var text := response_body.get_string_from_utf8()
	return {
		"ok": response_code >= 200 and response_code < 300,
		"code": response_code,
		"text": text,
		"error": "" if response_code >= 200 and response_code < 300 else "http_%s" % str(response_code),
	}


## Returns { ok, releases: Array, error, code } — releases from JSON array or empty.
func fetch_releases(owner: String, repo: String) -> Dictionary:
	var url := "%s/repos/%s/%s/releases?per_page=100" % [API_BASE, owner.uri_encode(), repo.uri_encode()]
	var res: Dictionary = await _do_request(url, true)
	if not res.ok:
		return {
			"ok": false,
			"releases": [],
			"error": res.get("text", res.error),
			"code": res.code,
		}
	var parsed: Variant = JSON.parse_string(res.text)
	if parsed == null:
		return {"ok": false, "releases": [], "error": "invalid_json", "code": res.code}
	if not parsed is Array:
		return {"ok": false, "releases": [], "error": "expected_array", "code": res.code}
	return {"ok": true, "releases": parsed, "error": "", "code": res.code}


## Probe GitHub for at least one release (`per_page=1`). Returns { has_releases, uncertain }.
## If `uncertain` (API error), callers should not drop the repo.
func check_repo_has_any_release(owner: String, repo: String) -> Dictionary:
	var o := owner.strip_edges()
	var r := repo.strip_edges()
	if o.is_empty() or r.is_empty():
		return {"has_releases": false, "uncertain": true}
	var url := "%s/repos/%s/%s/releases?per_page=1" % [API_BASE, o.uri_encode(), r.uri_encode()]
	var res: Dictionary = await _do_request(url, true)
	if not res.ok:
		return {"has_releases": false, "uncertain": true}
	var parsed: Variant = JSON.parse_string(res.text)
	if parsed == null or not parsed is Array:
		return {"has_releases": false, "uncertain": true}
	var arr: Array = parsed
	return {"has_releases": arr.size() > 0, "uncertain": false}


## GET /repos/{owner}/{repo} — returns { ok, topics: PackedStringArray } (repository "topics" field).
func fetch_repository_topics(owner: String, repo: String) -> Dictionary:
	var o := owner.strip_edges()
	var r := repo.strip_edges()
	if o.is_empty() or r.is_empty():
		return {"ok": false, "topics": PackedStringArray()}
	var url := "%s/repos/%s/%s" % [API_BASE, o.uri_encode(), r.uri_encode()]
	var res: Dictionary = await _do_request(url, true)
	if not res.ok:
		return {"ok": false, "topics": PackedStringArray()}
	var parsed: Variant = JSON.parse_string(res.text)
	if parsed == null or not parsed is Dictionary:
		return {"ok": false, "topics": PackedStringArray()}
	var root: Dictionary = parsed
	var tv: Variant = root.get("topics", [])
	var out := PackedStringArray()
	if tv is Array:
		for x in tv:
			out.append(str(x))
	return {"ok": true, "topics": out}


## Latest release object or prerelease skipped? GitHub /releases/latest is latest non-draft stable.
func fetch_latest(owner: String, repo: String) -> Dictionary:
	var url := "%s/repos/%s/%s/releases/latest" % [API_BASE, owner.uri_encode(), repo.uri_encode()]
	var res: Dictionary = await _do_request(url, true)
	if not res.ok:
		return {"ok": false, "release": {}, "error": res.get("text", res.error), "code": res.code}
	var parsed: Variant = JSON.parse_string(res.text)
	if parsed == null or not parsed is Dictionary:
		return {"ok": false, "release": {}, "error": "invalid_json", "code": res.code}
	return {"ok": true, "release": parsed, "error": "", "code": res.code}


## Download binary (e.g. release asset URL). Writes to dest_path (absolute or user://).
func download_asset(url: String, dest_path: String) -> Dictionary:
	var res: Dictionary = await _do_request(url, false)
	if not res.ok:
		return {"ok": false, "error": res.get("text", res.error), "code": res.code}
	var f := FileAccess.open(dest_path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": "open_failed: %s" % dest_path, "code": res.code}
	f.store_buffer(res.body)
	f.close()
	return {"ok": true, "error": "", "code": res.code}


## GET arbitrary URL (registry JSON). Returns text body.
func fetch_text(url: String) -> Dictionary:
	var res: Dictionary = await _do_request(url, false)
	if not res.ok:
		return {"ok": false, "text": "", "error": res.get("text", res.error), "code": res.code}
	return {"ok": true, "text": res.text, "error": "", "code": res.code}


## GitHub Search API — returns { ok, items: Array[Dictionary], total, error }.
## GitHub allows at most ~1000 hits per query; `per_page` max 100.
func search_repositories(query: String, page: int = 1, per_page: int = 30) -> Dictionary:
	var q := query.strip_edges()
	if q.is_empty():
		return {"ok": false, "items": [], "total": 0, "error": "empty_query"}
	var pp := clampi(per_page, 1, 100)
	var max_page := maxi(1, mini(100, int(ceil(1000.0 / float(pp)))))
	var pg := clampi(page, 1, max_page)
	var url := "%s/search/repositories?q=%s&sort=stars&per_page=%s&page=%s" % [
		API_BASE,
		q.uri_encode(),
		str(pp),
		str(pg),
	]
	var res: Dictionary = await _do_request(url, true)
	if not res.ok:
		return {"ok": false, "items": [], "total": 0, "error": res.get("text", res.error)}
	var parsed: Variant = JSON.parse_string(res.text)
	if parsed == null or not parsed is Dictionary:
		return {"ok": false, "items": [], "total": 0, "error": "invalid_json"}
	var root: Dictionary = parsed
	var items: Variant = root.get("items", [])
	var arr: Array = []
	if items is Array:
		arr = items
	var total: int = int(root.get("total_count", 0))
	return {"ok": true, "items": arr, "total": total, "error": ""}


## Official Godot Asset Library — resolves browse_url to GitHub owner/repo; install still uses GitHub releases.
## Returns { ok, plugins: Array[Dictionary], total_matches, error } — same plugin shape as registry entries + _from_search, _from_asset_library.
func search_asset_library_plugins(
	query: String, max_results: int = 30, page: int = 0
) -> Dictionary:
	var q := query.strip_edges()
	if q.is_empty():
		return {"ok": false, "plugins": [], "total_matches": 0, "error": "empty_query"}
	var cap := mini(maxi(max_results, 1), 30)
	var pg := maxi(0, page)
	var list_url := "%s/asset?filter=%s&max_results=%s&page=%s&sort=relevance" % [
		ASSET_LIB_API,
		q.uri_encode(),
		str(cap),
		str(pg),
	]
	var res: Dictionary = await _do_request_json(list_url)
	if not res.ok:
		return {"ok": false, "plugins": [], "total_matches": 0, "error": res.get("text", res.error)}
	var parsed: Variant = JSON.parse_string(res.text)
	if parsed == null or not parsed is Dictionary:
		return {"ok": false, "plugins": [], "total_matches": 0, "error": "invalid_json"}
	var root: Dictionary = parsed
	var rows: Variant = root.get("result", [])
	var total_matches: int = int(root.get("total_items", 0))
	var arr: Array = rows if rows is Array else []
	var plugins: Array = []
	for row in arr:
		if plugins.size() >= cap:
			break
		if not row is Dictionary:
			continue
		var rd: Dictionary = row
		var rid := str(rd.get("asset_id", "")).strip_edges()
		if rid.is_empty():
			continue
		var detail_url := "%s/asset/%s" % [ASSET_LIB_API, rid.uri_encode()]
		var dres: Dictionary = await _do_request_json(detail_url)
		if not dres.ok:
			continue
		var detail_parsed: Variant = JSON.parse_string(dres.text)
		if detail_parsed == null or not detail_parsed is Dictionary:
			continue
		var det: Dictionary = detail_parsed
		var browse := str(det.get("browse_url", "")).strip_edges()
		var pr := GdlmRegistryLoader.parse_owner_repo(browse)
		if pr.is_empty():
			continue
		var owner := str(pr.get("owner", ""))
		var repo := str(pr.get("repo", ""))
		if owner.is_empty() or repo.is_empty():
			continue
		var icon_u := str(det.get("icon_url", "")).strip_edges()
		var al_page := "https://godotengine.org/asset-library/asset/%s" % rid.uri_encode()
		plugins.append(
			{
				"name": str(det.get("title", "%s/%s" % [owner, repo])).strip_edges(),
				"owner": owner,
				"repo": repo,
				"description": str(det.get("description", "")).strip_edges(),
				"addon_dir": "",
				"repo_html_url": browse,
				"icon_url": icon_u,
				"asset_library_url": al_page,
				"_from_search": true,
				"_from_asset_library": true,
			}
		)
	return {"ok": true, "plugins": plugins, "total_matches": total_matches, "error": ""}
