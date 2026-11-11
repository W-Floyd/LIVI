extends Control
## The shell's root: the home page in its split layout, bound to the core's state. The
## projection is on one side and the panel on the other, swapped for RHD or the driver's
## "nearer" choice.

@onready var _status: StatusBar = $Page/Status
@onready var _body: HBoxContainer = $Page/Body
@onready var _slot: Control = $Page/Body/Slot
@onready var _projection: ProjectionView = $Projection
@onready var _side: MarginContainer = $Page/Body/Side
@onready var _handle: MarginContainer = $Page/Body/Handle
@onready var _phone_toggle: Button = $Page/Body/Handle/PhoneToggle
@onready var _stat: StatTile = $Page/Body/Side/Panel/Stat
@onready var _precondition: ToggleRow = $Page/Body/Side/Panel/Precondition
@onready var _stop: StopCard = $Page/Body/Side/Panel/Stop
@onready var _player: MiniPlayer = $Page/Body/Side/Panel/Player

## A tap on the "Electric vehicle" page's targets (`next_departure`, `scheduled`, `v2l`,
## `settings`). The core has no action for any of them yet.
signal ev_action(id: String)
## The page now showing, as `open_page` resolved it (`ev` is `ev_live` or `ev_main`).
signal page_changed(page: String)
## Whether a phone's picture (a projection video window) is there to show.
signal phone_changed(present: bool)

## Mapped windows, oldest first; the newest is shown until the window layouts land.
var _windows: Array[int] = []
var _app_ids := {}

## Side panel items, most important first. When they don't all fit, the panel drops items
## from the end, whole: never smaller text, never a half-shown card.
const PRIORITY := ["Stop", "Precondition", "Stat", "Player"]
## What the panel left out last time it was laid out, for tests and the shots' notes.
var left_out: Array[String] = []

## A scene theme's 3D layer, while one is in use.
var _scene: SceneSkin

## A pack's page standing in for the home page, while one is open.
var _page: Control
var _live_bar := false
## The "app" page: the newest hosted window fills the panel, nothing else drawn. "projection"
## too, with the newest projection video and nothing over it: Android Auto's own exit leaves it.
var _app_page := false
var _projection_page := false
## The page showing, as `open_page` resolved it, and where the projection page goes back to.
var _page_name := "home"
var _return_to := "home"
## Where the settings page goes back to.
var _settings_from := "home"
var _following_front := false
## The core's `/front/main` last seen: the phone's video focus.
var _front := ""
## Lists and starts apps, and knows which hosted window is whose (the "apps" page).
var launcher: Launcher
## What plays, for home's player and the media page.
var now_playing: NowPlaying
## Home's split, 0 to 1: the phone's picture beside the cards, or (no picture) the cards over the
## whole width. Tweened between; `_split_to` is where it is going.
var _split := 1.0
var _split_to := 1.0
var _split_tween: Tween
var _phone_present := false
const SPLIT_S := 0.35
## The keyboard for a hosted app's field (AppKeyboard), over the driver's side of the app page
## while the app wants text; the app is configured to the rest of the width meanwhile, so it lays
## its field and results out beside the keys rather than under them.
var app_keyboard: AppKeyboard
## Of the shell's width: about a phone's width (at the default app scale) left for the app.
const APP_KEYBOARD_SHARE := 0.55
## Brings the keyboard up for an app with no text input, to type to it as keys.
var _keys_button: Button
## Panel pixels a docked rail (NavRail) takes on the driver's side: every page lays out in the
## rest, the phone's area included, except the phone's own page, which keeps the whole panel.
var rail_width := 0.0:
	set(v):
		if v != rail_width:
			rail_width = v
			_inset()
			_tell_app_area()


