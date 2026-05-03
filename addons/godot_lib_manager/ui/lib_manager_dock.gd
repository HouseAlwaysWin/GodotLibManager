@tool
extends PanelContainer

const PLUGIN_CARD := preload("res://addons/godot_lib_manager/ui/plugin_card.tscn")
const PSettings := preload("res://addons/godot_lib_manager/core/settings.gd")
const PGithubClient := preload("res://addons/godot_lib_manager/core/github_client.gd")
const PRegistryLoader := preload("res://addons/godot_lib_manager/core/registry_loader.gd")
const PInstaller := preload("res://addons/godot_lib_manager/core/plugin_installer.gd")

var editor_plugin: EditorPlugin

var _config: ConfigFile
var _github: RefCounted
var _registry: RefCounted
var _installer: RefCounted

var _plugins: Array = []
var _releases: Array = []
var _selected: Dictionary = {}
var _showing_search_results: bool = false

@onready var _plugin_list: VBoxContainer = %PluginList
@onready var _detail_title: Label = %DetailTitle
@onready var _detail_source: Label = %DetailSource
@onready var _open_repo_btn: Button = %OpenRepoButton
@onready var _open_al_btn: Button = %OpenAssetLibButton
@onready var _detail_desc: TextEdit = %DetailDesc
@onready var _release_option: OptionButton = %ReleaseOption
@onready var _release_notes: TextEdit = %ReleaseNotes
@onready var _install_btn: Button = %InstallButton
@onready var _update_btn: Button = %UpdateButton
@onready var _uninstall_btn: Button = %UninstallButton
@onready var _rate_label: Label = %RateLimitLabel
@onready var _status_label: Label = %StatusLabel
@onready var _refresh_btn: Button = %RefreshButton
@onready var _add_repo_btn: Button = %AddRepoButton
@onready var _settings_btn: Button = %SettingsButton
@onready var _remove_repo_btn: Button = %RemoveRepoButton
@onready var _search_edit: LineEdit = %SearchLineEdit
@onready var _search_btn: Button = %SearchButton
@onready var _search_banner: Label = %SearchBanner
@onready var _add_to_my_list_btn: Button = %AddToMyListButton
@onready var _error_dialog: AcceptDialog = %ErrorDialog
@onready var _success_dialog: AcceptDialog = %SuccessDialog
@onready var _install_confirm: ConfirmationDialog = %InstallConfirm
@onready var _uninstall_confirm: ConfirmationDialog = %UninstallConfirm
@onready var _add_manual_dialog: ConfirmationDialog = %AddManualDialog
@onready var _settings_window: Window = %SettingsWindow
@onready var _token_edit: LineEdit = %TokenEdit
@onready var _remove_repo_confirm: ConfirmationDialog = %RemoveRepoConfirm


func setup(p_plugin: EditorPlugin) -> void:
	editor_plugin = p_plugin
	_config = PSettings.load_config()
	_github = PGithubClient.new(self)
	_registry = PRegistryLoader.new()
	_installer = PInstaller.new(editor_plugin)


func _ready() -> void:
	_refresh_btn.pressed.connect(_on_refresh_pressed)
	_add_repo_btn.pressed.connect(_on_add_repo_pressed)
	_settings_btn.pressed.connect(_on_settings_pressed)
	_remove_repo_btn.pressed.connect(_on_remove_repo_pressed)
	_search_btn.pressed.connect(_on_github_search_pressed)
	_search_edit.text_submitted.connect(_on_github_search_submitted)
	_add_to_my_list_btn.pressed.connect(_on_add_to_my_list_pressed)
	_open_repo_btn.pressed.connect(_on_open_repo_page_pressed)
	_open_al_btn.pressed.connect(_on_open_asset_lib_page_pressed)
	_release_option.item_selected.connect(_on_release_selected)
	_install_btn.pressed.connect(_on_install_pressed)
	_update_btn.pressed.connect(_on_update_pressed)
	_uninstall_btn.pressed.connect(_on_uninstall_pressed)
	_install_confirm.confirmed.connect(_on_install_confirmed)
	_uninstall_confirm.confirmed.connect(_on_uninstall_confirmed)
	_add_manual_dialog.confirmed.connect(_on_add_manual_confirmed)
	_settings_window.close_requested.connect(_on_settings_window_close_requested)
	_remove_repo_confirm.confirmed.connect(_on_remove_repo_confirmed)
	%SaveCloseButton.pressed.connect(_on_save_settings_pressed)
	if editor_plugin:
		await _refresh_plugin_list()


