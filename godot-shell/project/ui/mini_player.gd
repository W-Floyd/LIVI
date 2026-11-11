class_name MiniPlayer
extends Card
## What's playing, with the three controls a driver needs, laid out by the room home's panel
## gives it. A column of its own (HomeCards.is_tall): the cover as large as fits, title, artist
## and album, a thin position bar, larger controls. Otherwise one row, the cover square at the
## text's height; when the text would get fewer than MIN_CHARS beside the controls, they go to a
## row of their own under it, prev going only when that row cannot hold three; where the panel
## has no height for that row, one row without prev. One line per text, cut with an ellipsis. A
## tap elsewhere on the card opens the media page.

signal control(name: String)  # playPause | next | prev
signal opened

## Characters of the title's font the text keeps beside the controls in one row.
const MIN_CHARS := 8

var title := "":
	set(v):
		title = v
		if _title: _title.text = v
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
## one | two | tall: the controls beside the text, under it, or the card a column of its own.
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
	_rows = UI.vbox([_top], 1.0)
	_rows.name = "Rows"
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


## Artist and album a line each in a column of its own, else on one line.
func _texts() -> void:
	if _subtitle == null:
		return
	var tall := layout == "tall"
	_subtitle.text = artist if tall else " · ".join([artist, album].filter(func(s): return s != ""))
	_album.text = album
	_album.visible = tall and album != ""


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


## The width inside the card's padding, of the width home's panel gives it.
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


## `n` controls of `side` (they have no padding).
func _buttons_width(n: int, side: float) -> float:
	return side * n + ThemeManager.px.touch_gap * (n - 1)


func _arrange() -> void:
	if _top == null or inner_width() <= 0.0:
		return
	var t: float = ThemeManager.px.touch
	var tight := one_row_text_width() < min_text_width()
	var want := "one"
	if _panel() and _panel().is_tall(self):
		want = "tall"
	elif tight and allow_two_rows:
		want = "two"
	if want != layout:
		layout = want
		_place()
		_texts()
	var tall := layout == "tall"
	# Larger controls in a column of their own, where three fit.
	var big := t * 1.25 if tall and inner_width() >= _buttons_width(3, t * 1.25) else t
	for b in [_prev, _play, _next]:
		b.custom_minimum_size = Vector2(big, big)
		b.icon = Icons.texture(b.get_meta("icon_name"), ThemeManager.px.icon * big / t)
	_seek.visible = tall and show_position
	if now_playing and _seek.visible:
		_seek.seekable = now_playing.can_seek
		_seek.fraction = now_playing.fraction()
	_prev.visible = inner_width() >= _buttons_width(3, big) if layout != "one" else not tight
	_buttons.alignment = BoxContainer.ALIGNMENT_BEGIN if layout == "one" else BoxContainer.ALIGNMENT_CENTER
	for l in [_title, _subtitle, _album]:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER if tall else HORIZONTAL_ALIGNMENT_LEFT
	# In a column of its own the cover takes the height the rest leaves, drawn square in it
	# (ArtView): a minimum from the height would hold the panel at it.
	var side := t if tall else art_side()
	_art.custom_minimum_size = Vector2(side, side)


## Moves the cover, text and controls into the layout's boxes.
func _place() -> void:
	for n in [_art, _meta, _seek, _buttons, _top]:
		if n.get_parent():
			n.get_parent().remove_child(n)
	var tall := layout == "tall"
	_art.size_flags_vertical = Control.SIZE_EXPAND_FILL if tall else Control.SIZE_FILL
	match layout:
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
	# The tall card's boxes fill its height, so the cover can.
	_rows.size_flags_vertical = Control.SIZE_EXPAND_FILL