func _init() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The status bar on one edge and home's body in the rest (`_layout_status`).
	var page := Control.new()
	page.name = "Page"
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var status := StatusBar.new()
	status.name = "Status"
	status.minimum_size_changed.connect(_layout_status)
	page.add_child(status)
	var body := HBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", 0)
	# The projection is its own layer under the page: in its slot for solid surfaces, under
	# everything for frosted and glass ones, which float over it.
	var projection := ProjectionView.new()
	projection.name = "Projection"
	add_child(projection)
	var slot := Control.new()
	slot.name = "Slot"
	slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.resized.connect(_place_projection)
	body.add_child(slot)
	# Between the slot and the cards, while a phone is connected: hides or shows its picture.
	var handle := MarginContainer.new()
	handle.name = "Handle"
	handle.visible = false
	var toggle := Button.new()
	toggle.name = "PhoneToggle"
	toggle.focus_mode = Control.FOCUS_NONE
	toggle.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	toggle.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toggle.pressed.connect(func(): ThemeManager.set_look({home_phone = not ThemeManager.home_phone}))
	handle.add_child(toggle)
	body.add_child(handle)
	var side := MarginContainer.new()
	side.name = "Side"
	side.clip_contents = true
	var panel := HomeCards.new()
	panel.name = "Panel"
	for pair in [["Stat", StatTile], ["Precondition", ToggleRow], ["Stop", StopCard], ["Player", MiniPlayer]]:
		var n: Control = pair[1].new()
		n.name = pair[0]
		panel.add_child(n)
	side.add_child(panel)
	body.add_child(side)
	page.add_child(body)
	add_child(page)
	launcher = Launcher.new()
	launcher.name = "Launcher"
	add_child(launcher)
	now_playing = NowPlaying.new()
	now_playing.name = "NowPlaying"
	add_child(now_playing)
	_keys_button = Button.new()
	_keys_button.name = "KeysButton"
	_keys_button.tooltip_text = "Keyboard"
	_keys_button.focus_mode = Control.FOCUS_NONE
	_keys_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_keys_button.visible = false
	_keys_button.pressed.connect(_on_keys_button)
	add_child(_keys_button)
	add_child(DriveBadge.new())


func _ready() -> void:
	theme = ThemeManager.godot_theme
	ThemeManager.changed.connect(_style)
	ThemeManager.changed.connect(func(): _update_split(); _tell_front())
	# A (re)connected core starts from its own idea of the main screen: say what this page shows.
	Core.welcome.connect(func(_v): _refresh(); _tell_front(); _ask_area(true))
	Core.changed.connect(_on_core_changed)
	Core.open_page.connect(_on_core_page)
	_stat.hero = _split_to == 1.0
	_projection.visible = false
	_precondition.icon_name = "therm"
	_precondition.pressed.connect(_on_precondition)
	_player.control.connect(func(c): now_playing.pressed(c); Core.act({kind = "media", control = c}))
	_player.opened.connect(func(): open_page.call_deferred("media"))
	now_playing.changed.connect(_update_player)
	now_playing.art_changed.connect(_update_player)
	_update_player()
	Wayland.window_mapped.connect(func(id, app_id, title): print("window %d mapped: app_id \"%s\" title \"%s\"" % [id, app_id, title]); _windows.append(id); _app_ids[id] = app_id; _show_app())
	Wayland.window_unmapped.connect(_on_window_unmapped)
	Wayland.text_input_wanted.connect(_on_text_wanted)
	Wayland.text_input_released.connect(func(id): if app_keyboard and app_keyboard.window_id == id: app_keyboard.close())
	Drive.changed.connect(_update_keys_button)
	launcher.show_window.connect(bring_forward)
	_status.edge = ThemeManager.status_position
	_style()
	_refresh()
	_tell_app_area()


func _process(_delta: float) -> void:
	var t := Time.get_datetime_dict_from_unix_time(int(Clock.now()))
	_status.clock = "%02d:%02d" % [t.hour, t.minute]


func _draw() -> void:
	# A scene theme's 3D world shows through instead.
	if not ThemeManager.is_scene() and not _page is EvLive:
		draw_rect(Rect2(Vector2.ZERO, size), ThemeManager.c.bg)