func _status(msg: String) -> void:
	_status_label.text = msg


func _update_rate_label() -> void:
	var rem: int = _github.rate_limit_remaining
	var reset: int = _github.rate_limit_reset_unix
	var rem_s := "—" if rem < 0 else str(rem)
	var reset_s := ""
	if reset > 0:
		reset_s = " (resets ~%s)" % Time.get_datetime_string_from_unix_time(reset, false)
	_rate_label.text = "GitHub API rate limit remaining: %s%s" % [rem_s, reset_s]


func _show_error(msg: String) -> void:
	_error_dialog.dialog_text = msg
	_error_dialog.popup_centered()


func _show_success(msg: String) -> void:
	_success_dialog.dialog_text = msg
	_success_dialog.popup_centered()


func _format_install_error(code: String) -> String:
	match code:
		"zip_contains_no_addons_folder":
			return (
				"The downloaded archive has no addons/ folder at its root (after un-zipping GitHub’s wrapper folder).\n\n"
				+ "Structure must contain paths like addons/my_plugin/…. Either publish a zip that includes addons/, "
				+ "or put your addon under addons/ in the repository tag."
			)
		"no_download_url":
			return "This release has no downloadable zip attachment and no GitHub source zip URL."
		"no_zip_asset":
			return "No .zip release asset was found; tried fallback to GitHub source archive."
		_:
			return "Install failed:\n%s" % code


func _on_github_search_submitted(_text: String) -> void:
	_on_github_search_pressed()


func _clear_detail_panel() -> void:
	_selected.clear()
	_releases.clear()
	_detail_title.text = "Select a plugin"
	_detail_source.text = ""
	_detail_desc.text = ""
	_open_repo_btn.disabled = true
	_open_al_btn.visible = false
	_release_option.clear()
	_release_option.disabled = true
	_release_notes.text = ""
	_refresh_install_buttons()


func _github_items_to_plugin_entries(items: Array) -> Array:
	var out: Array = []
	for it in items:
		if not it is Dictionary:
			continue
		var d: Dictionary = it
		var fn := str(d.get("full_name", ""))
		if fn.is_empty():
			continue
		var parts := fn.split("/", false)
		if parts.size() < 2:
			continue
		var owner_obj: Variant = d.get("owner", {})
		var icon_url := ""
		if owner_obj is Dictionary:
			icon_url = str(owner_obj.get("avatar_url", "")).strip_edges()
		var repo_url := str(d.get("html_url", "")).strip_edges()
		if repo_url.is_empty():
			repo_url = "https://github.com/%s/%s" % [str(parts[0]), str(parts[1])]
		out.append(
			{
				"name": fn,
				"owner": str(parts[0]),
				"repo": str(parts[1]),
				"description": str(d.get("description", "")),
				"addon_dir": "",
				"repo_html_url": repo_url,
				"icon_url": icon_url,
				"_from_search": true,
				"_from_github": true,
			}
		)
	return out


func _merge_search_results(al: Dictionary, gh: Dictionary) -> Array:
	var seen: Dictionary = {}
	var out: Array = []
	if al.get("ok", false):
		for p in al.get("plugins", []):
			if not p is Dictionary:
				continue
			var d: Dictionary = p
			var k := PRegistryLoader.canonical_owner_repo(
				"%s/%s" % [str(d.get("owner", "")), str(d.get("repo", ""))]
			)
			if k.is_empty() or seen.has(k):
				continue
			seen[k] = true
			out.append(d)
	if gh.get("ok", false):
		for p2 in _github_items_to_plugin_entries(gh.get("items", [])):
			if not p2 is Dictionary:
				continue
			var d2: Dictionary = p2
			var k2 := PRegistryLoader.canonical_owner_repo(
				"%s/%s" % [str(d2.get("owner", "")), str(d2.get("repo", ""))]
			)
			if k2.is_empty() or seen.has(k2):
				continue
			seen[k2] = true
			out.append(d2)
	return out


