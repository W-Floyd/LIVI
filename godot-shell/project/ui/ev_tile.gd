class_name EvTile
extends Button
## A tap target of the "Electric vehicle" page: an icon, what it opens, and what is known
## about it. At least the touch-target height, with the theme's pressed state. It only says
## it was tapped; the page decides what that does.

signal activated(id: String)

var id := ""
## A pack image key for the box, with its states; empty for the theme's own look.
var skin_key := ""

var _icon: TextureRect
var _title: Label
var _items: HBoxContainer
var _row: HBoxContainer
var _text: VBoxContainer
var _content := {}
var _held := false


func _init() -> void:
	focus_mode = Control.FOCUS_NONE
	_icon = TextureRect.new()
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_title = UI.label("", "strong", "body")
	_title.name = "Title"
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_items = UI.hbox([], 0.8)
	_items.alignment = BoxContainer.ALIGNMENT_CENTER
	_text = UI.vbox([_title, _items], 0)
	_text.alignment = BoxContainer.ALIGNMENT_CENTER
	_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_row = UI.hbox([_icon, _text], 0.8)
	_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_row)
	pressed.connect(func(): activated.emit(id))
	button_down.connect(func(): _hold(true))
	button_up.connect(func(): _hold(false))


func _ready() -> void:
	ThemeManager.changed.connect(_style)
	resized.connect(_apply_material)
	_style()


## `{ title, icon: { name | texture, size }, items: [{ icon | texture, size, text }], look }`;
## `look.title` and `look.item` may set `size` (px) and `color` for a pack's own type.
func set_content(c: Dictionary) -> void:
	_content = c
	_style()


func _hold(down: bool) -> void:
	_held = down
	_colors()


func _style() -> void:
	var look: Dictionary = _content.get("look", {})
	_title.text = str(_content.get("title", ""))
	_title.visible = _title.text != ""
	_items.visible = not _content.get("items", []).is_empty()
	_text.visible = _title.visible or _items.visible
	_title.set_meta("look", ["strong", "caption", "text"])
	UI.style_label(_title)
	_title.autowrap_mode = TextServer.AUTOWRAP_OFF
	_title.max_lines_visible = -1
	_title.custom_minimum_size.y = 0
	if look.get("title", {}).has("size"):
		_title.add_theme_font_size_override("font_size", int(look.title.size))
	var ic: Dictionary = _content.get("icon", {})
	var icon_px: Vector2 = ic.get("size", Vector2.ONE * ThemeManager.px.icon * 1.7)
	_icon.texture = ic.texture if ic.has("texture") else (Icons.texture(ic.name, icon_px.y) if ic.has("name") else null)
	_icon.custom_minimum_size = icon_px
	_icon.visible = _icon.texture != null
	for n in _items.get_children():
		_items.remove_child(n)
		n.free()
	for it in _content.get("items", []):
		if it.has("icon") or it.has("texture"):
			var t := TextureRect.new()
			t.mouse_filter = Control.MOUSE_FILTER_IGNORE
			t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			var sz: Vector2 = it.get("size", Vector2.ONE * ThemeManager.px.icon)
			t.texture = it.texture if it.has("texture") else Icons.texture(it.icon, sz.y)
			t.custom_minimum_size = sz
			t.set_meta("tint", it.get("tint", true))
			_items.add_child(t)
		if it.has("text"):
			var l := UI.label(str(it.text), "body", "caption", "dim")
			if look.get("item", {}).has("size"):
				l.add_theme_font_size_override("font_size", int(look.item.size))
			l.set_meta("item", true)
			_items.add_child(l)
	_items.add_theme_constant_override("separation", roundi(ThemeManager.px.gap * 0.8))
	_row.add_theme_constant_override("separation", roundi(ThemeManager.px.gap * 0.8))
	var m := roundi(ThemeManager.px.gap * 1.2)
	_row.offset_left = m
	_row.offset_right = -m
	_boxes()
	_colors()
	_apply_material()
	# A pack's boxes are as tall as the stock UI's: the content sits inside, margin-free.
	var skinned := skin_key != ""
	var need: float = _row.get_combined_minimum_size().y + (0.0 if skinned else ThemeManager.px.gap * 1.4)
	custom_minimum_size.y = maxf(ThemeManager.px.touch * (1.0 if skinned else 1.3), need)


## Wraps the title to two lines where one would be trimmed, for a tile `width` wide, and
## returns the height the tile then needs.
func fit(width: float) -> float:
	var gap: float = ThemeManager.px.gap
	# A little under what is there: a title measured to fit must not wrap when laid out.
	var avail := (width - gap * 2.4 - (_icon.custom_minimum_size.x + gap * 0.8 if _icon.visible else 0.0)) * 0.92
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_title.max_lines_visible = 2
	var th := 0.0
	if _title.visible:
		th = _title.get_theme_font("font").get_multiline_string_size(
			_title.text, HORIZONTAL_ALIGNMENT_CENTER, avail, _title.get_theme_font_size("font_size"), 2).y
	_title.custom_minimum_size.y = th
	var body := th + (_items.get_combined_minimum_size().y if _items.visible else 0.0)
	var need: float = maxf(_icon.custom_minimum_size.y if _icon.visible else 0.0, body) + gap * 1.4
	custom_minimum_size.y = maxf(ThemeManager.px.touch * (1.0 if skin_key != "" else 1.3), need)
	return custom_minimum_size.y


## The box in each state: the pack's image when the tile has a skin, else a surface over the
## map, else the theme's button.
func _boxes() -> void:
	for s in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var box: StyleBox = null
		var pack := ThemeManager.pack
		if skin_key != "" and pack != null and ThemeManager.material == "solid" and s != "focus":
			box = pack.box(skin_key, ThemeManager.appearance, ThemeManager.BUTTON_STATES[s])
			if box == null:
				box = pack.box(skin_key, ThemeManager.appearance)
		elif ThemeManager.material != "solid" and not ThemeManager.is_scene():
			box = ThemeManager.card_box()
			box.content_margin_top = 0
			box.content_margin_bottom = 0
		if box:
			add_theme_stylebox_override(s, box)
		else:
			remove_theme_stylebox_override(s)


func _colors() -> void:
	var c := ThemeManager.c
	# The theme's pressed state is the accent fill, so the foreground follows it; a pack's
	# image states draw their own.
	var on := _held and skin_key == "" and ThemeManager.material == "solid"
	var fg: Color = c.on_accent if on else c.text
	var look: Dictionary = _content.get("look", {})
	var title_color: Color = look.get("title", {}).get("color", fg)
	_title.add_theme_color_override("font_color", c.on_accent if on else title_color)
	var dim: Color = c.on_accent if on else look.get("item", {}).get("color", c.dim)
	for n in _items.get_children():
		if n is Label:
			n.add_theme_color_override("font_color", dim)
		elif n is TextureRect and n.get_meta("tint", true):
			n.modulate = dim
	_icon.modulate = fg if _content.get("icon", {}).get("tint", true) else Color.WHITE


func _apply_material() -> void:
	material = ThemeManager.surface_material(size) if not _held else null
