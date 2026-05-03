@tool
extends PanelContainer

const PLUGIN_CARD := preload("res://addons/godot_lib_manager/ui/plugin_card.tscn")
## Rows shown per Search pager step (after topic + release filters).
const SEARCH_UI_PAGE_SIZE := 20
const PSearchCatalogCache := preload("res://addons/godot_lib_manager/core/search_catalog_cache.gd")
## GitHub Search — avoid bare `topic:godot` (spam/off-topic repos tag it alongside Unity/Java/etc.).
const CATALOG_GITHUB_QUERIES := [
	"topic:godot-addon",
	"topic:godot-plugin",
	"topic:godot-engine",
	"topic:gdextension",
]
## 3 days — must be a literal (GDScript const cannot use int() or PackedStringArray(...) ctor).
const CATALOG_CACHE_MAX_AGE_SEC := 259200
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
## UI pager page (1-based): slices filtered rows from `_search_filtered_accumulator`.
var _search_ui_page: int = 1
## Current keyword-filtered slice of `_catalog_entries` (filled when user clicks Search).
var _search_filtered_accumulator: Array = []
## Query string used for the current paginated search session (Prev/Next); avoids mismatch if LineEdit is edited.
var _search_active_query: String = ""
## Offline catalog: populated at startup (disk) then optionally refreshed (network).
var _catalog_entries: Array = []
var _catalog_ready: bool = false
var _catalog_saved_unix: int = 0
var _catalog_refresh_running: bool = false
## Cancels stale `_run_paged_search` after overlapping navigations (reset path awaits catalog).
var _paged_search_serial: int = 0

@onready var _plugin_list: VBoxContainer = %PluginList
@onready var _detail_icon: TextureRect = %DetailIcon
@onready var _detail_title: Label = %DetailTitle
@onready var _detail_source: Label = %DetailSource
@onready var _open_repo_btn: Button = %OpenRepoButton
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
@onready var _search_pager_wrap: VBoxContainer = %SearchPagerWrap
@onready var _search_pager: HBoxContainer = %SearchPager
@onready var _search_first_btn: Button = %SearchFirstPage
@onready var _search_prev_btn: Button = %SearchPrevPage
@onready var _search_page_numbers: HBoxContainer = %SearchPageNumbers
@onready var _search_next_btn: Button = %SearchNextPage
@onready var _search_last_btn: Button = %SearchLastPage
@onready var _search_meta_label: Label = %SearchPagerMetaLabel
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
	_search_first_btn.pressed.connect(_on_search_first_page_pressed)
	_search_prev_btn.pressed.connect(_on_search_prev_page_pressed)
	_search_next_btn.pressed.connect(_on_search_next_page_pressed)
	_search_last_btn.pressed.connect(_on_search_last_page_pressed)
	_add_to_my_list_btn.pressed.connect(_on_add_to_my_list_pressed)
	_open_repo_btn.pressed.connect(_on_open_repo_page_pressed)
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
		## Do not await network/registry inside _ready — it can leave the main screen blank until it finishes.
		call_deferred("_deferred_dock_bootstrap")


func _deferred_dock_bootstrap() -> void:
	if not editor_plugin:
		return
	await _refresh_plugin_list()
	call_deferred("_start_catalog_build")


func _status(msg: String) -> void:
	_status_label.text = msg


func _update_rate_label() -> void:
	var rem: int = _github.rate_limit_remaining
	var lim: int = _github.rate_limit_limit
	var reset: int = _github.rate_limit_reset_unix
	var rem_s := "—" if rem < 0 else str(rem)
	if lim >= 0 and rem >= 0:
		rem_s = "%s / %s" % [str(rem), str(lim)]
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
	if is_instance_valid(_detail_icon):
		_detail_icon.texture = null
		_detail_icon.visible = false
	_detail_title.text = "Select a plugin"
	_detail_source.text = ""
	_detail_desc.text = ""
	_open_repo_btn.disabled = true
	_release_option.clear()
	_release_option.disabled = true
	_release_notes.text = ""
	_refresh_install_buttons()