func _filter_search_entries_with_releases(entries: Array) -> Array:
	var out: Array = []
	var idx := 0
	var total := entries.size()
	for e in entries:
		if not e is Dictionary:
			continue
		var d: Dictionary = e
		var owner := str(d.get("owner", "")).strip_edges()
		var repo := str(d.get("repo", "")).strip_edges()
		if owner.is_empty() or repo.is_empty():
			continue
		idx += 1
		_status("Checking GitHub releases (%s/%s)…" % [str(idx), str(total)])
		var chk: Dictionary = await _github.check_repo_has_any_release(owner, repo)
		_update_rate_label()
		if chk.get("uncertain", false):
			out.append(d)
		elif chk.get("has_releases", false):
			out.append(d)
	return out


func _on_github_search_pressed() -> void:
	var q := _search_edit.text.strip_edges()
	if q.is_empty():
		return
	_clear_detail_panel()
	_status("Searching Godot Asset Library and GitHub…")
	var al_res: Dictionary = await _github.search_asset_library_plugins(q, 15)
	var gh_res: Dictionary = await _github.search_repositories(q)
	_update_rate_label()
	if not al_res.get("ok", false) and not gh_res.get("ok", false):
		var e1 := str(al_res.get("error", ""))
		var e2 := str(gh_res.get("error", ""))
		_show_error("Search failed.\nAsset Library: %s\nGitHub: %s" % [e1, e2])
		_status("Search failed.")
		return
	_plugins = _merge_search_results(al_res, gh_res)
	var merged_n := _plugins.size()
	_status("Filtering: keeping repos with ≥1 GitHub release…")
	_plugins = await _filter_search_entries_with_releases(_plugins)
	_showing_search_results = true
	var al_total := 0
	var al_n := 0
	if al_res.get("ok", false):
		al_total = int(al_res.get("total_matches", 0))
		var ap: Variant = al_res.get("plugins", [])
		al_n = ap.size() if ap is Array else 0
	var gh_total: int = int(gh_res.get("total", 0)) if gh_res.get("ok", false) else 0
	_search_banner.text = (
		"Asset Library + GitHub — %s repo(s) with releases (from %s merged; no-release repos removed). "
		+ "Asset Library: %s in raw list (~%s matches). GitHub: ~%s matches. "
		+ "Press Refresh to return to your saved list."
	) % [str(_plugins.size()), str(merged_n), str(al_n), str(al_total), str(gh_total)]
	_search_banner.visible = true
	_rebuild_plugin_cards()
	_status(
		"Search: %s rows (Asset Library %s · GitHub ~%s)."
		% [str(_plugins.size()), str(al_n), str(gh_total)]
	)


func _append_manual_repo_canonical(can: String) -> void:
	if can.is_empty():
		return
	var manual := PSettings.get_manual_repos(_config)
	for i in manual.size():
		if PRegistryLoader.canonical_owner_repo(str(manual[i])) == can:
			_show_error("%s is already in your list." % can)
			return
	var arr: Array = Array(manual)
	arr.append(can)
	var ps := PackedStringArray()
	for x in arr:
		ps.append(str(x))
	PSettings.set_manual_repos(_config, ps)
	PSettings.save_config(_config)


func _is_selection_in_manual_list() -> bool:
	if _selected.is_empty():
		return false
	var key := PRegistryLoader.canonical_owner_repo(
		"%s/%s" % [str(_selected.get("owner", "")), str(_selected.get("repo", ""))]
	)
	if key.is_empty():
		return false
	for m in PSettings.get_manual_repos(_config):
		if PRegistryLoader.canonical_owner_repo(str(m)) == key:
			return true
	return false


func _on_add_to_my_list_pressed() -> void:
	if not _selected.get("_from_search", false):
		return
	var can := PRegistryLoader.canonical_owner_repo(
		"%s/%s" % [str(_selected.get("owner", "")), str(_selected.get("repo", ""))]
	)
	if can.is_empty():
		return
	_append_manual_repo_canonical(can)
	_show_success("%s added to your saved list." % can)
	await _refresh_plugin_list()


func _sort_releases_by_date(arr: Array) -> void:
	arr.sort_custom(
		func(a, b): return str(a.get("published_at", "")) > str(b.get("published_at", ""))
	)


