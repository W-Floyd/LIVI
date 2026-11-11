class_name MiniPlayer
extends Card
## What's playing, with the three controls a driver needs, laid out by the room home's panel
## gives it (HomeCards.child_rect). Large (the media card leads home): `wide`, the cover the
## card's height beside title, artist, album, a position bar and larger controls; `tall` where
## that leaves the text too little width, the cover over them. Otherwise one row, the cover
## square at the text's height; when the text would get fewer than MIN_CHARS beside the
## controls, they go to a row of their own under it, prev going only when that row cannot hold
## three; where the panel has no height for that row, one row without prev. Nothing playing:
## `empty`, a placeholder and a line to open the media page. A tap on the card outside its
## controls opens the media page.

signal control(name: String)  # playPause | next | prev
signal opened

## Characters of the title's font the text keeps beside the controls in one row.
const MIN_CHARS := 8
## The position bar's height on a large card, of a touch target.
const SEEK_SHARE := 0.6

var title := "":
	set(v):
		title = v
		_texts()
var artist := "":
	set(v):
		artist = v
		_texts()
var album := "":
	set(v):
		album = v
		_texts()
var playing := false:
	set(v):
		playing = v
		if _play: _style()
## The cover; null shows the placeholder.
var art: Texture2D:
	set(v):
		art = v
		if _art: _art.texture = v
var initials := "":
	set(v):
		initials = v
		if _art: _art.initials = v
var badge := Color(0, 0, 0, 0):
	set(v):
		badge = v
		if _art: _art.fill = v
## For the tall card's position bar, shown for the phone's track only (`show_position`).
var now_playing: NowPlaying
var show_position := false:
	set(v):
		if v != show_position:
			show_position = v
			_arrange()
## empty | one | two | tall | wide (see above).
var layout := "one"
var two_rows: bool:
	get:
		return layout == "two"
## Home's panel clears this when a second row would leave the card out.
var allow_two_rows := true:
	set(v):
		if v != allow_two_rows:
			allow_two_rows = v
			_arrange()

var _art: ArtView
var _title: Label
var _subtitle: Label
var _album: Label
var _meta: VBoxContainer
var _seek: SeekBar
var _prev: Button
var _play: Button
var _next: Button
var _rows: VBoxContainer
var _top: HBoxContainer
## Beside the cover in `wide`: the text, the bar and the controls.
var _col: VBoxContainer
var _col_fill: Control
var _buttons: HBoxContainer


func _build() -> void:
	_art = ArtView.new()
	_art.name = "Art"
	_title = UI.label(title, "strong", "body")
	_title.name = "Title"
	_subtitle = UI.label("", "body", "caption", "dim")
	_subtitle.name = "Subtitle"
	_album = UI.label("", "body", "caption", "dim")
	_album.name = "Album"
	for l in [_title, _subtitle, _album]:
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		l.clip_text = true
	_meta = UI.vbox([_title, _subtitle, _album], 0)
	_meta.name = "Meta"
	_meta.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_meta.alignment = BoxContainer.ALIGNMENT_CENTER
	_seek = SeekBar.new()
	_seek.name = "Seek"
	_seek.visible = false
	_seek.height_share = SEEK_SHARE
	_seek.seeked.connect(_on_seek)
	_prev = _button("prev", "Previous")
	_play = _button("pause", "Pause")
	_next = _button("next", "Next")
	_prev.pressed.connect(func(): control.emit("prev"))
	_play.pressed.connect(func(): control.emit("playPause"))
	_next.pressed.connect(func(): control.emit("next"))
	_buttons = UI.hbox([_prev, _play, _next], 0)
	_buttons.name = "Buttons"
	_buttons.set_meta("gap", 0.0)
	_top = UI.hbox([_art, _meta, _buttons], 1.0)
	_top.name = "Top"
	_col = UI.vbox([], 1.0)
	_col.name = "Column"
	_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Spreads the column to the cover's height: text at its top, controls at its foot.
	_col_fill = Control.new()
	_col_fill.name = "Fill"
	_col_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_col_fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rows = UI.vbox([_top], 1.0)
	_rows.name = "Rows"
	_rows.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_rows)
	_texts()


func _ready() -> void:
	super()
	# Home's panel sizes its cards when it sorts, and leaves out a card that does not fit by the
	# height it has then: the layout follows the room the panel gives, hidden or not.
	var p := get_parent()
	if p is Container:
		p.sort_children.connect(_arrange)
		p.resized.connect(_arrange)
	resized.connect(_arrange)


func _process(_delta: float) -> void:
	if _seek.visible and now_playing and (now_playing.running() or _seek.dragging()):
		_seek.fraction = now_playing.fraction()


func _on_seek(f: float) -> void:
	if now_playing:
		now_playing.seek(f)


func _gui_input(event: InputEvent) -> void:
	# The buttons take their own taps; a release on the rest of the card opens the page.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		accept_event()
		opened.emit()


func has_content() -> bool:
	return title != ""