func _style() -> void:
	theme = ThemeManager.godot_theme
	if ThemeManager.is_scene() and _scene == null:
		_scene = SceneSkin.new()
		_scene.name = "Scene"
		_scene.surfaces = [_status, _stat, _precondition, _stop, _player, _phone_toggle]
		add_child(_scene)
		move_child(_scene, 0)
	elif not ThemeManager.is_scene() and _scene != null:
		_scene.queue_free()
		_scene = null
	if _scene:
		_scene.visible = _page == null
	# A pack that comes or goes changes who draws the live page's title bar.
	if _page is EvLive and _live_bar != _own_bar():
		open_page("ev_live")
	var g: float = ThemeManager.px.gap
	for k in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		_side.add_theme_constant_override(k, roundi(g * 1.5))
	var cards: HomeCards = _side.get_node("Panel")
	cards.gap = roundi(g * 1.5)
	cards.column = ThemeManager.px.side - roundi(g * 1.5) * 2
	cards.column_left = ThemeManager.side_left()
	_body.move_child(_side, 0 if ThemeManager.side_left() else 2)
	_body.move_child(_handle, 1)
	# Its gap to the slot is the cards' to it.
	_handle.add_theme_constant_override("margin_top", roundi(g * 1.5))
	_handle.add_theme_constant_override("margin_left", 0 if ThemeManager.side_left() else roundi(g * 1.5))
	_handle.add_theme_constant_override("margin_right", roundi(g * 1.5) if ThemeManager.side_left() else 0)
	_phone_toggle.custom_minimum_size = Vector2.ONE * ThemeManager.px.touch
	_style_toggle()
	_set_split(_split)
	# The page passes input through where the projection shows.
	$Page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()
	_fit.call_deferred()
	_place_projection.call_deferred()
	# The driver's side may have changed.
	if rail_width > 0.0:
		_inset()
	_keys_button.custom_minimum_size = Vector2.ONE * ThemeManager.px.touch * 1.2
	_keys_button.icon = Icons.texture("keyboard", ThemeManager.px.icon)
	_place_keyboard.call_deferred()
	if _status.edge != ThemeManager.status_position:
		_move_status()
	_layout_status()


## Hosted apps are configured to the app page's rect (the panel less the rail), whichever page
## shows, so a page change does not resize them.
func _tell_app_area() -> void:
	var vp := get_viewport_rect().size
	Wayland.set_app_area(roundi(vp.x - rail_width - _keyboard_width()), roundi(vp.y))


func _inset() -> void:
	var w := 0.0 if _projection_page else rail_width
	var left := ThemeManager.hand != "rhd"
	offset_left = w if left else 0.0
	offset_right = 0.0 if left else -w
	_place_next_frame()


## The shell's rect (already beside a docked rail) less the status bar, where the page showing
## lays out: home's body, and every page `_fit_page` places. The whole rect on pages without
## the bar (the app and phone pages, a pack's screens, a pack's own EV title bar).
func content_rect() -> Rect2:
	return _rect_beside_status() if $Page.visible else Rect2(Vector2.ZERO, size)


func _rect_beside_status() -> Rect2:
	var r := Rect2(Vector2.ZERO, size)
	var t := _status_thickness()
	match _status.edge:
		"bottom":
			r.size.y -= t
		"left":
			r.position.x += t
			r.size.x -= t
		"right":
			r.size.x -= t
		_:
			r.position.y += t
			r.size.y -= t
	return r


## Whole pixels, as the rail: a row as a box container lays it out (truncated), a column rounded
## up so its widest item fits. None when it is off.
func _status_thickness() -> float:
	if _status.edge == "off":
		return 0.0
	var m := _status.get_combined_minimum_size()
	return ceilf(m.x) if _status.vertical() else floorf(m.y)


## Puts the status bar on its edge and the body in the rest, and the open page with it.
func _layout_status() -> void:
	if _status == null:
		return
	var t := _status_thickness()
	const PRESETS := {top = Control.PRESET_TOP_WIDE, bottom = Control.PRESET_BOTTOM_WIDE, left = Control.PRESET_LEFT_WIDE, right = Control.PRESET_RIGHT_WIDE, off = Control.PRESET_TOP_WIDE}
	_status.visible = _status.edge != "off"
	_status.set_anchors_preset(PRESETS[_status.edge])
	for k in ["offset_left", "offset_top", "offset_right", "offset_bottom"]:
		_status.set(k, 0.0)
	match _status.edge:
		"bottom":
			_status.offset_top = -t
		"left":
			_status.offset_right = t
		"right":
			_status.offset_left = -t
		_:
			_status.offset_bottom = t
	var r := _rect_beside_status()
	_body.set_anchors_preset(Control.PRESET_FULL_RECT)
	_body.offset_left = r.position.x
	_body.offset_top = r.position.y
	_body.offset_right = r.end.x - size.x
	_body.offset_bottom = r.end.y - size.y
	if _page:
		_fit_page(_page)
	_place_next_frame()