func _rebuild_plugin_cards() -> void:
	for c in _plugin_list.get_children():
		c.queue_free()
	if _plugins.is_empty():
		var hint := Label.new()
		if _showing_search_results:
			hint.text = (
				"No repositories with at least one GitHub release matched.\n"
				+ "Try different keywords, or press Refresh."
			)
		else:
			hint.text = "No plugins yet.\n• Use Search — results appear in this list.\n• Add repo… — paste owner/repo or a github.com URL.\n• Token… — optional PAT for higher API limits."
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.add_theme_color_override("font_color", Color(0.62, 0.68, 0.78))
		_plugin_list.add_child(hint)
		return
	for p in _plugins:
		if not p is Dictionary:
			continue
		var d: Dictionary = p
		var card: PanelContainer = PLUGIN_CARD.instantiate()
		card.set_plugin(d)
		var owner_s := str(d.get("owner", ""))
		var repo_s := str(d.get("repo", ""))
		var installed := PSettings.get_installed_for_source(_config, owner_s, repo_s)
		if not installed.is_empty():
			card.set_badge("Installed: %s" % str(installed.get("version", "?")))
		elif d.get("_from_asset_library", false):
			card.set_badge("Asset Library")
		elif d.get("_from_search", false):
			card.set_badge("GitHub")
		else:
			card.set_badge("")
		card.card_pressed.connect(_on_plugin_card_pressed)
		_plugin_list.add_child(card)


func _repo_page_url(plugin: Dictionary) -> String:
	var u := str(plugin.get("repo_html_url", "")).strip_edges()
	if not u.is_empty():
		return u
	var o := str(plugin.get("owner", "")).strip_edges()
	var r := str(plugin.get("repo", "")).strip_edges()
	if o.is_empty() or r.is_empty():
		return ""
	return "https://github.com/%s/%s" % [o, r]


func _on_open_repo_page_pressed() -> void:
	var u := _repo_page_url(_selected)
	if u.is_empty():
		return
	OS.shell_open(u)


func _on_open_asset_lib_page_pressed() -> void:
	var u := str(_selected.get("asset_library_url", "")).strip_edges()
	if u.is_empty():
		return
	OS.shell_open(u)


func _on_plugin_card_pressed(plugin: Dictionary) -> void:
	_selected = plugin.duplicate(true)
	if str(_selected.get("repo_html_url", "")).strip_edges().is_empty():
		_selected["repo_html_url"] = _repo_page_url(_selected)
	_detail_title.text = str(plugin.get("name", ""))
	_detail_source.text = "%s/%s" % [str(plugin.get("owner", "")), str(plugin.get("repo", ""))]
	_detail_desc.text = str(plugin.get("description", ""))
	_open_repo_btn.disabled = _repo_page_url(_selected).is_empty()
	var al := str(_selected.get("asset_library_url", "")).strip_edges()
	_open_al_btn.visible = not al.is_empty()
	_release_option.clear()
	_release_option.disabled = true
	_release_notes.text = ""
	_releases.clear()
	_status("Fetching releases for %s/%s…" % [plugin.get("owner", ""), plugin.get("repo", "")])
	var res: Dictionary = await _github.fetch_releases(
		str(plugin.get("owner", "")), str(plugin.get("repo", ""))
	)
	_update_rate_label()
	if not res.get("ok", false):
		_show_error("Failed to load releases:\n%s" % str(res.get("error", "unknown")))
		_status("Failed to load releases.")
		_refresh_install_buttons()
		return
	var rels: Array = res.get("releases", [])
	_sort_releases_by_date(rels)
	_releases = rels
	for r in _releases:
		if not r is Dictionary:
			continue
		var rd: Dictionary = r
		_release_option.add_item(str(rd.get("tag_name", rd.get("name", "?"))))
	_release_option.disabled = _releases.is_empty()
	if _releases.size() > 0:
		_release_option.select(0)
		_on_release_selected(0)
	_status("Loaded %s release(s)." % str(_releases.size()))
	_refresh_install_buttons()


func _refresh_install_buttons() -> void:
	var ins := _installed_record()
	var rel := _get_selected_release()
	var has_rel := not rel.is_empty()
	var search_hit := _selected.get("_from_search", false)
	var already_saved := _is_selection_in_manual_list()
	_add_to_my_list_btn.visible = search_hit and not already_saved
	_install_btn.disabled = not has_rel or not ins.is_empty()
	_update_btn.disabled = not has_rel or ins.is_empty()
	_uninstall_btn.disabled = ins.is_empty()


func _get_selected_release() -> Dictionary:
	var i := _release_option.selected
	if i < 0 or i >= _releases.size():
		return {}
	var r: Variant = _releases[i]
	return r if r is Dictionary else {}


