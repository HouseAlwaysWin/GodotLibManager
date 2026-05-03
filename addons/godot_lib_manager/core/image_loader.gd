extends RefCounted
class_name GdlmImageLoader

const MAX_ICON_SIDE := 160


static func decode_image(data: PackedByteArray) -> Image:
	if data.is_empty():
		return null
	var img: Image
	img = Image.new()
	if img.load_png_from_buffer(data) == OK:
		return img
	img = Image.new()
	if img.load_jpg_from_buffer(data) == OK:
		return img
	img = Image.new()
	if img.load_webp_from_buffer(data) == OK:
		return img
	img = Image.new()
	if img.load_tga_from_buffer(data) == OK:
		return img
	img = Image.new()
	if img.load_bmp_from_buffer(data) == OK:
		return img
	img = Image.new()
	if img.load_svg_from_buffer(data, 1.0) == OK:
		return img
	return null


static func clamp_image(img: Image, max_side: int = MAX_ICON_SIDE) -> void:
	if img == null:
		return
	var w := img.get_width()
	var h := img.get_height()
	if w <= 0 or h <= 0:
		return
	if w <= max_side and h <= max_side:
		return
	var mx := maxf(float(w), float(h))
	var scale := float(max_side) / mx
	img.resize(maxi(1, int(floor(w * scale))), maxi(1, int(floor(h * scale))), Image.INTERPOLATE_LANCZOS)


## Loads a remote image into a texture (editor-safe HTTPRequest on `parent`).
static func fetch_texture_async(url: String, parent: Node) -> Texture2D:
	if url.strip_edges().is_empty() or not is_instance_valid(parent):
		return null
	var http := HTTPRequest.new()
	parent.add_child(http)
	var headers := PackedStringArray()
	headers.append("Accept: image/png,image/jpeg,image/webp,image/svg+xml,image/gif,image/*;q=0.8,*/*;q=0.5")
	headers.append("User-Agent: GodotLibManager/0.1 (Godot Editor)")
	var err: Error = http.request(url.strip_edges(), headers, HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return null
	var result: Array = await http.request_completed
	http.queue_free()
	var code: int = result[1]
	var body: PackedByteArray = result[3]
	if code < 200 or code >= 300:
		return null
	var img := decode_image(body)
	if img == null:
		return null
	clamp_image(img, MAX_ICON_SIDE)
	return ImageTexture.create_from_image(img)
