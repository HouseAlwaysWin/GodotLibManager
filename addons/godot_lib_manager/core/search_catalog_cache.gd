extends RefCounted

## Persists the offline search catalog under user:// (GitHub topic snapshot).

const CACHE_PATH := "user://gdlm_search_catalog.json"
const VERSION := 5


static func load_snapshot() -> Dictionary:
	var f := FileAccess.open(CACHE_PATH, FileAccess.READ)
	if f == null:
		return {"ok": false, "entries": [], "saved_unix": 0}
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null or not parsed is Dictionary:
		return {"ok": false, "entries": [], "saved_unix": 0}
	var root: Dictionary = parsed
	if int(root.get("version", 0)) != VERSION:
		return {"ok": false, "entries": [], "saved_unix": 0}
	var entries: Array = []
	var ev: Variant = root.get("entries", [])
	if ev is Array:
		for x in ev:
			if x is Dictionary:
				entries.append((x as Dictionary).duplicate(true))
	return {
		"ok": true,
		"entries": entries,
		"saved_unix": int(root.get("saved_unix", 0)),
	}


static func delete_snapshot_file() -> void:
	if not FileAccess.file_exists(CACHE_PATH):
		return
	var gp := ProjectSettings.globalize_path(CACHE_PATH)
	var err := DirAccess.remove_absolute(gp)
	if err != OK:
		push_warning("GdlmSearchCatalogCache: could not delete %s (%s)" % [gp, error_string(err)])


static func save_snapshot(entries: Array) -> void:
	var packed: Array = []
	for e in entries:
		if e is Dictionary:
			packed.append((e as Dictionary).duplicate(true))
	var root := {
		"version": VERSION,
		"saved_unix": Time.get_unix_time_from_system(),
		"entries": packed,
	}
	var f := FileAccess.open(CACHE_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("GdlmSearchCatalogCache: could not write %s" % CACHE_PATH)
		return
	f.store_string(JSON.stringify(root))
	f.close()
