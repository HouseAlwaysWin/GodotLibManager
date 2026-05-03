extends RefCounted
class_name GdlmPluginInstaller

var _editor: EditorPlugin


func _init(editor_plugin: EditorPlugin) -> void:
	_editor = editor_plugin


func _editor_interface() -> EditorInterface:
	return _editor.get_editor_interface()


## Pick best .zip asset from a GitHub release JSON object.
func pick_zip_asset_url(release: Dictionary, addon_hint: String) -> String:
	var assets: Variant = release.get("assets", [])
	if not assets is Array:
		return ""
	var hint := addon_hint.strip_edges().to_lower()
	var candidates: Array = []
	for a in assets:
		if not a is Dictionary:
			continue
		var ad: Dictionary = a
		var name := str(ad.get("name", "")).to_lower()
		if not name.ends_with(".zip"):
			continue
		var url := str(ad.get("browser_download_url", ""))
		if url.is_empty():
			continue
		candidates.append({"name": name, "url": url})
	if candidates.is_empty():
		return ""
	if not hint.is_empty():
		for c in candidates:
			if hint in str(c.name):
				return str(c.url)
		for c in candidates:
			var n := str(c.name)
			if n.ends_with("%s.zip" % hint) or n.ends_with("_%s.zip" % hint):
				return str(c.url)
	return str(candidates[0].url)


func _normalize_addon_relative(zip_inner_path: String) -> String:
	var p := zip_inner_path.replace("\\", "/")
	var marker := "/addons/"
	var idx := p.find(marker)
	if idx != -1:
		return p.substr(idx + 1)
	if p.begins_with("addons/"):
		return p
	return ""


func _addon_root_from_relative(rel: String) -> String:
	if not rel.begins_with("addons/"):
		return ""
	var rest := rel.trim_prefix("addons/")
	var seg := rest.get_slice("/", 0)
	if seg.is_empty():
		return ""
	return "addons/%s" % seg


func _slug_for_addon_folder(display_name: String) -> String:
	var s := display_name.strip_edges().to_lower()
	s = s.replace(" ", "_")
	for ch in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]:
		s = s.replace(ch, "_")
	while s.contains("__"):
		s = s.replace("__", "_")
	return s if not s.is_empty() else "addon"


func _plugin_name_from_cfg_text(txt: String) -> String:
	var in_section := false
	for raw in txt.split("\n"):
		var line := raw.strip_edges()
		if line.begins_with(";") or line.is_empty():
			continue
		if line == "[plugin]":
			in_section = true
			continue
		if line.begins_with("["):
			in_section = false
			continue
		if not in_section:
			continue
		if line.begins_with("name"):
			var eq := line.find("=")
			if eq < 0:
				continue
			var val := line.substr(eq + 1).strip_edges()
			val = val.trim_prefix('"').trim_suffix('"').trim_prefix("'").trim_suffix("'")
			return val.strip_edges()
	return ""


## When zip has no addons/ paths, find plugin.cfg and install that folder under res://addons/<slug>/.
func _install_plugin_cfg_fallback(zip_path: String) -> Dictionary:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return {"ok": false, "addon_dirs": [], "error": "zip_open_failed"}
	var files: PackedStringArray = reader.get_files()
	var cfg_paths: Array = []
	for entry in files:
		var p := str(entry).replace("\\", "/")
		if p.ends_with("/"):
			continue
		if p.get_file().to_lower() != "plugin.cfg":
			continue
		cfg_paths.append(p)
	if cfg_paths.is_empty():
		reader.close()
		return {"ok": false, "addon_dirs": [], "error": "zip_contains_no_addons_folder"}
	var installed: Dictionary = {}
	var used_slugs := {}
	for cfg_path in cfg_paths:
		var cfg_inner: String = str(cfg_path).replace("\\", "/")
		var root_in_zip := cfg_inner.get_base_dir()
		var prefix := ""
		if not root_in_zip.is_empty():
			prefix = root_in_zip + "/"
		var txt := reader.read_file(cfg_inner).get_string_from_utf8()
		var pname := _plugin_name_from_cfg_text(txt)
		if pname.is_empty():
			pname = root_in_zip.get_file() if not root_in_zip.is_empty() else "plugin"
		var slug := _slug_for_addon_folder(pname)
		var base_slug := slug
		var n := 2
		while used_slugs.has(slug):
			slug = "%s_%s" % [base_slug, str(n)]
			n += 1
		used_slugs[slug] = true
		var dest_root := "addons/%s" % slug
		var single_cfg_zip := cfg_paths.size() == 1
		for entry2 in files:
			var inner := str(entry2).replace("\\", "/")
			if inner.ends_with("/"):
				continue
			var include := false
			var tail := ""
			if prefix.is_empty():
				# e.g. GitHub zipball: one top folder; or a lone plugin.cfg with subfolders
				if single_cfg_zip:
					include = true
					tail = inner
				elif not inner.contains("/"):
					include = true
					tail = inner
			elif inner.begins_with(prefix):
				include = true
				tail = inner.substr(prefix.length())
			if not include:
				continue
			var dest_rel := "%s/%s" % [dest_root, tail]
			dest_rel = dest_rel.replace("//", "/")
			var dest_res := "res://%s" % dest_rel
			var parent_abs := ProjectSettings.globalize_path(dest_res.get_base_dir())
			DirAccess.make_dir_recursive_absolute(parent_abs)
			var buf: PackedByteArray = reader.read_file(inner)
			var f := FileAccess.open(dest_res, FileAccess.WRITE)
			if f == null:
				reader.close()
				return {"ok": false, "addon_dirs": installed.keys(), "error": "write_failed: %s" % dest_res}
			f.store_buffer(buf)
			f.close()
		installed[dest_root] = true
	reader.close()
	var addon_list: Array = installed.keys()
	addon_list.sort()
	_editor_interface().get_resource_filesystem().scan()
	return {"ok": true, "addon_dirs": addon_list, "error": ""}