## A new edge for the status bar (Look → Status bar): it fades in there, at once under reduced
## motion.
func _move_status() -> void:
	_status.edge = ThemeManager.status_position
	if ThemeManager.reduced_motion or not is_visible_in_tree():
		return
	_status.modulate.a = 0.0
	create_tween().tween_property(_status, "modulate:a", 1.0, SPLIT_S)


## The status bar's rect in the shell's, empty on pages without it.
func status_rect() -> Rect2:
	return _status.get_rect() if $Page.visible and _status.visible else Rect2()


## Whether the status bar shows as a column on the driver's side, where a docked rail is: the two
## then read as one band (`NavRail.joined`), the column nearer the page.
func status_beside_rail() -> bool:
	return is_node_ready() and $Page.visible and ThemeManager.status_position == ("left" if _driver_left() else "right")


## Lays `page` out in `content_rect`. A page with a `top_inset` spans the top and draws its own
## content below it, as it did under the top bar only.
func _fit_page(page: Control) -> void:
	var r := content_rect()
	page.offset_left = r.position.x
	page.offset_right = r.end.x - size.x
	page.offset_bottom = r.end.y - size.y
	if "top_inset" in page:
		# The bar's unrounded height, which these pages have always drawn below.
		var top := _status.get_combined_minimum_size().y if $Page.visible and _status.edge == "top" else r.position.y
		if page.top_inset != top:
			page.top_inset = top
			if page.has_method("_layout"):
				page.call_deferred("_layout")
			page.queue_redraw()
		if page is SettingsPage:
			page.offset_top = top
	else:
		page.offset_top = r.position.y


## "home"; a screen of the theme's pack, which replaces the home page until "home" again
## (`ev_main`, the pack's image page); `ev_live`, the Godot-rendered "Electric vehicle" page,
## which every theme has; `ev`, whichever of the two the theme and the look choose
## (`ThemeManager.ev_page_kind`); `app`; `apps`, the launcher; or `projection`, the phone's
## picture alone on the panel. An error message when there is no such page.
func open_page(page: String) -> String:
	if page == "ev":
		page = "ev_live" if ThemeManager.ev_page_kind() == "live" else "ev_main"
	if page == "ev_live":
		if _powertrain() != "electric":
			return "ev_live needs an electric car"
	elif page == "settings":
		pass
	elif page not in ["home", "app", "apps", "projection", "media"] and not (ThemeManager.pack and ThemeManager.pack.has_screen(page)):
		return "theme %s has no page %s" % [ThemeManager.theme_name, page]
	if _page:
		remove_child(_page)
		_page.free()
		_page = null
	if page == "projection" and _page_name != "projection":
		_return_to = _page_name
	if page == "settings" and _page_name != "settings":
		_settings_from = _page_name
	_page_name = page
	_projection_page = page == "projection"
	_app_page = page == "app" or _projection_page
	if rail_width > 0.0:
		_inset()
	var home := page == "home"
	var live := page == "ev_live"
	var own_bar := live and _own_bar()
	_live_bar = own_bar
	# The live page keeps the status bar unless its pack draws its own title bar.
	$Page.visible = home or page == "apps" or page == "media" or (live and not own_bar)
	_body.visible = home
	# Off home, the split is where it will be when home shows again.
	if not home and _split_tween:
		_split_tween.kill()
		_split_tween = null
		_set_split(_split_to)
	_projection.visible = _app_page or (home and _split < 1.0)
	# Every page change: leaving the full-panel pages puts the picture back in home's slot. The
	# slot's size is stale until the body, hidden till now, lays out: the phone is asked after.
	_place_projection(not home)
	_place_next_frame()
	if _scene:
		_scene.visible = home
	if live:
		var ev := EvLive.new()
		_fit_page(ev)
		ev.tile_pressed.connect(func(id): ev_action.emit(id))
		ev.back_pressed.connect(func(): open_page.call_deferred("home"))
		_page = ev
		add_child(_page)
	elif page == "settings":
		var settings := SettingsPage.new()
		settings.back_pressed.connect(func(): open_page.call_deferred(_settings_from))
		$Page.visible = true
		_fit_page(settings)
		_page = settings
		add_child(_page)
	elif page == "media":
		var media := MediaPage.new()
		media.now_playing = now_playing
		_fit_page(media)
		_page = media
		add_child(_page)
	elif page == "apps":
		var apps := AppsPage.new()
		apps.launcher = launcher
		_fit_page(apps)
		_page = apps
		add_child(_page)
	elif not home and not _app_page:
		_page = PackScreen.new()
		_page.screen_name = page
		add_child(_page)
	_layout_status()
	_show_app()
	if not _following_front:
		_tell_front()
	queue_redraw()
	page_changed.emit(page)
	return ""


