@tool
extends EditorPlugin

const DOCK_SCENE := preload("res://addons/godot_lib_manager/ui/lib_manager_dock.tscn")

var _main_screen: Control


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	return "Lib Manager"


func _get_plugin_icon() -> Texture2D:
	# Avoid missing icons (e.g. "AssetLibrary" not in all Godot versions).
	var theme := get_editor_interface().get_editor_theme()
	for icon_name in ["EditorPlugin", "Plugin", "Package", "Node"]:
		if theme.has_icon(icon_name, "EditorIcons"):
			return theme.get_icon(icon_name, "EditorIcons")
	return theme.get_icon("Node", "EditorIcons")


func _make_visible(visible: bool) -> void:
	if is_instance_valid(_main_screen):
		_main_screen.visible = visible


func _enter_tree() -> void:
	_main_screen = DOCK_SCENE.instantiate()
	_main_screen.setup(self)
	var host := get_editor_interface().get_editor_main_screen()
	host.add_child(_main_screen)
	# Main screen host is usually a Container: children need expand+fill or they stay at ~0 size (empty grey).
	if host is Container:
		# Control.LayoutMode.CONTAINER — expand fill required under BoxContainer-style hosts.
		_main_screen.layout_mode = 2
		_main_screen.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_main_screen.size_flags_vertical = Control.SIZE_EXPAND_FILL
	else:
		_main_screen.layout_mode = 1
		_main_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_make_visible(false)


func _exit_tree() -> void:
	if is_instance_valid(_main_screen):
		_main_screen.queue_free()
		_main_screen = null
