class_name ThemePack
extends RefCounted
## What a vendor pack carries beyond a normal theme (PLAN.md, "Vendor themes"): images by
## `<package>/<name>` key, day or night, 9-patches, selector state maps, and screens as
## absolute rectangles. Read from the pack's folder on first use.

## A selector entry matches when every state it names equals this, with the entry's own
## states overriding: an unnamed state is a don't-care.
const BASE_STATE := {enabled = true, pressed = false, focused = false, hovered = false, checked = false, selected = false}

var dir: String

var _spec: Dictionary
var _index: Dictionary
var _loaded := false
var _images := {}     # file -> {tex: Texture2D, scale: float}
var _screens := {}


func _init(pack_dir: String, spec: Dictionary) -> void:
	dir = pack_dir
	_spec = spec


func has_screen(name: String) -> bool:
	return _spec.get("screens", {}).has(name)


func screen(name: String) -> Dictionary:
	if not _screens.has(name):
		_screens[name] = Yaml.parse(FileAccess.get_file_as_string(dir.path_join(_spec.screens[name])))
	var s = _screens[name]
	return s if s is Dictionary else {}


func has_image(key: String) -> bool:
	return _index_map().has(key)


## The bitmap entry drawn for `key` in `mode` (day | night; day when there is no night
## variant) under `state`, following selectors, aliases and the first animation frame.
func entry(key: String, mode: String, state := {}, depth := 0) -> Dictionary:
	var e = _index_map().get(key)
	if e == null or depth > 8:
		return {}
	var v = e.get(mode, e.get("day", e.get("night")))
	if not v is Dictionary:
		return {}
	if v.has("file"):
		return v
	var next = null
	if v.has("selector"):
		var st := BASE_STATE.merged(state, true)
		for item in v.selector:
			var ok := true
			for s in item.state:
				ok = ok and st.get(s, false) == item.state[s]
			if ok and item.get("image"):
				next = item.image
				break
	elif v.get("alias"):
		next = v.alias
	elif v.has("animation") and not v.animation.is_empty():
		next = v.animation[0].get("image")
	return entry(next, mode, state, depth + 1) if next else {}


func texture(key: String, mode: String, state := {}) -> Texture2D:
	var e := entry(key, mode, state)
	return _image(e).tex if not e.is_empty() else null


## The image as a StyleBoxTexture: its 9-patch margins when it has them, stretched whole
## otherwise. Null when the key has no bitmap.
func box(key: String, mode: String, state := {}) -> StyleBoxTexture:
	var e := entry(key, mode, state)
	if e.is_empty():
		return null
	var img := _image(e)
	var b := StyleBoxTexture.new()
	b.texture = img.tex
	if e.has("nine_patch"):
		var tm: Array = e.nine_patch.texture_margins
		var cm: Array = e.nine_patch.content_margins
		for i in 4:
			b.set_texture_margin(i, roundf(tm[i] * img.scale))
			b.set_content_margin(i, roundf(cm[i] * img.scale))
	return b


func _index_map() -> Dictionary:
	if not _loaded:
		_loaded = true
		var d = Yaml.parse(FileAccess.get_file_as_string(dir.path_join(_spec.get("images", "images/index.yaml"))))
		if d is Dictionary:
			_index = d
		else:
			push_error("%s: image index: %s" % [dir, d if d is String else "not a map"])
	return _index


## Loaded once; resized by the importer's density scale, as the stock UI draws it.
func _image(e: Dictionary) -> Dictionary:
	var file: String = e.file
	if not _images.has(file):
		var img := Image.load_from_file(dir.path_join(file))
		var s := float(e.get("scale", 1.0))
		if img == null:
			push_error("%s: cannot read %s" % [dir, file])
			img = Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
		elif s != 1.0:
			img.resize(roundi(img.get_width() * s), roundi(img.get_height() * s), Image.INTERPOLATE_LANCZOS)
		_images[file] = {tex = ImageTexture.create_from_image(img), scale = s}
	return _images[file]
