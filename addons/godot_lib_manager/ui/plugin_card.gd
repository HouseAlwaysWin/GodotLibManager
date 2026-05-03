@tool
extends PanelContainer

signal card_pressed(plugin: Dictionary)

var _plugin: Dictionary = {}

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


func _apply() -> void:
	if not is_instance_valid(_title):
		return
	_title.text = str(_plugin.get("name", ""))
	_desc.text = str(_plugin.get("description", ""))
	_source.text = "%s/%s" % [str(_plugin.get("owner", "")), str(_plugin.get("repo", ""))]
	_badge.text = str(_plugin.get("_badge", ""))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			card_pressed.emit(_plugin)
