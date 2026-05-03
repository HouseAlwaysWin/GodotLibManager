extends RefCounted
class_name GdlmGithubClient

const API_BASE := "https://api.github.com"

## Unix time for catalog sort (newest first). GitHub: pushed_at / updated_at.
static func catalog_sort_unix_from_github_item(item: Dictionary) -> int:
	var s := str(item.get("pushed_at", item.get("updated_at", ""))).strip_edges()
	return catalog_sort_unix_from_date_string(s)


static func catalog_sort_unix_from_date_string(s: String) -> int:
	s = s.strip_edges()
	if s.is_empty():
		return 0
	var u := Time.get_unix_time_from_datetime_string(s)
	if u >= 0:
		return u
	if (" " in s) and (not s.contains("T")):
		var alt := s.substr(0, 10) + "T" + s.substr(11).strip_edges() + "Z"
		u = Time.get_unix_time_from_datetime_string(alt)
		if u >= 0:
			return u
	return 0


## Last parsed rate limit (updated after each request).
var rate_limit_remaining: int = -1
var rate_limit_reset_unix: int = -1
## REST core quota ceiling from GET /rate_limit (optional display).
var rate_limit_limit: int = -1

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


## GET /rate_limit — cheap; updates rate_limit_* so the status bar can show quota without a prior API call.
func refresh_rate_limit_from_api() -> void:
	var url := "%s/rate_limit" % API_BASE
	var res: Dictionary = await _do_request(url, true)
	if not res.ok:
		return
	var parsed: Variant = JSON.parse_string(res.text)
	if parsed == null or not parsed is Dictionary:
		return
	var resources: Variant = parsed.get("resources", {})
	if not resources is Dictionary:
		return
	var core: Variant = resources.get("core", {})
	if not core is Dictionary:
		return
	var c: Dictionary = core
	rate_limit_limit = int(c.get("limit", -1))
	rate_limit_remaining = int(c.get("remaining", -1))
	var rs := int(c.get("reset", 0))
	if rs > 0:
		rate_limit_reset_unix = rs


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