## Extract paths under addons/, else detect plugin.cfg trees (GitHub zipball layout).
func install_from_zip(zip_path: String) -> Dictionary:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return {"ok": false, "addon_dirs": [], "error": "zip_open_failed"}
	var roots: Dictionary = {}
	var files: PackedStringArray = reader.get_files()
	for entry in files:
		var inner: String = str(entry).replace("\\", "/")
		if inner.ends_with("/"):
			continue
		var rel := _normalize_addon_relative(inner)
		if rel.is_empty():
			continue
		var dest_res := "res://%s" % rel
		var abs_dest := ProjectSettings.globalize_path(dest_res)
		var parent_abs := abs_dest.get_base_dir()
		DirAccess.make_dir_recursive_absolute(parent_abs)
		var buf: PackedByteArray = reader.read_file(inner)
		if buf.is_empty() and not inner.ends_with("/"):
			# allow empty files
			pass
		var f := FileAccess.open(dest_res, FileAccess.WRITE)
		if f == null:
			reader.close()
			return {"ok": false, "addon_dirs": roots.keys(), "error": "write_failed: %s" % dest_res}
		f.store_buffer(buf)
		f.close()
		var root := _addon_root_from_relative(rel)
		if not root.is_empty():
			roots[root] = true
	reader.close()
	var addon_list: Array = roots.keys()
	addon_list.sort()
	_editor_interface().get_resource_filesystem().scan()
	if addon_list.is_empty():
		return _install_plugin_cfg_fallback(zip_path)
	return {"ok": true, "addon_dirs": addon_list, "error": ""}


func _cache_zip_path(owner: String, repo: String, tag: String) -> String:
	var safe := "%s__%s__%s.zip" % [owner, repo, tag]
	safe = safe.replace("/", "_").replace("\\", "_")
	return "user://gdlm_cache/%s" % safe


func ensure_cache_dir() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://gdlm_cache"))


func ensure_backup_dir() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://gdlm_backup"))


## Backup res-relative addon dirs (e.g. addons/foo) to user://gdlm_backup/<stamp>/...
func backup_addon_dirs(addon_dirs: Array) -> void:
	if addon_dirs.is_empty():
		return
	ensure_backup_dir()
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var base := "user://gdlm_backup/%s" % stamp
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(base))
	for ad in addon_dirs:
		var rel := str(ad).strip_edges()
		if rel.is_empty():
			continue
		var src := "res://%s" % rel.trim_prefix("/")
		var abs_src := ProjectSettings.globalize_path(src)
		if not DirAccess.dir_exists_absolute(abs_src):
			continue
		var dest := "%s/%s" % [base, rel.get_file()]
		var abs_dest := ProjectSettings.globalize_path(dest)
		_copy_dir_recursive(abs_src, abs_dest)