## Shows a hosted window on the app page, in front of the others.
func bring_forward(id: int) -> void:
	if not _windows.has(id):
		return
	_windows.erase(id)
	_windows.append(id)
	open_page("app")


## Whether the phone's picture is what the page shows.
func _on_projection() -> bool:
	return _projection_page or (_app_page and _projection.window.to_core)


## As the stock UI does: the phone has video focus while its picture is the page, and gives it
## back when the page goes. The core passes touches on only while it does.
func _tell_front() -> void:
	Core.act({kind = "show", screen = "main", front = "projection" if _shows_projection() else "livi"})


## Pages with the phone's picture on them: home has it in its slot, so the phone keeps video
## focus there too (and the slot's picture exists only while it does).
func _shows_projection() -> bool:
	return _on_projection() or (_page_name == "home" and ThemeManager.home_phone)


## Day or night as the core has it for the main screen's UI: the car's lights (its night mode,
## through the telemetry) unless LIVI's appearance setting is Day or Night.
func _follow_night() -> void:
	var n = Core.get_value("/config/mainUiNightMode")
	# The look's own Day or Night wins.
	if n == null or ThemeManager.appearance_mode != "auto":
		return
	var want := "night" if n else "day"
	if ThemeManager.appearance != want:
		ThemeManager.set_look({appearance = want})


## Follows the core's main screen: the phone asking for it (navigation, a call) opens the
## projection page; Android Auto's own exit, or the end of that ask, leaves it.
func _follow_front() -> void:
	var f = Core.get_value("/front/main")
	if f == null or str(f) == _front:
		return
	var was := _front
	_front = str(f)
	# The phone's own choice: follow it without answering, or home (which shows the phone's
	# slot) would take the screen straight back after Android Auto's exit.
	_following_front = true
	if _front == "projection" and not _shows_projection():
		open_page("projection")
	elif _front == "livi" and was != "" and _on_projection():
		open_page(_return_to if _projection_page else "home")
	_following_front = false
	# Acknowledge the phone giving the screen up: the core ignores a request equal to the last
	# one it got, so without this a later "projection" (Full, home) would not reach the phone.
	if _front == "livi" and was != "":
		Core.act({kind = "show", screen = "main", front = "livi"})


## The car's own buttons and telemetry open pages by path; the shell has the projection only.
func _on_core_page(path: String) -> void:
	var first := path.trim_prefix("/").get_slice("/", 0)
	if first == "" or first == "projection":
		if not _on_projection():
			open_page("projection")
	elif first == "media":
		# /media/phone, /media/dabplus, /media/fm: that tab, without putting it on air.
		if _page_name != "media":
			open_page("media")
		var tab: String = {phone = "phone", dabplus = "dab", fm = "fm"}.get(path.trim_prefix("/").get_slice("/", 1), "")
		if tab != "" and _page is MediaPage and now_playing.receiver:
			(_page as MediaPage).show_view(tab)
	else:
		print("core asks for %s: the shell has no such page" % path)


## Draws the live page's 3D scene once into a tiny viewport, so its shaders are compiled before
## the first visit: on the unit's GPU that is seconds, and it would otherwise stall the first tap.
func warm_up() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(96, 54)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.add_child(EvScene.new())
	add_child(vp)
	for i in 3:
		await RenderingServer.frame_post_draw
	vp.queue_free()


## Whether the active pack draws the live page's title bar itself: it has the stock layout.
func _own_bar() -> bool:
	return not EvLive.pack_layout().is_empty()


func _place_projection(ask := true) -> void:
	if _projection == null:
		return
	var r := Rect2(_slot.global_position - global_position, _slot.size)
	if _app_page:
		r = Rect2(Vector2.ZERO, size)
		var kw := 0.0 if _projection_page else _keyboard_width()
		r.size.x -= kw
		if _driver_left():
			r.position.x += kw
	elif ThemeManager.floating():
		# Under the floating panel: the whole projection screen, 1:1 with the panel, under a docked
		# rail too; the shell's own rect would scale it into the rest.
		r = Rect2(get_viewport_rect().position - global_position, get_viewport_rect().size)
	_projection.position = r.position
	_projection.size = r.size
	# The picture follows the slot every frame; the phone is asked for where it settles.
	if ask and _split_tween == null:
		_ask_area()