## Drop obvious non-Godot junk that still slips through search (e.g. Java servers with topic godot).
func _github_catalog_repo_passes_relevance(repo: Dictionary) -> bool:
	var tv: Variant = repo.get("topics", [])
	var topics: Array = tv if tv is Array else []
	var lang := str(repo.get("language", "")).strip_edges()
	var strong := false
	var needles := ["godot-addon", "godot-plugin", "gdextension", "godot-engine", "godot-gdextension", "gdplugin"]
	for t in topics:
		var s := str(t).to_lower().strip_edges()
		for n in needles:
			if s == n or s.contains(n):
				strong = true
				break
		if strong:
			break
	if strong:
		return true
	if lang in ["Java", "Kotlin", "Scala", "Clojure"]:
		return false
	return true


func _github_items_to_plugin_entries(items: Array) -> Array:
	var out: Array = []
	for it in items:
		if not it is Dictionary:
			continue
		var d: Dictionary = it
		if not _github_catalog_repo_passes_relevance(d):
			continue
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
		var sort_u := int(PGithubClient.catalog_sort_unix_from_github_item(d))
		var act := ""
		if sort_u > 0:
			act = "Last push: %s" % Time.get_datetime_string_from_unix_time(sort_u, true)
		out.append(
			{
				"name": fn,
				"owner": str(parts[0]),
				"repo": str(parts[1]),
				"description": str(d.get("description", "")),
				"addon_dir": "",
				"repo_html_url": repo_url,
				"icon_url": icon_url,
				"_catalog_sort_unix": sort_u,
				"_activity_caption": act,
				"_from_search": true,
				"_from_github": true,
			}
		)
	return out


func _filled_ui_pages_count() -> int:
	var n := _search_filtered_accumulator.size()
	if n <= 0:
		return 1
	return maxi(1, int(ceil(float(n) / float(SEARCH_UI_PAGE_SIZE))))


func _sort_catalog_newest_first(items: Array) -> void:
	items.sort_custom(
		func(a, b):
			if not a is Dictionary:
				return false
			if not b is Dictionary:
				return true
			var ua := int((a as Dictionary).get("_catalog_sort_unix", 0))
			var ub := int((b as Dictionary).get("_catalog_sort_unix", 0))
			return ua > ub
	)


func _filter_catalog_entries_local(all_entries: Array, q: String) -> Array:
	var qn := q.strip_edges().to_lower()
	if qn.is_empty():
		var dup: Array = []
		for e in all_entries:
			if e is Dictionary:
				dup.append((e as Dictionary).duplicate(true))
		## Empty keyword = browse full catalog: newest → oldest by stored dates.
		_sort_catalog_newest_first(dup)
		return dup
	var tokens := qn.split(" ", false)
	var out: Array = []
	for e in all_entries:
		if not e is Dictionary:
			continue
		var d: Dictionary = e
		var hay := (
			"%s %s %s %s"
			% [
				str(d.get("name", "")),
				str(d.get("owner", "")),
				str(d.get("repo", "")),
				str(d.get("description", "")),
			]
		).to_lower()
		var ok := true
		for t in tokens:
			var tt := str(t).strip_edges()
			if tt.is_empty():
				continue
			if not hay.contains(tt):
				ok = false
				break
		if ok:
			out.append(d.duplicate(true))
	## Same rule as empty search: newest first by stored push time.
	_sort_catalog_newest_first(out)
	return out


func _ensure_catalog_ready() -> void:
	## First catalog build: GitHub search API pages only (no frame cap).
	var spins := 0
	while not _catalog_ready:
		spins += 1
		if spins % 120 == 1:
			_status("Waiting for search catalog (building GitHub topic index)…")
		await get_tree().process_frame


func _start_catalog_build() -> void:
	var snap: Dictionary = PSearchCatalogCache.load_snapshot()
	var age_sec := 999999999
	if snap.get("ok", false) and snap.entries.size() > 0:
		_catalog_entries = snap.entries
		_catalog_saved_unix = int(snap.get("saved_unix", 0))
		_catalog_ready = true
		age_sec = Time.get_unix_time_from_system() - _catalog_saved_unix
		_status(
			"Search catalog: %s entries (disk). Filtering is local — no GitHub search per keystroke."
			% str(_catalog_entries.size())
		)
	else:
		_status("Building search catalog (first run — one-time network fetch)…")
	if _catalog_entries.is_empty():
		await _fetch_catalog_from_network()
	elif age_sec > CATALOG_CACHE_MAX_AGE_SEC:
		## Delay so refresh does not overlap with immediate UI use (no API during pager clicks).
		call_deferred("_catalog_refresh_stale_delayed")


