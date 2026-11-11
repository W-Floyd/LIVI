class_name MediaPage
extends Control
## What plays, large: the cover, the track, a seekable position, the transport and the volume,
## over a blurred, dimmed cover. With a DAB+ stick, tabs for the phone, DAB+ and FM as stock
## LIVI's media page has them: a band's tuned station, its text and its stations to pick.

var now_playing: NowPlaying
## The status bar's height, which the page leaves clear.
var top_inset := 0.0
## phone | dab | fm: what the page shows, the source on air unless the driver picked a tab.
var view := "phone"

## Volume steps are sent at most this often while dragging.
const VOLUME_MS := 100
## A station button's width, in touch targets.
const STATION_W := 4.2

var _art: ArtView
var _info: VBoxContainer
var _tabs: HBoxContainer
var _tab := {}
var _source: Label
var _title: Label
var _artist: Label
var _album: Label
var _seek_box: VBoxContainer
var _seek: SeekBar
var _elapsed: Label
var _remaining: Label
var _stations: DragScroll
## Pushes the phone's position and controls down; a band's stations take the room instead.
var _fill: Control
var _grid: GridContainer
var _stations_key := ""
var _prev: Button
var _play: Button
var _next: Button
var _favorite: Button
var _mute: Button
var _volume: HSlider
var _percent: Label
var _volume_sent_ms := 0
var _sliding := false
var _unmuted := 0.0
var _on_air := ""


func _init() -> void:
	name = "Media"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_art = ArtView.new()
	_art.name = "Art"
	add_child(_art)
	var group := ButtonGroup.new()
	_tabs = UI.hbox([], 0.6)
	_tabs.name = "Tabs"
	for t in [["phone", "Phone"], ["dab", "DAB+"], ["fm", "FM"]]:
		var b := Button.new()
		b.name = t[0]
		b.text = t[1]
		b.toggle_mode = true
		b.button_group = group
		b.focus_mode = Control.FOCUS_NONE
		var v: String = t[0]
		b.pressed.connect(func(): pick_view(v))
		_tabs.add_child(b)
		_tab[v] = b
	_source = UI.label("", "strong", "caption", "accent")
	_source.name = "Source"
	_title = UI.label("", "display", "title")
	_title.name = "Title"
	_artist = UI.label("", "strong", "body")
	_artist.name = "Artist"
	_album = UI.label("", "body", "body", "dim")
	_album.name = "Album"
	for l in [_source, _title, _artist, _album]:
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		l.clip_text = true
	_seek = SeekBar.new()
	_seek.name = "Seek"
	_seek.seeked.connect(_on_seek)
	_seek.dragged.connect(func(_f): _tick())
	_elapsed = UI.label("0:00", "body", "caption", "dim")
	_elapsed.name = "Elapsed"
	_remaining = UI.label("", "body", "caption", "dim")
	_remaining.name = "Remaining"
	_seek_box = UI.vbox([_seek, UI.hbox([_elapsed, UI.spacer(), _remaining], 0)], 0)
	_seek_box.name = "Position"
	_stations = DragScroll.new()
	_stations.name = "Stations"
	_stations.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_grid = GridContainer.new()
	_grid.name = "Grid"
	_stations.list.add_child(_grid)
	_prev = _button("Prev", "prev")
	_play = _button("Play", "play")
	_next = _button("Next", "next")
	_favorite = _button("Favorite", "star_outline")
	_prev.pressed.connect(_control.bind("prev"))
	_play.pressed.connect(_control.bind("playPause"))
	_next.pressed.connect(_control.bind("next"))
	_favorite.pressed.connect(_toggle_favorite)
	var transport := UI.hbox([_prev, _play, _next, _favorite], 0)
	transport.name = "Transport"
	transport.alignment = BoxContainer.ALIGNMENT_CENTER
	_mute = _button("Mute", "vol")
	_mute.pressed.connect(_toggle_mute)
	_volume = HSlider.new()
	_volume.name = "Slider"
	_volume.min_value = 0.0
	_volume.max_value = 1.0
	_volume.step = 0.01
	_volume.focus_mode = Control.FOCUS_NONE
	_volume.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_volume.size_flags_stretch_ratio = 0.6
	_volume.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_volume.drag_started.connect(func(): _sliding = true)
	_volume.value_changed.connect(_on_volume)
	_volume.drag_ended.connect(func(_c): _sliding = false; _send_volume(_volume.value))
	_percent = UI.label("", "body", "body", "dim")
	_percent.name = "Percent"
	_percent.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var volume := UI.hbox([_mute, _volume, _percent], 0.6)
	volume.name = "Volume"
	volume.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	volume.alignment = BoxContainer.ALIGNMENT_END
	_source.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_source.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var head := UI.hbox([_source, _tabs], 1.0)
	head.name = "Head"
	var top := UI.vbox([head, _title, _artist, _album], 0.3)
	top.name = "Meta"
	var fill := Control.new()
	_fill = fill
	fill.name = "Fill"
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var controls := UI.hbox([transport, volume], 3.0)
	controls.name = "Controls"
	_info = UI.vbox([top, fill, _stations, _seek_box, controls], 1.2)
	_info.name = "Info"
	add_child(_info)