## Once this frame's deferred layout passes (minimum size, then sort) have run.
func _place_next_frame() -> void:
	if is_inside_tree() and not get_tree().process_frame.is_connected(_place_projection):
		get_tree().process_frame.connect(_place_projection, CONNECT_ONE_SHOT)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _side:
		_layout_status()
		_set_split(_split)
		_place_keyboard()


## Opens home's slot while there is a phone's picture, else gives the cards the whole width:
## animated on home, at once elsewhere or under reduced motion.
func _update_split() -> void:
	var present := has_phone()
	if present != _phone_present:
		_phone_present = present
		_handle.visible = present
		_set_split(_split)
		phone_changed.emit(present)
	# The driver can keep home to the cards while a phone is connected (Look → Phone on home).
	var want := 0.0 if present and ThemeManager.home_phone else 1.0
	if want == _split_to:
		return
	_split_to = want
	_stat.hero = want == 1.0
	_fit.call_deferred()
	if _split_tween:
		_split_tween.kill()
		_split_tween = null
	if ThemeManager.reduced_motion or _page_name != "home" or not is_visible_in_tree():
		_set_split(want)
		_split_settled()
		return
	_projection.visible = true
	_split_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_split_tween.tween_method(_set_split, _split, want, SPLIT_S)
	_split_tween.finished.connect(_split_settled)


func _set_split(v: float) -> void:
	_split = v
	var handle := _handle.get_combined_minimum_size().x if _handle.visible else 0.0
	_side.custom_minimum_size.x = lerpf(ThemeManager.px.side, _rect_beside_status().size.x - handle, v)
	(_side.get_node("Panel") as HomeCards).wide = v


func _split_settled() -> void:
	_split_tween = null
	if _page_name == "home":
		_projection.visible = _split < 1.0
	# A slot that closed is asked for again when it opens, whatever it was before.
	if _split_to == 1.0:
		_area_asked = Rect2i()
	_place_next_frame()


## Hide while the picture is in the slot, show while it is not.
func _style_toggle() -> void:
	var shown := ThemeManager.home_phone
	_phone_toggle.icon = Icons.texture("eye_off" if shown else "phone", ThemeManager.px.icon)
	_phone_toggle.tooltip_text = "Hide the phone" if shown else "Show the phone"


## A projection video window (Android Auto or CarPlay streaming) is mapped.
func has_phone() -> bool:
	return _windows.any(_is_projection)


## The last area asked of the phone, in the projection screen's pixels.
var _area_asked := Rect2i()


## Android Auto lays its UI out where the page shows it: home's slot (under a floating panel too),
## else the whole panel. A phone that does not take it is letterboxed (`WindowView`).
func _ask_area(again := false) -> void:
	if not _shows_projection():
		return
	var a: Rect2i = _projection.window.to_screen(_slot.get_global_rect() if _page_name == "home" else get_global_rect())
	if a.size.x <= 0 or a.size.y <= 0 or (a == _area_asked and not again):
		return
	_area_asked = a
	Core.act({kind = "projectionArea", screen = "main", x = a.position.x, y = a.position.y, width = a.size.x, height = a.size.y})


## Shows every item that has content, then drops the least important until the rest fit.
func _fit() -> void:
	var panel: HomeCards = _side.get_node("Panel")
	var dashboard := _split_to == 1.0
	var electric := _powertrain() == "electric"
	var wanted := {Stat = true, Precondition = electric, Stop = electric and _stop.has_content(), Player = _player.has_content()}
	for n in PRIORITY:
		panel.get_node(n).visible = wanted[n]
	# The screen's height, not the panel's: the panel grows with what it holds.
	var room: float = _rect_beside_status().size.y \
		- _side.get_theme_constant("margin_top") - _side.get_theme_constant("margin_bottom")
	left_out.clear()
	var order := PRIORITY.duplicate()
	order.reverse()
	for n in order:
		var need := panel.needed(dashboard)
		if need <= room:
			break
		var item: Control = panel.get_node(n)
		if item.visible:
			item.visible = false
			# The hero beside a too-tall stack: leaving it out would not make the stack fit.
			if panel.needed(dashboard) >= need:
				item.visible = true
				continue
			left_out.append(n)
	if not left_out.is_empty():
		print("side panel: left out %s; it holds %d px" % [", ".join(left_out), roundi(room)])