func _catalog_refresh_stale_delayed() -> void:
	await get_tree().create_timer(90.0).timeout
	if _catalog_refresh_running:
		return
	await _catalog_refresh_stale_async()


func _catalog_refresh_stale_async() -> void:
	if _catalog_refresh_running:
		return
	_catalog_refresh_running = true
	_status("Refreshing search catalog in background…")
	await _fetch_catalog_from_network()
	_catalog_refresh_running = false
	_status("Catalog refreshed: %s entries." % str(_catalog_entries.size()))


func _fetch_catalog_from_network() -> void:
	var seen: Dictionary = {}
	var merged: Array = []

	var gh_pp := 100
	for qry in CATALOG_GITHUB_QUERIES:
		var gh_total := 0
		var page := 1
		while page <= 100:
			_status("Catalog — GitHub «%s» page %s…" % [qry, str(page)])
			var gh: Dictionary = await _github.search_repositories(qry, page, gh_pp)
			_update_rate_label()
			if not gh.get("ok", false):
				break
			if page == 1:
				gh_total = int(gh.get("total", 0))
			var items: Array = gh.get("items", [])
			if items.is_empty():
				break
			for ent in _github_items_to_plugin_entries(items):
				if not ent is Dictionary:
					continue
				var ed: Dictionary = ent
				var k2 := PRegistryLoader.canonical_owner_repo(
					"%s/%s" % [str(ed.get("owner", "")), str(ed.get("repo", ""))]
				)
				if k2.is_empty() or seen.has(k2):
					continue
				seen[k2] = true
				merged.append(ed.duplicate(true))
			var max_pages := maxi(1, int(ceil(float(mini(gh_total, 1000)) / float(gh_pp))))
			page += 1
			if page > max_pages:
				break

	_catalog_entries = merged
	_catalog_saved_unix = Time.get_unix_time_from_system()
	_catalog_ready = true
	PSearchCatalogCache.save_snapshot(_catalog_entries)
	_status(
		"Catalog ready: %s entries (saved). Release list loads when you select a repo."
		% str(_catalog_entries.size())
	)


func _update_search_pager() -> void:
	if not is_instance_valid(_search_pager):
		return
	var show := _showing_search_results
	if is_instance_valid(_search_pager_wrap):
		_search_pager_wrap.visible = show
	else:
		_search_pager.visible = show
	if not show:
		return
	var filled := _filled_ui_pages_count()
	var max_p := filled
	var at_end := _search_ui_page >= filled
	if is_instance_valid(_search_first_btn):
		_search_first_btn.disabled = _search_ui_page <= 1
	if is_instance_valid(_search_prev_btn):
		_search_prev_btn.disabled = _search_ui_page <= 1
	if is_instance_valid(_search_next_btn):
		_search_next_btn.disabled = at_end
	if is_instance_valid(_search_last_btn):
		_search_last_btn.disabled = at_end
	_rebuild_search_page_number_buttons(max_p)
	if is_instance_valid(_search_meta_label):
		var cat_n := _catalog_entries.size()
		_search_meta_label.text = (
			"Catalog %s entries · matches %s · page %s/%s · filter/search: local only"
			% [str(cat_n), str(_search_filtered_accumulator.size()), str(_search_ui_page), str(max_p)]
		)