func _ready() -> void:
	ThemeManager.changed.connect(_style)
	Core.changed.connect(_on_core_changed)
	resized.connect(_layout)
	if now_playing:
		now_playing.changed.connect(_update)
		now_playing.art_changed.connect(_update_art)
		view = now_playing.on_air() if now_playing.receiver else "phone"
		_on_air = now_playing.on_air()
	_read_volume()
	_style()


func _button(button_name: String, icon_name: String) -> Button:
	var b := Button.new()
	b.name = button_name
	b.tooltip_text = button_name
	b.focus_mode = Control.FOCUS_NONE
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
	b.set_meta("icon_name", icon_name)
	return b


func _style() -> void:
	theme = ThemeManager.godot_theme
	UI.restyle(self)
	var t: float = ThemeManager.px.touch
	var g: float = ThemeManager.px.gap
	_title.add_theme_font_size_override("font_size", roundi(ThemeManager.px.title * 1.3))
	for b in _tab.values():
		(b as Button).custom_minimum_size = Vector2(t * 1.8, t)
	(_play.get_parent() as BoxContainer).add_theme_constant_override("separation", roundi(ThemeManager.px.touch_gap * 1.5))
	_volume.custom_minimum_size.x = t * 3.0
	for b in [_prev, _next, _favorite, _mute]:
		_style_quiet(b, t * 1.25)
	_style_quiet(_mute, t)
	_play.custom_minimum_size = Vector2(t * 1.3, t * 1.3)
	var accent := StyleBoxFlat.new()
	accent.bg_color = ThemeManager.c.accent
	accent.set_corner_radius_all(roundi(t * 0.65))
	accent.anti_aliasing = true
	for s in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		_play.add_theme_stylebox_override(s, accent)
	for k in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color"]:
		_play.add_theme_color_override(k, ThemeManager.c.on_accent)
	_style_slider()
	_percent.custom_minimum_size.x = ThemeManager.px.body * 3.2
	_grid.add_theme_constant_override("h_separation", roundi(g))
	_grid.add_theme_constant_override("v_separation", roundi(g))
	_stations_key = ""
	_update()
	_update_art()
	_layout()


## Round, no fill until pressed: the play button is the one in the accent.
func _style_quiet(b: Button, side: float) -> void:
	b.custom_minimum_size = Vector2(side, side)
	var clear := StyleBoxFlat.new()
	clear.bg_color = Color(0, 0, 0, 0)
	var down := StyleBoxFlat.new()
	down.bg_color = ThemeManager.c.surface2
	for box in [clear, down]:
		box.set_corner_radius_all(roundi(side / 2.0))
		box.anti_aliasing = true
	for s in ["normal", "hover", "focus", "disabled"]:
		b.add_theme_stylebox_override(s, clear)
	for s in ["pressed", "hover_pressed"]:
		b.add_theme_stylebox_override(s, down)
	for k in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
		b.add_theme_color_override(k, ThemeManager.c.text)
	b.add_theme_color_override("icon_disabled_color", ThemeManager.c.dim)


func _style_slider() -> void:
	var h := roundi(ThemeManager.px.gap * 0.6)
	var track := StyleBoxFlat.new()
	track.bg_color = ThemeManager.c.surface2
	var fill := StyleBoxFlat.new()
	fill.bg_color = ThemeManager.c.accent
	for b in [track, fill]:
		b.set_corner_radius_all(h)
		b.content_margin_top = h / 2.0
		b.content_margin_bottom = h / 2.0
		b.anti_aliasing = true
	_volume.add_theme_stylebox_override("slider", track)
	_volume.add_theme_stylebox_override("grabber_area", fill)
	_volume.add_theme_stylebox_override("grabber_area_highlight", fill)
	var px := roundi(ThemeManager.px.touch * 0.45)
	var img := Image.new()
	img.load_svg_from_string('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><circle cx="12" cy="12" r="11" fill="#%s"/></svg>' % ThemeManager.c.accent.to_html(false), px / 24.0)
	var dot := ImageTexture.create_from_image(img)
	_volume.add_theme_icon_override("grabber", dot)
	_volume.add_theme_icon_override("grabber_highlight", dot)
	_volume.custom_minimum_size.y = ThemeManager.px.touch


## The right margin's, beside a docked rail (`Shell.rail_width`), as the apps page.
func _left() -> float:
	var rail = get_parent().get("rail_width") if get_parent() else null
	return ThemeManager.px.gap * 4.0 + (0.0 if rail != null and rail > 0.0 else ThemeManager.px.touch)