func _on_window_unmapped(id: int) -> void:
	_windows.erase(id)
	_app_ids.erase(id)
	# The app page shows hosted apps only: with none left, back to the grid they came from
	# (not to the phone's video, which is the newest window left).
	if _page_name == "app" and not _windows.any(func(w): return not _is_projection(w)):
		_update_split()
		open_page("apps")
		return
	# The phone's page with the phone gone: back where it was opened from, not a blank panel.
	if _projection_page and not has_phone():
		_update_split()
		open_page(_return_to if _return_to != "projection" else "home")
		return
	_show_app()


func _show_app() -> void:
	_update_split()
	# Home's slot is the phone's alone: a hosted app is the app page's.
	var phone := _projection_page or _page_name == "home"
	var shown: Array = _windows.filter(_is_projection) if phone else _windows.filter(func(w): return not _is_projection(w)) if _page_name == "app" else Array(_windows)
	var id: int = shown[-1] if not shown.is_empty() else -1
	_projection.show_window(id, id >= 0 and _is_projection(id))
	# The keyboard types into the app showing, on its page only.
	if app_keyboard and (_page_name != "app" or app_keyboard.window_id != id):
		app_keyboard.close()
	_update_keys_button()


func _driver_left() -> bool:
	return ThemeManager.hand != "rhd"


func _keyboard_width() -> float:
	return roundf(size.x * APP_KEYBOARD_SHARE) if app_keyboard and not app_keyboard.closing() else 0.0


## A hosted app showing on the app page wants text: the keyboard comes up for it. Never for the
## phone's picture, whose own keyboard is on the phone's UI.
func _on_text_wanted(id: int) -> void:
	if _page_name != "app" or _projection.window.window_id != id or _is_projection(id):
		return
	open_keyboard(id, Wayland.text_field(id))


## The keyboard for window `id`'s `field` (as `Wayland.text_field` gives it; empty: keys only).
func open_keyboard(id: int, field: Dictionary) -> void:
	if app_keyboard and app_keyboard.window_id == id and not app_keyboard.closing():
		return
	var k := AppKeyboard.new()
	k.closed.connect(_on_keyboard_closed.bind(k))
	add_child(k)
	app_keyboard = k
	k.configure(id, field)
	_place_keyboard()
	k.slide_in(k.position.x, _driver_left())
	_tell_app_area()
	_place_projection(false)
	_update_keys_button()


func _on_keyboard_closed(_submitted: bool, k: AppKeyboard) -> void:
	# Its name is the next one's, while it slides out.
	k.name = "ClosingKeyboard"
	if app_keyboard == k:
		app_keyboard = null
	_tell_app_area()
	_place_projection(false)
	_update_keys_button()


## Full height on the driver's side of the shell's rect, beside a docked rail.
func _place_keyboard() -> void:
	if app_keyboard == null or app_keyboard.closing():
		return
	var kw := _keyboard_width()
	app_keyboard.size = Vector2(kw, size.y)
	if not app_keyboard.moving():
		app_keyboard.position = Vector2(0.0 if _driver_left() else size.x - kw, 0.0)
	_place_projection(false)
	_update_keys_button()


## In the app's bottom corner on the driver's side, for an app that has no text input to ask with.
func _update_keys_button() -> void:
	var id := _projection.window.window_id
	var on := _page_name == "app" and id >= 0 and not _is_projection(id) and app_keyboard == null and not Wayland.has_text_input(id) and not Drive.covers_window(id)
	_keys_button.visible = on
	if not on:
		return
	var g: float = ThemeManager.px.gap * 2.0
	var b := _keys_button.get_combined_minimum_size()
	_keys_button.size = b
	_keys_button.position = Vector2(g if _driver_left() else size.x - b.x - g, size.y - b.y - g)


func _on_keys_button() -> void:
	var id := _projection.window.window_id
	if id < 0:
		return
	_projection.window.focus_app()
	open_keyboard(id, {})


## livi-gst-host names its video windows livi-video; their touches are the phone's.
func _is_projection(id: int) -> bool:
	return str(_app_ids.get(id, "")).begins_with("livi-video")