func _button(icon: String, name: String) -> Button:
	var b := Button.new()
	b.name = name
	b.tooltip_text = name
	b.focus_mode = Control.FOCUS_NONE
	b.expand_icon = false
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.set_meta("icon_name", icon)
	return b


## Artist and album a line each on a large card, else on one line. Nothing playing: a line to
## the media page.
func _texts() -> void:
	if _subtitle == null:
		return
	var large := layout == "tall" or layout == "wide"
	_title.text = title if title != "" else "Nothing playing"
	_subtitle.text = "Open Media" if title == "" else artist if large else " · ".join([artist, album].filter(func(s): return s != ""))
	_album.text = album
	_album.visible = large and album != "" and title != ""


func _style() -> void:
	_art.radius = ThemeManager.px.radius
	_play.set_meta("icon_name", "pause" if playing else "play")
	_play.tooltip_text = "Pause" if playing else "Play"
	_buttons.add_theme_constant_override("separation", roundi(ThemeManager.px.touch_gap))
	# Icons only: no text padding, so a control is a touch target wide wherever it is.
	for st in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		var box := ThemeManager.godot_theme.get_stylebox(st, "Button").duplicate() as StyleBox
		box.content_margin_left = 0
		box.content_margin_right = 0
		for b in [_prev, _next]:
			b.add_theme_stylebox_override(st, box)
	# The main control is the accent; the others are quiet.
	var accent := StyleBoxFlat.new()
	accent.bg_color = ThemeManager.c.accent
	accent.set_corner_radius_all(roundi(ThemeManager.px.radius))
	for s in ["normal", "hover", "pressed", "hover_pressed"]:
		_play.add_theme_stylebox_override(s, accent)
	for k in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color"]:
		_play.add_theme_color_override(k, ThemeManager.c.on_accent)
	_arrange()


## The cover's side in a row: the text's height, at least a touch target.
func art_side() -> float:
	return maxf(ThemeManager.px.touch, _meta.get_combined_minimum_size().y)


func _panel() -> HomeCards:
	var p := get_parent()
	return p if p is HomeCards else null


## The room inside the card's padding, of the rect home's panel gives it.
func inner_size() -> Vector2:
	var r := _panel().child_rect(self).size if _panel() else size
	return r - get_theme_stylebox("panel").get_minimum_size()


## The width alone (HomeCards.child_width), which does not depend on this card's height.
func inner_width() -> float:
	var w: float = _panel().child_width(self) if _panel() else size.x
	return w - get_theme_stylebox("panel").get_minimum_size().x


## The text's width beside the controls in one row, from the card's width alone (not from the
## laid-out text, which the choice itself changes).
func one_row_text_width() -> float:
	var gap := float(_top.get_theme_constant("separation"))
	return inner_width() - art_side() - gap * 2.0 - _buttons_width(3, ThemeManager.px.touch)