func _layout() -> void:
	var g: float = ThemeManager.px.gap
	var x := _left()
	var right := size.x - g * 4.0
	var top := top_inset + g * 3.0
	var h := maxf(0.0, size.y - top - g * 3.0)
	var side := minf(h, (right - x) * 0.42)
	_art.position = Vector2(x, top + (h - side) / 2.0)
	_art.size = Vector2(side, side)
	var ix := x + side + g * 5.0
	_info.position = Vector2(ix, top)
	_info.size = Vector2(maxf(0.0, right - ix), h)
	var tile_w: float = ThemeManager.px.touch * STATION_W
	var sep: float = g
	_grid.columns = maxi(1, int((_info.size.x + sep) / (tile_w + sep)))
	queue_redraw()


## The cover, blurred (a tiny image drawn stretched) and dimmed into the theme's ground.
func _draw() -> void:
	var r := Rect2(0, top_inset, size.x, size.y - top_inset)
	draw_rect(r, ThemeManager.c.bg)
	var b: Texture2D = now_playing.backdrop if now_playing and view == "phone" else null
	if b == null:
		return
	# The middle of the cover at the page's aspect.
	var ts := b.get_size()
	var k := maxf(r.size.x / ts.x, r.size.y / ts.y)
	draw_texture_rect_region(b, r, Rect2((ts - r.size / k) / 2.0, r.size / k), Color(1, 1, 1, 0.9))
	var dim: Color = ThemeManager.c.bg
	dim.a = 0.72 if ThemeManager.appearance == "night" else 0.78
	draw_rect(r, dim)


func _process(_delta: float) -> void:
	if now_playing and view == "phone" and (now_playing.running() or _seek.dragging()):
		_tick()


func _on_seek(f: float) -> void:
	if now_playing:
		now_playing.seek(f)
		_tick()


## The position, each frame while it runs.
func _tick() -> void:
	if now_playing == null:
		return
	var d := now_playing.duration_ms
	_seek.fraction = now_playing.fraction()
	var e := _seek.shown() * d if _seek.dragging() else now_playing.elapsed_ms()
	_elapsed.text = NowPlaying.clock(e)
	_remaining.text = "-" + NowPlaying.clock(d - e) if d > 0.0 else ""


func _update() -> void:
	if now_playing == null or not is_inside_tree():
		return
	var np := now_playing
	# The page follows a source coming on air, as stock's does.
	if np.on_air() != _on_air:
		_on_air = np.on_air()
		view = _on_air
	if not np.receiver:
		view = "phone"
	_tabs.visible = np.receiver
	for v in _tab:
		(_tab[v] as Button).set_pressed_no_signal(v == view)
	var phone := view == "phone"
	_seek_box.visible = phone and np.duration_ms > 0.0
	_stations.visible = not phone
	_fill.visible = phone
	_favorite.visible = not phone and _band().title != ""
	_seek.seekable = np.can_seek
	if phone:
		_source.text = " · ".join([np.app, _session_name(np.session)].filter(func(s): return s != "")).to_upper()
		_title.text = np.title if np.title != "" else "Nothing playing"
		_artist.text = np.artist
		_album.text = np.album
		_set_playing(np.playing())
		_tick()
	else:
		var band := _band()
		_source.text = "DAB+" if view == "dab" else "FM"
		_title.text = band.title if band.title != "" else "No station"
		_artist.text = band.text
		_album.text = band.detail
		_set_playing(band.active and band.playing)
		_favorite.set_meta("icon_name", "star" if band.favorite else "star_outline")
		_favorite.tooltip_text = "Unfavorite" if band.favorite else "Favorite"
		_favorite.icon = Icons.texture(_favorite.get_meta("icon_name"), ThemeManager.px.icon * 1.2)
		_update_stations(band)
	for b in [_prev, _next]:
		b.icon = Icons.texture(b.get_meta("icon_name"), ThemeManager.px.icon * 1.2)
	_update_art()


func _set_playing(on: bool) -> void:
	_play.set_meta("icon_name", "pause" if on else "play")
	_play.tooltip_text = "Pause" if on else "Play"
	_play.icon = Icons.texture(_play.get_meta("icon_name"), ThemeManager.px.icon * 1.5)


func _update_art() -> void:
	if now_playing == null:
		return
	if view == "phone":
		_art.texture = now_playing.art
		_art.initials = ""
		_art.fill = Color(0, 0, 0, 0)
	else:
		var band := _band()
		_art.texture = NowPlaying.logo(band.logo) if band.logo != "" else null
		_art.initials = band.initials
		_art.fill = band.badge
	queue_redraw()