func _rebuild_search_page_number_buttons(max_p: int) -> void:
	if not is_instance_valid(_search_page_numbers):
		return
	while _search_page_numbers.get_child_count() > 0:
		var ch := _search_page_numbers.get_child(0)
		_search_page_numbers.remove_child(ch)
		ch.queue_free()
	if max_p <= 0:
		return
	var cur := clampi(_search_ui_page, 1, max_p)
	if max_p == 1:
		var lone := Button.new()
		lone.text = "1"
		lone.flat = true
		lone.focus_mode = Control.FOCUS_NONE
		lone.custom_minimum_size = Vector2(28, 26)
		lone.disabled = true
		_search_page_numbers.add_child(lone)
		return
	## Compact pager: 1 … window around current … last — avoids a wide strip of 10+ buttons that gets clipped.
	var delta := 2
	var include: Dictionary = {}
	include[1] = true
	include[max_p] = true
	var win_lo := maxi(2, cur - delta)
	var win_hi := mini(max_p - 1, cur + delta)
	for p in range(win_lo, win_hi + 1):
		include[p] = true
	var keys: Array = include.keys()
	keys.sort_custom(func(a, b): return int(a) < int(b))
	var prev_page := -1
	for pv in keys:
		var p: int = int(pv)
		if prev_page >= 0 and p - prev_page > 1:
			var ell := Label.new()
			ell.text = "…"
			ell.mouse_filter = Control.MOUSE_FILTER_IGNORE
			ell.add_theme_font_size_override("font_size", 13)
			ell.add_theme_color_override("font_color", Color(0.42, 0.46, 0.54, 1))
			_search_page_numbers.add_child(ell)
		var btn := Button.new()
		btn.text = str(p)
		btn.flat = true
		btn.focus_mode = Control.FOCUS_NONE
		btn.custom_minimum_size = Vector2(28, 26)
		var pg := p
		btn.disabled = pg == cur
		if not btn.disabled:
			btn.pressed.connect(_on_search_page_number_pressed.bind(pg))
		_search_page_numbers.add_child(btn)
		prev_page = p


func _on_search_page_number_pressed(page: int) -> void:
	if page == _search_ui_page:
		return
	var mx := _filled_ui_pages_count()
	if page < 1 or page > mx:
		return
	_search_ui_page = page
	await _run_paged_search(false)


func _on_search_first_page_pressed() -> void:
	if _search_ui_page <= 1:
		return
	_search_ui_page = 1
	await _run_paged_search(false)


func _on_search_last_page_pressed() -> void:
	var mx := _filled_ui_pages_count()
	if _search_ui_page >= mx:
		return
	_search_ui_page = mx
	await _run_paged_search(false)


func _on_search_prev_page_pressed() -> void:
	if _search_ui_page <= 1:
		return
	_search_ui_page -= 1
	await _run_paged_search(false)


func _on_search_next_page_pressed() -> void:
	var filled := _filled_ui_pages_count()
	if _search_ui_page >= filled:
		return
	_search_ui_page += 1
	await _run_paged_search(false)


func _run_paged_search(reset_page: bool) -> void:
	_paged_search_serial += 1
	var run_id := _paged_search_serial
	var q_input := _search_edit.text.strip_edges()
	var q := q_input
	if not reset_page:
		q = _search_active_query.strip_edges()
		if q.is_empty():
			q = q_input

	## Pager must never await network — only Search waits for the catalog build.
	if reset_page:
		await _ensure_catalog_ready()
		if run_id != _paged_search_serial:
			return
		if not _catalog_ready:
			return
	else:
		if not _catalog_ready:
			_status("Catalog still loading — pagination uses no API once ready.")
			return

	if reset_page:
		_search_ui_page = 1
		_clear_detail_panel()
		_search_filtered_accumulator = _filter_catalog_entries_local(_catalog_entries, q)
	else:
		_clear_detail_panel()

	var acc_n := _search_filtered_accumulator.size()
	var start_i := (_search_ui_page - 1) * SEARCH_UI_PAGE_SIZE
	if acc_n > 0 and start_i >= acc_n:
		_search_ui_page = maxi(1, _filled_ui_pages_count())
		start_i = (_search_ui_page - 1) * SEARCH_UI_PAGE_SIZE

	_plugins = []
	var end_i := mini(start_i + SEARCH_UI_PAGE_SIZE, acc_n)
	if start_i < acc_n:
		for i in range(start_i, end_i):
			var row: Variant = _search_filtered_accumulator[i]
			if row is Dictionary:
				_plugins.append((row as Dictionary).duplicate(true))

	if run_id != _paged_search_serial:
		return

	_showing_search_results = true
	var filtered_total := acc_n
	var catalog_total := _catalog_entries.size()
	_search_active_query = q.strip_edges()
	var age_h := int((Time.get_unix_time_from_system() - _catalog_saved_unix) / 3600.0)
	_search_banner.text = (
		"Offline catalog — %s match(es), showing %s on this page (%s per page). "
		+ "Catalog holds %s repos (GitHub topic search snapshot). "
		+ "Sorted by last push to default branch — see each row. "
		+ "Not sorted by latest release (would need one API call per repo). "
		+ "Keyword filter is local. Releases load when you select a repo. "
		+ "Cache age ~%s h. My List: saved registries."
	) % [
		str(filtered_total),
		str(_plugins.size()),
		str(SEARCH_UI_PAGE_SIZE),
		str(catalog_total),
		str(maxi(0, age_h)),
	]
	_search_banner.visible = true
	_update_search_pager()
	_rebuild_plugin_cards()
	var pages := _filled_ui_pages_count()
	if reset_page:
		_status(
			"Filtered %s / %s catalog · page %s/%s."
			% [str(filtered_total), str(catalog_total), str(_search_ui_page), str(pages)]
		)
	else:
		_status(
			"Page %s/%s · %s rows · %s matches (local)."
			% [str(_search_ui_page), str(pages), str(_plugins.size()), str(filtered_total)]
		)