## MIN_CHARS of the title's font at its size in a row.
func min_text_width() -> float:
	var f: Font = ThemeManager.fonts.strong
	var fs := ThemeManager.font_size("body")
	return f.get_string_size("abcdefghijklmnopqrstuvwxyz", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x / 26.0 * MIN_CHARS


## The card's height in a row, or two where the text would be tight: what it needs at least,
## from the theme's fonts rather than its present layout.
func compact_height() -> float:
	var t: float = ThemeManager.px.touch
	var pad := get_theme_stylebox("panel").get_minimum_size().y
	var text: float = ThemeManager.fonts.strong.get_height(ThemeManager.font_size("body")) \
		+ ThemeManager.fonts.body.get_height(ThemeManager.font_size("caption")) + 6.0
	var row := maxf(t, text)
	if title != "" and one_row_text_width() < min_text_width() and allow_two_rows:
		row += float(_rows.get_theme_constant("separation")) + t
	return ceilf(row + pad)


## `n` controls of `side` (they have no padding).
func _buttons_width(n: int, side: float) -> float:
	return side * n + ThemeManager.px.touch_gap * (n - 1)


## The text (`title_lines` of title, the album line or not), bar and controls of a large layout,
## with `side` controls.
func _large_stack_height(title_lines: int, side: float, with_album: bool) -> float:
	var sep := float(_rows.get_theme_constant("separation"))
	# A label's lines with the theme's line spacing between them.
	var spacing := 3.0
	var h: float = (ThemeManager.fonts.strong.get_height(ThemeManager.font_size("title")) + spacing) * title_lines
	h += (ThemeManager.fonts.body.get_height(ThemeManager.font_size("caption")) + spacing) * (2.0 if with_album and album != "" else 1.0)
	h += side + sep
	if show_position:
		h += roundf(ThemeManager.px.touch * SEEK_SHARE) + sep
	return h


## The layout for the room the card has: [layout, the large cover's side, title lines, control
## side, album line]. A large layout only where its text, bar and controls fit the height: two
## lines of title and larger controls where they fit, else one line, else touch-size controls,
## else without the album line.
func _choose() -> Array:
	var t: float = ThemeManager.px.touch
	if title == "":
		return ["empty", 0.0, 1, t, false]
	var room := inner_size()
	var sep := float(_rows.get_theme_constant("separation"))
	for fit in [[2, t * 1.25, true], [1, t * 1.25, true], [1, t, true], [1, t, false]]:
		var stack := _large_stack_height(fit[0], fit[1], fit[2])
		# Beside the text: the card's height, leaving the text MIN_CHARS at the title's size and
		# room for the controls.
		var beside := minf(room.y, room.x - sep - maxf(min_text_width() * ThemeManager.px.title / ThemeManager.px.body, _buttons_width(3, fit[1])))
		if room.y >= stack and beside >= t * 2.0:
			return ["wide", floorf(beside), fit[0], fit[1], fit[2]]
		var over := minf(room.x, room.y - stack - sep)
		if over >= t * 2.0 and room.x >= _buttons_width(3, fit[1]):
			return ["tall", floorf(over), fit[0], fit[1], fit[2]]
	if one_row_text_width() < min_text_width() and allow_two_rows:
		return ["two", 0.0, 1, t, false]
	return ["one", 0.0, 1, t, false]


func _arrange() -> void:
	if _top == null or inner_width() <= 0.0:
		return
	var t: float = ThemeManager.px.touch
	var pick := _choose()
	if pick[0] != layout:
		layout = pick[0]
		_place()
		_texts()
	var large := layout == "tall" or layout == "wide"
	var room := inner_size()
	# The controls on a large card as `_choose` fitted them.
	var line: float = room.x - (pick[1] + float(_top.get_theme_constant("separation")) if layout == "wide" else 0.0)
	var big: float = pick[3]
	_album.visible = large and album != "" and pick[4]
	for b in [_prev, _play, _next]:
		b.custom_minimum_size = Vector2(big, big)
		b.icon = Icons.texture(b.get_meta("icon_name"), ThemeManager.px.icon * big / t)
	_buttons.visible = layout != "empty"
	_seek.visible = large and show_position
	if now_playing and _seek.visible:
		_seek.seekable = now_playing.can_seek
		_seek.fraction = now_playing.fraction()
	_prev.visible = line >= _buttons_width(3, big) if layout != "one" else one_row_text_width() >= min_text_width()
	# Under the text, from its edge (beside the cover); under a centred card, centred.
	_buttons.alignment = BoxContainer.ALIGNMENT_CENTER if layout in ["two", "tall"] else BoxContainer.ALIGNMENT_BEGIN
	for l in [_title, _subtitle, _album]:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER if layout == "tall" else HORIZONTAL_ALIGNMENT_LEFT
	# A large card's title in two lines at the title size before an ellipsis.
	if large:
		_title.add_theme_font_size_override("font_size", ThemeManager.font_size("title"))
		# One line: cut, not wrapped (a wrap would show only its first word).
		_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if pick[2] > 1 else TextServer.AUTOWRAP_OFF
		_title.max_lines_visible = pick[2]
		_title.clip_text = pick[2] == 1
	else:
		UI.style_label(_title)
		_title.autowrap_mode = TextServer.AUTOWRAP_OFF
		_title.max_lines_visible = -1
		_title.clip_text = true
	# The tall card's cover is drawn square in what its box gets (ArtView). Beside the text it is
	# its side square, from the room the panel gives (never from this card's own minimum), the
	# text column as high, text at the cover's top and controls at its foot.
	match layout:
		"wide":
			_art.custom_minimum_size = Vector2(pick[1], pick[1])
			_col.custom_minimum_size.y = pick[1]
		"tall":
			_art.custom_minimum_size = Vector2(t, t)
		_:
			_art.custom_minimum_size = Vector2.ONE * art_side()


## Moves the cover, text and controls into the layout's boxes.
func _place() -> void:
	for n in [_art, _meta, _seek, _col_fill, _buttons, _top, _col]:
		if n.get_parent():
			n.get_parent().remove_child(n)
	_art.size_flags_vertical = Control.SIZE_EXPAND_FILL if layout == "tall" else Control.SIZE_SHRINK_BEGIN if layout == "wide" else Control.SIZE_FILL
	_col.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	match layout:
		"wide":
			for n in [_meta, _seek, _col_fill, _buttons]:
				_col.add_child(n)
			_top.add_child(_art)
			_top.add_child(_col)
			_rows.add_child(_top)
		"tall":
			for n in [_art, _meta, _seek, _buttons]:
				_rows.add_child(n)
		"two":
			for n in [_art, _meta]:
				_top.add_child(n)
			_rows.add_child(_top)
			_rows.add_child(_buttons)
		_:
			for n in [_art, _meta, _buttons]:
				_top.add_child(n)
			_rows.add_child(_top)
	_top.size_flags_vertical = Control.SIZE_FILL
	# A row on a card taller than it (the stack's media card) sits in its middle.
	_rows.alignment = BoxContainer.ALIGNMENT_BEGIN if layout == "tall" else BoxContainer.ALIGNMENT_CENTER
