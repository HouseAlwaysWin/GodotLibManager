extends RefCounted
class_name GdlmImageLoader

const MAX_ICON_SIDE := 160


## Godot’s PNG loader logs ERROR to the editor if you feed it JPEG/WebP — sniff format first.
static func _try_one_loader(data: PackedByteArray, which: int) -> Image:
	var img := Image.new()
	var ok: Error
	match which:
		1:
			ok = img.load_png_from_buffer(data)
		2:
			ok = img.load_jpg_from_buffer(data)
		3:
			ok = img.load_webp_from_buffer(data)
		4:
			ok = img.load_bmp_from_buffer(data)
		5:
			ok = img.load_tga_from_buffer(data)
		6:
			ok = img.load_svg_from_buffer(data, 1.0)
		_:
			return null
	if ok == OK:
		return img
	return null


static func _skip_ws_and_utf8_bom(data: PackedByteArray) -> int:
	var i := 0
	if data.size() >= 3 and data[0] == 0xEF and data[1] == 0xBB and data[2] == 0xBF:
		i = 3
	while i < data.size():
		var b: int = data[i]
		if b == 9 or b == 10 or b == 13 or b == 32:
			i += 1
		else:
			break
	return i


## Detect CDN HTML error bodies without calling get_string_from_utf8 on binary (avoids Unicode ERROR spam).
static func _is_ascii_html_error_document(data: PackedByteArray) -> bool:
	var i := _skip_ws_and_utf8_bom(data)
	if i >= data.size() or data[i] != 0x3C:
		return false
	i += 1
	var tag := PackedByteArray()
	while i < data.size() and data[i] != 0x3E and tag.size() < 256:
		var b: int = data[i]
		if b > 0x7F:
			return false
		tag.append(b)
		i += 1
	var tag_s := tag.get_string_from_ascii().strip_edges().to_lower()
	if tag_s.is_empty():
		return false
	if tag_s.begins_with("?xml") or tag_s.begins_with("svg"):
		return false
	if (
		tag_s.begins_with("!doctype html")
		or tag_s == "html"
		or tag_s.begins_with("html ")
		or tag_s.begins_with("head")
		or tag_s.begins_with("title")
		or tag_s.begins_with("body")
	):
		return true
	return false


static func decode_image(data: PackedByteArray) -> Image:
	if data.is_empty():
		return null
	## 1) Known binary images first — never pass PNG/JPEG/WebP/BMP bytes through UTF-8 text paths.
	if data.size() >= 8 and data[0] == 0x89 and data[1] == 0x50 and data[2] == 0x4E and data[3] == 0x47:
		return _try_one_loader(data, 1)
	if data.size() >= 3 and data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF:
		return _try_one_loader(data, 2)
	if (
		data.size() >= 12
		and data[0] == 0x52
		and data[1] == 0x49
		and data[2] == 0x46
		and data[3] == 0x46
		and data[8] == 0x57
		and data[9] == 0x45
		and data[10] == 0x42
		and data[11] == 0x50
	):
		return _try_one_loader(data, 3)
	if data.size() >= 2 and data[0] == 0x42 and data[1] == 0x4D:
		return _try_one_loader(data, 4)
	## 2) Plain ASCII HTML error pages (no UTF-8 decode of binary).
	if _is_ascii_html_error_document(data):
		return null
	## 3) Unknown — try image loaders; do not call get_string_from_utf8 on raw bytes.
	for which in [2, 3, 4, 5, 6]:
		var got := _try_one_loader(data, which)
		if got != null:
			return got
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
