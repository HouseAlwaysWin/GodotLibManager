@tool
extends PanelContainer

signal card_pressed(plugin: Dictionary)

var _plugin: Dictionary = {}

@onready var _icon: TextureRect = %Icon
@onready var _title: Label = %Title
@onready var _desc: Label = %Description
@onready var _source: Label = %Source
@onready var _badge: Label = %Badge


func set_plugin(meta: Dictionary) -> void:
	_plugin = meta.duplicate(true)
	_apply()


func set_badge(text: String) -> void:
	_plugin["_badge"] = text
	if is_instance_valid(_badge):
		_badge.text = text


func get_plugin() -> Dictionary:
	return _plugin


func _ready() -> void:
	_apply()
	_start_icon_load.call_deferred()


func _apply() -> void:
	if not is_instance_valid(_title):
		return
	_title.text = str(_plugin.get("name", ""))
	_desc.text = str(_plugin.get("description", ""))
	_source.text = "%s/%s" % [str(_plugin.get("owner", "")), str(_plugin.get("repo", ""))]
	_badge.text = str(_plugin.get("_badge", ""))
	if is_instance_valid(_icon):
		_icon.texture = null
		var url := str(_plugin.get("icon_url", "")).strip_edges()
		_icon.visible = not url.is_empty()


func _start_icon_load() -> void:
	# Editor plugins run with is_editor_hint() == true; still need to load list icons.
	if not is_instance_valid(_icon):
		return
	var url := str(_plugin.get("icon_url", "")).strip_edges()
	if url.is_empty():
		_icon.visible = false
		return
	# Keep the slot visible so the list layout doesn’t jump while the request runs.
	_icon.visible = true
	_icon.modulate = Color(1, 1, 1, 0.35)
	var tex: Texture2D = await GdlmImageLoader.fetch_texture_async(url, self)
	if not is_instance_valid(self):
		return
	_icon.modulate = Color.WHITE
	if tex != null:
		_icon.texture = tex
		_icon.visible = true
	else:
		_icon.texture = null
		_icon.visible = false


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			card_pressed.emit(_plugin)