## Sections changed since the last refresh. A phone session changes the track, with its artwork,
## and the route several times a second; one refresh a frame, of what changed, keeps the unit's
## CPU for drawing.
var _dirty := {}


func _on_core_changed(sections: PackedStringArray) -> void:
	var first := _dirty.is_empty()
	for s in sections:
		_dirty[s] = true
	if first:
		_refresh_dirty.call_deferred()


func _refresh_dirty() -> void:
	var d := _dirty
	_dirty = {}
	_refresh(d)


## `sections` are the changed ones; empty means all.
func _refresh(sections := {}) -> void:
	if sections.is_empty() or sections.has("front"):
		_follow_front()
	if sections.is_empty() or sections.has("config"):
		_follow_night()
	var t := func(p: String): return Core.get_value("/telemetry/" + p)
	# fuelPct is the charge for an electric car and the tank otherwise.
	var power := _powertrain()
	var soc = t.call("fuelPct")
	_stat.icon_name = "bolt" if power == "electric" else "fuel"
	_stat.value = "–" if soc == null else str(roundi(soc))
	_stat.unit = "%"
	_stat.fraction = -1.0 if soc == null else soc / 100.0
	var km = t.call("rangeKm")
	_stat.sub_label = "Range"
	_stat.sub_value = "–" if km == null else Units.range_text(km)
	var ev_km = t.call("rangeElectricKm")
	if power == "hybrid" and ev_km != null:
		_stat.sub_label = "Range · %s electric" % Units.range_text(ev_km)
	var amb = t.call("ambientC")
	_status.outside = "" if amb == null else Units.temperature(amb)
	_status.charge = "" if soc == null else "%d %%" % roundi(soc)
	_status.charge_icon = "bolt" if power == "electric" else "fuel"
	_status.phone = "Pixel"

	# No typing while the car is driven.
	var lock := DriveCover.new()
	lock.typing = true
	lock.dismissed.connect(k.close)
	k.add_child(lock)
	var on := _preconditioning()
	_precondition.set_pressed_no_signal(on)
	_precondition.label = "Warming battery" if on else "Precondition battery"
	_precondition.detail = "on" if on else "for 30 min"
	_precondition._style()

	var stop = Core.get_value("/navigation/chargingStop")
	if stop is Dictionary:
		var cap = t.call("batteryCapacityKwh")
		if stop.get("arrivalWh") != null and cap:
			stop.arrivalPct = stop.arrivalWh / (cap * 10.0)
		_stop.stop = stop

	_fit.call_deferred()


## Home's player: the phone's track, or the radio station on air.
func _update_player() -> void:
	var np := now_playing
	var band: Dictionary = np.dab if np.on_air() == "dab" else np.fm if np.on_air() == "fm" else {}
	if band.is_empty():
		_player.title = np.title
		_player.subtitle = " · ".join([np.artist, np.album].filter(func(s): return s))
		_player.playing = np.playing()
		_player.art = np.art
		_player.initials = ""
		_player.badge = Color(0, 0, 0, 0)
	else:
		_player.title = band.title if band.title != "" else ("DAB+" if np.on_air() == "dab" else "FM")
		_player.subtitle = " · ".join([band.text, band.detail].filter(func(s): return s))
		_player.playing = band.playing
		_player.art = NowPlaying.logo(band.logo) if band.logo != "" else null
		_player.initials = band.initials
		_player.badge = band.badge
	_fit.call_deferred()


## electric | hybrid | combustion, from the core's carType (LIVI's CarType numbers). When it
## is unset, a battery capacity in the telemetry means electric.
func _powertrain() -> String:
	var t = Core.get_value("/config/carType")
	match int(t) if t != null else 0:
		10:
			return "electric"
		101, 102:
			return "hybrid"
		0, 12:
			return "electric" if Core.get_value("/telemetry/batteryCapacityKwh") != null else "combustion"
		_:
			return "combustion"


func _preconditioning() -> bool:
	return Core.get_value("/precondition/manualUntil") != null


## The row shows the core's state, not the tap: it changes when the core says so.
func _on_precondition() -> void:
	var want := not _preconditioning()
	_precondition.set_pressed_no_signal(not want)
	var err: String = Core.act({kind = "preconditionBattery", on = want})
	if err != "":
		push_error("precondition: %s" % err)