func _on_release_selected(idx: int) -> void:
	if idx < 0 or idx >= _releases.size():
		_release_notes.text = ""
		return
	var r: Variant = _releases[idx]
	if not r is Dictionary:
		_release_notes.text = ""
		return
	var rd: Dictionary = r
	_release_notes.text = str(rd.get("body", ""))
	_refresh_install_buttons()


func _installed_record() -> Dictionary:
	if _selected.is_empty():
		return {}
	return PSettings.get_installed_for_source(
		_config, str(_selected.get("owner", "")), str(_selected.get("repo", ""))
	)


func _on_refresh_pressed() -> void:
	await _refresh_plugin_list()


func _refresh_plugin_list() -> void:
	_showing_search_results = false
	if _search_banner:
		_search_banner.visible = false
	_config = PSettings.load_config()
	_github.set_token(PSettings.get_github_token(_config))
	_status("Loading plugin list…")
	_plugins = await _registry.load_all(
		_github,
		PSettings.get_registries(_config),
		PSettings.get_manual_repos(_config),
	)
	_plugins.sort_custom(
		func(a, b):
			return str(a.get("name", "")).to_lower() < str(b.get("name", "")).to_lower()
	)
	_update_rate_label()
	_rebuild_plugin_cards()
	_status("Loaded %s plugin(s)." % str(_plugins.size()))
	_refresh_install_buttons()


func _on_add_repo_pressed() -> void:
	var le: LineEdit = _add_manual_dialog.get_node_or_null("ManualLineEdit") as LineEdit
	if le:
		le.clear()
	_add_manual_dialog.popup_centered()


func _on_add_manual_confirmed() -> void:
	var le: LineEdit = _add_manual_dialog.get_node_or_null("ManualLineEdit") as LineEdit
	if le == null:
		return
	var line := le.text.strip_edges()
	var can := PRegistryLoader.canonical_owner_repo(line)
	if can.is_empty():
		_show_error(
			"Invalid repository. Use owner/repo or a full GitHub URL, e.g.\n"
			+ "• HouseAlwaysWin/GodotExternalDebugAttachPlugin\n"
			+ "• https://github.com/HouseAlwaysWin/GodotExternalDebugAttachPlugin"
		)
		return
	var manual := PSettings.get_manual_repos(_config)
	var found := false
	for i in manual.size():
		if PRegistryLoader.canonical_owner_repo(str(manual[i])) == can:
			found = true
			break
	if not found:
		var arr: Array = Array(manual)
		arr.append(can)
		var ps := PackedStringArray()
		for x in arr:
			ps.append(str(x))
		PSettings.set_manual_repos(_config, ps)
		PSettings.save_config(_config)
	await _refresh_plugin_list()


func _on_install_pressed() -> void:
	if _get_selected_release().is_empty():
		return
	_install_confirm.dialog_text = (
		"Extract addons/ from the release zip into this project. Existing files under those folders may be overwritten. "
		+ "A backup of existing addon folders will be created under user://gdlm_backup when possible."
	)
	_install_confirm.popup_centered()


func _on_update_pressed() -> void:
	if _get_selected_release().is_empty():
		return
	_install_confirm.dialog_text = (
		"Reinstall or upgrade from the selected release. Existing files under addons/ may be overwritten. "
		+ "A backup of affected addon folders will be created under user://gdlm_backup when possible."
	)
	_install_confirm.popup_centered()


func _on_install_confirmed() -> void:
	_install_confirm.dialog_text = (
		"Extract addons/ from the release zip into this project. Existing files under those folders may be overwritten. "
		+ "A backup of existing addon folders will be created under user://gdlm_backup when possible."
	)
	var rel := _get_selected_release()
	if rel.is_empty() or _selected.is_empty():
		return
	var owner_s := str(_selected.get("owner", ""))
	var repo_s := str(_selected.get("repo", ""))
	var hint := str(_selected.get("addon_dir", ""))
	_status("Downloading & installing…")
	var result: Dictionary = await _installer.install_release(
		_github, owner_s, repo_s, rel, hint, true
	)
	_update_rate_label()
	if not result.get("ok", false):
		_show_error(_format_install_error(str(result.get("error", "unknown"))))
		_status("Install failed.")
		return
	var dirs: Array = result.get("addon_dirs", [])
	var ver := str(rel.get("tag_name", rel.get("name", "")))
	PSettings.set_installed(_config, owner_s, repo_s, ver, dirs)
	PSettings.save_config(_config)
	_rebuild_plugin_cards()
	_refresh_install_buttons()
	editor_plugin.get_editor_interface().get_resource_filesystem().scan()
	_status("Installed %s." % ver)
	_show_success(
		"Addon files were extracted under res://addons/.\n\n"
		+ "Enable the plugin(s) under: Project → Project Settings… → Plugins.\n\n"
		+ "Installed roots: %s" % str(dirs)
	)