func _on_github_search_pressed() -> void:
	await _run_paged_search(true)


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


func _ensure_icon_url_for_plugin(d: Dictionary) -> void:
	if str(d.get("icon_url", "")).strip_edges().is_empty():
		var owner := str(d.get("owner", "")).strip_edges()
		if owner.is_empty():
			return
		var rh := str(d.get("repo_html_url", "")).strip_edges().to_lower()
		if rh.contains("github.com") or rh.is_empty():
			d["icon_url"] = "https://github.com/%s.png" % owner.uri_encode()


func _rebuild_plugin_cards() -> void:
	for c in _plugin_list.get_children():
		c.queue_free()
	if _plugins.is_empty():
		var hint := Label.new()
		if _showing_search_results:
			hint.text = (
				"No matches in the offline catalog for this keyword.\n"
				+ "Try other words, clear the box to browse all, or open My List."
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
		_ensure_icon_url_for_plugin(d)
		var card: PanelContainer = PLUGIN_CARD.instantiate()
		card.set_plugin(d)
		var owner_s := str(d.get("owner", ""))
		var repo_s := str(d.get("repo", ""))
		var installed := PSettings.get_installed_for_source(_config, owner_s, repo_s)
		if not installed.is_empty():
			card.set_badge("Installed: %s" % str(installed.get("version", "?")))
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


func _on_plugin_card_pressed(plugin: Dictionary) -> void:
	_selected = plugin.duplicate(true)
	if str(_selected.get("repo_html_url", "")).strip_edges().is_empty():
		_selected["repo_html_url"] = _repo_page_url(_selected)
	_ensure_icon_url_for_plugin(_selected)
	if is_instance_valid(_detail_icon):
		_detail_icon.texture = null
		_detail_icon.visible = false
	var icon_u := str(_selected.get("icon_url", "")).strip_edges()
	if not icon_u.is_empty():
		var tex: Texture2D = await GdlmImageLoader.fetch_texture_async(icon_u, self)
		if is_instance_valid(_detail_icon) and is_instance_valid(self):
			_detail_icon.texture = tex
			_detail_icon.visible = tex != null
	_detail_title.text = str(plugin.get("name", ""))
	_detail_source.text = "%s/%s" % [str(plugin.get("owner", "")), str(plugin.get("repo", ""))]
	_detail_desc.text = str(plugin.get("description", ""))
	_open_repo_btn.disabled = _repo_page_url(_selected).is_empty()
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
	_search_ui_page = 1
	_search_active_query = ""
	_search_filtered_accumulator.clear()
	if _search_banner:
		_search_banner.visible = false
	if is_instance_valid(_search_pager_wrap):
		_search_pager_wrap.visible = false
	elif is_instance_valid(_search_pager):
		_search_pager.visible = false
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
	await _github.refresh_rate_limit_from_api()
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
		return
	_settings_window.hide()
	await _refresh_plugin_list()