func _band() -> Dictionary:
	if now_playing == null:
		return {}
	return now_playing.dab if view == "dab" else now_playing.fm


static func _session_name(s: String) -> String:
	return {carplay = "CarPlay", androidauto = "Android Auto", airplay = "AirPlay"}.get(s, "")


func _update_stations(band: Dictionary) -> void:
	var key := JSON.stringify([view, band.stations])
	if key == _stations_key:
		return
	_stations_key = key
	for c in _grid.get_children():
		_grid.remove_child(c)
		c.queue_free()
	for st in band.stations:
		var b := Button.new()
		b.name = str(st.id)
		b.text = str(st.label)
		if st.favorite:
			b.icon = Icons.texture("star", ThemeManager.px.icon * 0.8)
		# The tuned one in the accent, as a pressed button. Touch leaves the last one "hovered":
		# hover looks like rest.
		var rest: StyleBox = ThemeManager.godot_theme.get_stylebox("pressed" if st.tuned else "normal", "Button")
		b.add_theme_stylebox_override("normal", rest)
		b.add_theme_stylebox_override("hover", rest)
		if st.tuned:
			for k in ["font_color", "font_hover_color", "icon_normal_color", "icon_hover_color"]:
				b.add_theme_color_override(k, ThemeManager.c.on_accent)
		b.focus_mode = Control.FOCUS_NONE
		b.clip_text = true
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		b.custom_minimum_size = Vector2(ThemeManager.px.touch * STATION_W, ThemeManager.px.touch)
		var id: int = st.id
		b.pressed.connect(func(): if not _stations.dragged: pick_station(id))
		_grid.add_child(b)
	if band.stations.is_empty():
		var none := UI.label("No stations yet", "body", "body", "dim")
		none.name = "None"
		_grid.add_child(none)


func _on_core_changed(sections: PackedStringArray) -> void:
	if "config" in sections:
		_read_volume()


func _read_volume() -> void:
	if _sliding:
		return
	var v = Core.get_value("/config/huVolume")
	var level := float(v) if v != null else 0.0
	_volume.set_value_no_signal(level)
	_percent.text = "%d %%" % roundi(level * 100.0)
	_mute.set_meta("icon_name", "vol")
	_mute.tooltip_text = "Unmute" if level <= 0.0 else "Mute"
	_mute.modulate.a = 0.5 if level <= 0.0 else 1.0
	_mute.icon = Icons.texture("vol", ThemeManager.px.icon * 1.2)


func _on_volume(v: float) -> void:
	_percent.text = "%d %%" % roundi(v * 100.0)
	var now := Time.get_ticks_msec()
	if not _sliding:
		_send_volume(v)
	elif now - _volume_sent_ms >= VOLUME_MS:
		_volume_sent_ms = now
		_send_volume(v)


func _send_volume(v: float) -> void:
	Core.act({kind = "setConfig", patch = {huVolume = snappedf(v, 0.01)}})


func _toggle_mute() -> void:
	var v = Core.get_value("/config/huVolume")
	var level := float(v) if v != null else 0.0
	if level > 0.0:
		_unmuted = level
	_send_volume(HardKeys.volume_after("AudioVolumeMute", level, _unmuted))


## Transport as stock routes it: the phone's tab to the phone; a band's tab resumes that band
## when another source is on air, else the control goes to the band playing.
func _control(c: String) -> void:
	if now_playing == null:
		return
	if not now_playing.receiver or view == "phone":
		now_playing.pressed(c)
		Core.act({kind = "phoneMedia", control = c})
	elif now_playing.on_air() != view:
		Core.act({kind = "dabResume" if view == "dab" else "fmResume"})
	else:
		Core.act({kind = "media", control = c})
	_update()


## A tab: shows the source and puts it on air (stock's phone, resume and resume-fm).
func pick_view(v: String) -> void:
	show_view(v)
	Core.act({kind = {phone = "phoneResume", dab = "dabResume", fm = "fmResume"}[v]})


## Shows a tab without telling the core (a page the core opened itself).
func show_view(v: String) -> void:
	if v == view:
		return
	view = v
	_stations.offset = 0.0
	_update()
	queue_redraw()


## A station: tunes it; the one tuned and playing pauses (stock's `pick`).
func pick_station(id: int) -> void:
	var band := _band()
	if band.tuned == id and band.playing and band.active:
		Core.act({kind = "dabPause"})
	elif view == "fm":
		Core.act({kind = "fmPlay", khz = id})
	else:
		Core.act({kind = "dabPlay", serviceId = id})


func _toggle_favorite() -> void:
	var band := _band()
	if band.tuned < 0:
		return
	if view == "fm":
		Core.act({kind = "fmFavorite", khz = band.tuned, favorite = not band.favorite})
	else:
		Core.act({kind = "dabFavorite", serviceId = band.tuned, favorite = not band.favorite})
