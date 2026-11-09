class_name UI
## Small helpers every component uses to take its look from ThemeManager. Components build
## their nodes once and call these again from `_style()` whenever the theme changes.


## A label set in a font role (display, body, strong), a size token and a color token.
static func label(text := "", font := "body", size := "body", color := "text") -> Label:
	var l := Label.new()
	l.text = text
	l.set_meta("look", [font, size, color])
	style_label(l)
	return l


static func style_label(l: Label) -> void:
	var look: Array = l.get_meta("look")
	l.add_theme_font_override("font", ThemeManager.fonts[look[0]])
	l.add_theme_font_size_override("font_size", ThemeManager.font_size(look[1]))
	l.add_theme_color_override("font_color", ThemeManager.c[look[2]])


## Restyles every label made by `label()` under `root`.
static func style_labels(root: Node) -> void:
	for n in root.find_children("*", "Label", true, false):
		if n.has_meta("look"):
			style_label(n)


static func icon(name: String, size := "icon", color := "text") -> TextureRect:
	var t := TextureRect.new()
	t.set_meta("icon", [name, size, color])
	t.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	style_icon(t)
	return t


static func style_icon(t: TextureRect) -> void:
	var look: Array = t.get_meta("icon")
	var s: float = ThemeManager.px[look[1]]
	t.texture = Icons.texture(look[0], s)
	t.custom_minimum_size = Vector2(s, s)
	t.modulate = ThemeManager.c[look[2]]


static func style_icons(root: Node) -> void:
	for n in root.find_children("*", "TextureRect", true, false):
		if n.has_meta("icon"):
			style_icon(n)


static func hbox(children: Array, gap := 1.0) -> HBoxContainer:
	var b := HBoxContainer.new()
	# Layout only: input goes to the controls inside, or through to what's under.
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.set_meta("gap", gap)
	for ch in children:
		b.add_child(ch)
	return b


static func vbox(children: Array, gap := 1.0) -> VBoxContainer:
	var b := VBoxContainer.new()
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.set_meta("gap", gap)
	for ch in children:
		b.add_child(ch)
	return b


## Box separations follow the theme's gap, times each box's factor.
static func style_boxes(root: Node) -> void:
	for n in root.find_children("*", "BoxContainer", true, false):
		if n.has_meta("gap"):
			n.add_theme_constant_override("separation", roundi(ThemeManager.px.gap * n.get_meta("gap")))


static func spacer() -> Control:
	var s := Control.new()
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return s


## Restyles everything the helpers made under `root`.
static func restyle(root: Node) -> void:
	style_labels(root)
	style_icons(root)
	style_boxes(root)
