extends RefCounted
class_name GdlmSettings

const CONFIG_PATH := "user://godot_lib_manager.cfg"

const SECTION_GITHUB := "github"
const KEY_TOKEN := "token"

const SECTION_SOURCES := "sources"
const KEY_REGISTRIES := "registries"
const KEY_MANUAL := "manual_repos"

const SECTION_INSTALLED := "installed"


static func load_config() -> ConfigFile:
	var cf := ConfigFile.new()
	if cf.load(CONFIG_PATH) != OK:
		_apply_defaults(cf)
	return cf


static func save_config(cf: ConfigFile) -> Error:
	var err := cf.save(CONFIG_PATH)
	if err != OK:
		push_error("GodotLibManager: could not save config at %s (%s)" % [CONFIG_PATH, error_string(err)])
	return err


static func _apply_defaults(cf: ConfigFile) -> void:
	cf.set_value(SECTION_GITHUB, KEY_TOKEN, "")
	cf.set_value(SECTION_SOURCES, KEY_REGISTRIES, PackedStringArray())
	cf.set_value(SECTION_SOURCES, KEY_MANUAL, PackedStringArray())


static func get_github_token(cf: ConfigFile) -> String:
	return str(cf.get_value(SECTION_GITHUB, KEY_TOKEN, ""))


static func set_github_token(cf: ConfigFile, token: String) -> void:
	cf.set_value(SECTION_GITHUB, KEY_TOKEN, token)


static func get_registries(cf: ConfigFile) -> PackedStringArray:
	var v = cf.get_value(SECTION_SOURCES, KEY_REGISTRIES, PackedStringArray())
	if v is PackedStringArray:
		return v
	if v is Array:
		var out := PackedStringArray()
		for x in v:
			out.append(str(x))
		return out
	return PackedStringArray()


static func set_registries(cf: ConfigFile, urls: PackedStringArray) -> void:
	cf.set_value(SECTION_SOURCES, KEY_REGISTRIES, urls)


static func get_manual_repos(cf: ConfigFile) -> PackedStringArray:
	var v = cf.get_value(SECTION_SOURCES, KEY_MANUAL, PackedStringArray())
	if v is PackedStringArray:
		return v
	if v is Array:
		var out := PackedStringArray()
		for x in v:
			out.append(str(x))
		return out
	return PackedStringArray()


static func set_manual_repos(cf: ConfigFile, repos: PackedStringArray) -> void:
	cf.set_value(SECTION_SOURCES, KEY_MANUAL, repos)


static func source_key(owner: String, repo: String) -> String:
	return "%s/%s" % [owner.strip_edges(), repo.strip_edges()]


static func get_installed_for_source(cf: ConfigFile, owner: String, repo: String) -> Dictionary:
	var key := source_key(owner, repo)
	var d: Variant = cf.get_value(SECTION_INSTALLED, key, {})
	if d is Dictionary:
		return d.duplicate()
	return {}


static func set_installed(
	cf: ConfigFile,
	owner: String,
	repo: String,
	version: String,
	addon_dirs: Array
) -> void:
	var key := source_key(owner, repo)
	var rec := {
		"source": key,
		"version": version,
		"addon_dirs": addon_dirs.duplicate(),
	}
	cf.set_value(SECTION_INSTALLED, key, rec)


static func remove_installed(cf: ConfigFile, owner: String, repo: String) -> void:
	var key := source_key(owner, repo)
	if cf.has_section_key(SECTION_INSTALLED, key):
		cf.erase_section_key(SECTION_INSTALLED, key)


static func list_installed_sources(cf: ConfigFile) -> PackedStringArray:
	if not cf.has_section(SECTION_INSTALLED):
		return PackedStringArray()
	var keys := cf.get_section_keys(SECTION_INSTALLED)
	var out := PackedStringArray()
	for k in keys:
		out.append(str(k))
	return out