func _on_uninstall_pressed() -> void:
	if _installed_record().is_empty():
		return
	_uninstall_confirm.popup_centered()


func _on_uninstall_confirmed() -> void:
	var ins := _installed_record()
	if ins.is_empty():
		return
	var dirs: Array = ins.get("addon_dirs", [])
	_status("Removing addon folders…")
	var result: Dictionary = _installer.uninstall_addon_dirs(dirs)
	if not result.get("ok", false):
		_show_error("Uninstall failed:\n%s" % str(result.get("error", "unknown")))
		_status("Uninstall failed.")
		return
	PSettings.remove_installed(_config, str(_selected.get("owner", "")), str(_selected.get("repo", "")))
	PSettings.save_config(_config)
	_rebuild_plugin_cards()
	_refresh_install_buttons()
	_status("Uninstalled.")
	_show_success("Removed: %s" % str(dirs))


func _on_settings_pressed() -> void:
	_config = PSettings.load_config()
	_token_edit.text = PSettings.get_github_token(_config)
	_center_window(_settings_window)
	_settings_window.show()


func _selected_in_manual_repos() -> bool:
	if _selected.is_empty():
		return false
	var want := PRegistryLoader.canonical_owner_repo(
		"%s/%s" % [str(_selected.get("owner", "")), str(_selected.get("repo", ""))]
	)
	if want.is_empty():
		return false
	for m in PSettings.get_manual_repos(_config):
		if PRegistryLoader.canonical_owner_repo(str(m)) == want:
			return true
	return false


func _on_remove_repo_pressed() -> void:
	if _selected.is_empty():
		_show_error('Select a repository on the left first.')
		return
	if not _selected_in_manual_repos():
		_show_error(
			'Only repos added with "Add repo…" can be removed here. '
			+ "Plugins loaded from a registry JSON must be changed by editing godot_lib_manager.cfg."
		)
		return
	_remove_repo_confirm.dialog_text = "Remove %s/%s from your list?" % [
		str(_selected.get("owner", "")),
		str(_selected.get("repo", "")),
	]
	_remove_repo_confirm.popup_centered()


func _on_remove_repo_confirmed() -> void:
	if _selected.is_empty():
		return
	var owner_s := str(_selected.get("owner", ""))
	var repo_s := str(_selected.get("repo", ""))
	var key := PRegistryLoader.canonical_owner_repo("%s/%s" % [owner_s, repo_s])
	var manual := PSettings.get_manual_repos(_config)
	var out := PackedStringArray()
	for m in manual:
		if PRegistryLoader.canonical_owner_repo(str(m)) != key:
			out.append(str(m))
	PSettings.set_manual_repos(_config, out)
	PSettings.save_config(_config)
	_selected.clear()
	_detail_title.text = "Select a plugin"
	_detail_source.text = ""
	_detail_desc.text = ""
	_release_option.clear()
	_release_notes.text = ""
	_releases.clear()
	_refresh_install_buttons()
	await _refresh_plugin_list()


func _center_window(win: Window) -> void:
	var base := editor_plugin.get_editor_interface().get_base_control()
	var r := base.get_viewport().get_visible_rect()
	win.position = Vector2i(
		int(r.position.x + (r.size.x - win.size.x) * 0.5),
		int(r.position.y + (r.size.y - win.size.y) * 0.5)
	)


func _apply_settings_fields_to_config() -> void:
	PSettings.set_github_token(_config, _token_edit.text)


func _on_save_settings_pressed() -> void:
	_apply_settings_fields_to_config()
	if PSettings.save_config(_config) != OK:
		_show_error("Could not save settings to disk. Check editor Output for details.")
		return
	_settings_window.hide()
	await _refresh_plugin_list()


func _on_settings_window_close_requested() -> void:
	# Closing with ✕ previously discarded edits — persist same as Save.
	_apply_settings_fields_to_config()
	if PSettings.save_config(_config) != OK:
		_show_error("Could not save settings to disk. Check editor Output for details.")
	_settings_window.hide()
	await _refresh_plugin_list()