func _copy_dir_recursive(src_abs: String, dst_abs: String) -> void:
	DirAccess.make_dir_recursive_absolute(dst_abs)
	var da := DirAccess.open(src_abs)
	if da == null:
		return
	da.list_dir_begin()
	var n := da.get_next()
	while n != "":
		if n == "." or n == "..":
			n = da.get_next()
			continue
		var p := "%s/%s" % [src_abs, n]
		if da.current_is_dir():
			_copy_dir_recursive(p, "%s/%s" % [dst_abs, n])
		else:
			var from := FileAccess.open(p, FileAccess.READ)
			if from:
				var to_path := "%s/%s" % [dst_abs, n]
				DirAccess.make_dir_recursive_absolute(dst_abs)
				var to := FileAccess.open(to_path, FileAccess.WRITE)
				if to:
					to.store_buffer(from.get_buffer(from.get_length()))
					to.close()
				from.close()
		n = da.get_next()
	da.list_dir_end()


func _remove_dir_recursive(abs_path: String) -> Error:
	if not DirAccess.dir_exists_absolute(abs_path):
		return OK
	var da := DirAccess.open(abs_path)
	if da == null:
		return ERR_CANT_OPEN
	da.list_dir_begin()
	var n := da.get_next()
	while n != "":
		if n == "." or n == "..":
			n = da.get_next()
			continue
		var p := "%s/%s" % [abs_path, n]
		if da.current_is_dir():
			var sub := _remove_dir_recursive(p)
			if sub != OK:
				da.list_dir_end()
				return sub
		else:
			DirAccess.remove_absolute(p)
		n = da.get_next()
	da.list_dir_end()
	return DirAccess.remove_absolute(abs_path)


func uninstall_addon_dirs(addon_dirs: Array) -> Dictionary:
	for ad in addon_dirs:
		var rel := str(ad).strip_edges().trim_prefix("/")
		if rel.is_empty():
			continue
		var res_path := "res://%s" % rel
		var abs_path := ProjectSettings.globalize_path(res_path)
		if DirAccess.dir_exists_absolute(abs_path):
			var err := OS.move_to_trash(abs_path)
			if err != OK:
				err = _remove_dir_recursive(abs_path)
			if err != OK:
				return {"ok": false, "error": "remove_failed: %s" % res_path}
	_editor_interface().get_resource_filesystem().scan()
	return {"ok": true, "error": ""}


func scan_zip_addon_roots(zip_path: String) -> Array:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return []
	var roots := {}
	for entry in reader.get_files():
		var s := str(entry).replace("\\", "/")
		if s.ends_with("/"):
			continue
		var rel := _normalize_addon_relative(s)
		if rel.is_empty():
			continue
		var r := _addon_root_from_relative(rel)
		if not r.is_empty():
			roots[r] = true
	reader.close()
	var keys: Array = roots.keys()
	keys.sort()
	return keys


## Full flow: download zip for release, extract addons/*, return addon_dirs.
func install_release(
	github: GdlmGithubClient,
	owner: String,
	repo: String,
	release: Dictionary,
	addon_hint: String,
	do_backup: bool
) -> Dictionary:
	var tag := str(release.get("tag_name", release.get("name", "unknown")))
	var url := pick_zip_asset_url(release, addon_hint)
	if url.is_empty():
		# Many authors ship only tag/source without a .zip attachment — use GitHub source archive.
		url = str(release.get("zipball_url", "")).strip_edges()
	if url.is_empty():
		return {"ok": false, "addon_dirs": [], "error": "no_download_url"}
	ensure_cache_dir()
	var zip_path := _cache_zip_path(owner, repo, tag)
	var dl: Dictionary = await github.download_asset(url, zip_path)
	if not dl.get("ok", false):
		return {"ok": false, "addon_dirs": [], "error": str(dl.get("error", "download_failed"))}
	if do_backup:
		var roots_to_touch: Array = scan_zip_addon_roots(zip_path)
		var existing: Array = []
		for r in roots_to_touch:
			var abs_path := ProjectSettings.globalize_path("res://%s" % str(r).trim_prefix("/"))
			if DirAccess.dir_exists_absolute(abs_path):
				existing.append(r)
		if not existing.is_empty():
			backup_addon_dirs(existing)
	var ex := install_from_zip(zip_path)
	return ex


func res_paths_exist(addon_dirs: Array) -> bool:
	for ad in addon_dirs:
		var rel := str(ad).strip_edges().trim_prefix("/")
		var abs_path := ProjectSettings.globalize_path("res://%s" % rel)
		if DirAccess.dir_exists_absolute(abs_path):
			return true
	return false
