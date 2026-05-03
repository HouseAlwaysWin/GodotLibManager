extends RefCounted
class_name GdlmGithubClient

const API_BASE := "https://api.github.com"

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
