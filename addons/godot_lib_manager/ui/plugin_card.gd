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
	if Engine.is_editor_hint():
		return
	if not is_instance_valid(_icon):
		return
	var url := str(_plugin.get("icon_url", "")).strip_edges()
	if url.is_empty():
		_icon.visible = false
		return
	var tex: Texture2D = await _fetch_texture(url)
	if not is_instance_valid(self):
		return
	if tex != null:
		_icon.texture = tex
		_icon.visible = true
	else:
		_icon.texture = null
		_icon.visible = false


func _fetch_texture(url: String) -> Texture2D:
	var http := HTTPRequest.new()
	add_child(http)
	var err: Error = http.request(url, PackedStringArray(), HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return null
	var result: Array = await http.request_completed
	http.queue_free()
	var code: int = result[1]
	var body: PackedByteArray = result[3]
	if code < 200 or code >= 300:
		return null
	var img := _image_from_bytes(body)
	if img == null:
		return null
	return ImageTexture.create_from_image(img)


func _image_from_bytes(data: PackedByteArray) -> Image:
	if data.is_empty():
		return null
	var img := Image.new()
	var e: Error = img.load_png_from_buffer(data)
	if e == OK:
		return img
	e = img.load_jpg_from_buffer(data)
	if e == OK:
		return img
	e = img.load_webp_from_buffer(data)
	if e == OK:
		return img
	e = img.load_tga_from_buffer(data)
	if e == OK:
		return img
	return null


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			card_pressed.emit(_plugin)
