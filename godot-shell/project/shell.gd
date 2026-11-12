extends Control
## The shell's root: the home page in its split layout, bound to the core's state. The
## projection is on one side and the panel on the other, swapped for RHD or the driver's
## "nearer" choice.

@onready var _status: StatusBar = $Page/Status
@onready var _body: HBoxContainer = $Page/Body
@onready var _slot: Control = $Page/Body/Slot
@onready var _projection: ProjectionView = $Projection
@onready var _side: MarginContainer = $Page/Body/Side
@onready var _handle: PhoneHandle = $Page/PhoneHandle
@onready var _source: SourceToggle = $Page/Source
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
## from the end, whole: never smaller text, never a half-shown card. The media card leads home
## and is never the one left out.
const PRIORITY := ["Player", "Stop", "Stat", "Precondition"]
## What the panel left out last time it was laid out, for tests and the shots' notes.
var left_out: Array[String] = []
## Logged once per change: telemetry refits the panel several times a second.
var _left_out_said := ""
## What the last fit was of (`_fit`); emptied by a restyle.
var _fit_key := []
## Fits run, for tests.
var fits := 0

## A scene theme's 3D layer, while one is in use.
var _scene: SceneSkin

## A pack's page standing in for the home page, while one is open.
var _page: Control
## The pages off home, loaded at their first use (`_page_script`): naming their classes here would
## compile them with the shell, before the first frame (docs/startup.md).
const PAGE_SCRIPTS := {ev_live = "res://ui/ev_live.gd", settings = "res://ui/settings_page.gd", media = "res://ui/media_page.gd", apps = "res://ui/apps_page.gd", pack = "res://ui/pack_screen.gd"}
## The live EV page, kept while another page shows (`_live_page`). A Control: see PAGE_SCRIPTS.
var _ev_live: Control
## Started by each look change while the live page is away (`warm_up`).
var _rewarm: Timer
const REWARM_S := 1.5
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
## Home by a swipe in from a panel edge, as the look sets it.
var _edge: EdgeSwipe
## Lists and starts apps, and knows which hosted window is whose (the "apps" page).
var launcher: Launcher
## What plays, for home's player and the media page.
var now_playing: NowPlaying
## Home's split, 0 to 1: the phone's picture beside the cards, or (no picture) the cards over the
## whole width. `_split_to` is where it is going: 0 the phone at its width, 1 none.
var _split := 1.0
var _split_to := 1.0
## The cards' width, and where it is going (`_slide`); the slot takes the rest.
var _side_w := 0.0
var _side_to := -1.0
var _split_tween: Tween
## Slides started (`_start_slide`): a later one supersedes one not yet started.
var _slides := 0
## The handle is being dragged, from the cards at `_drag_w0`.
var _dragging := false
var _drag_w0 := 0.0
var _phone_present := false
## Home's slot has something to show: the phone's picture, or the navigation app.
var _slot_present := false
## The navigation app's window last given the slot's size, else -1 (`_size_nav`).
var _nav_window := -1
## The look's `nav_app` and `home_source` as last applied (`_on_nav_look`).
var _nav_seen := []
## The launcher's list was read for the navigation app (`nav_app`).
var _apps_scanned := false
## The navigation app kept running (`_keep_nav`): the one started since it was designated, the
## restarts so far after it exited, when its window last mapped, and the wait before the next.
var _nav_kept := ""
var _nav_restarts := 0
var _nav_up_ms := 0
var _nav_retry: Timer
## Seconds before each restart; the last repeats. Running this long resets them.
const NAV_RETRY_S := [2.0, 4.0, 8.0, 16.0, 32.0, 60.0]
const NAV_STABLE_S := 60.0
const SPLIT_S := 0.35
## The keyboard for a hosted app's field (AppKeyboard), over the driver's side of the app page
## while the app wants text; the app is configured to the rest of the width meanwhile, so it lays
## its field and results out beside the keys rather than under them.
var app_keyboard: AppKeyboard
## Of the shell's width: about a phone's width (at the default app scale) left for the app.
const APP_KEYBOARD_SHARE := 0.55
## Brings the keyboard up for an app with no text input, to type to it as keys.
var _keys_button: Button
## Built ahead for the next field (`_prepare_keyboard`).
var _spare_keyboard: AppKeyboard
## Panel pixels a docked rail (NavRail) takes on the driver's side: every page lays out in the
## rest, the phone's area included, except the phone's own page, which keeps the whole panel.
var rail_width := 0.0:
	set(v):
		if v != rail_width:
			rail_width = v
			# The rail is the way home: the EV page's and Settings' back buttons only without it.
			if _ev_live:
				_ev_live.back_button = v <= 0.0
			if _is_page(_page, "settings"):
				_page.back_button = v <= 0.0
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
	# The slot toggle lies over the bar's slot for it.
	status.source_moved.connect(func(): _place_source.call_deferred())
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
	var side := MarginContainer.new()
	side.name = "Side"
	side.clip_contents = true
	# Riding the cards, the status bar follows their column as it sorts.
	side.item_rect_changed.connect(func(): _place_status())
	var panel := HomeCards.new()
	panel.name = "Panel"
	for pair in [["Stat", StatTile], ["Precondition", ToggleRow], ["Stop", StopCard], ["Player", MiniPlayer]]:
		var n: Control = pair[1].new()
		n.name = pair[0]
		panel.add_child(n)
	side.add_child(panel)
	body.add_child(side)
	page.add_child(body)
	# In the gutter between the slot and the cards, over the body, while a phone is connected.
	var handle := PhoneHandle.new()
	handle.name = "PhoneHandle"
	handle.visible = false
	handle.dragged.connect(_on_handle_drag)
	handle.released.connect(_on_handle_release)
	handle.reset.connect(_on_handle_reset)
	body.sort_children.connect(_place_handle)
	page.add_child(handle)
	# Under the cards on the slot's side, while the phone and the navigation app are both there.
	var source := SourceToggle.new()
	source.visible = false
	body.sort_children.connect(_place_source)
	page.add_child(source)
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
	_edge = EdgeSwipe.new()
	_edge.name = "EdgeSwipe"
	_edge.home.connect(func(): print("edge swipe: home from %s" % _page_name); open_page.call_deferred("home"))


func _ready() -> void:
	theme = ThemeManager.godot_theme
	ThemeManager.changed.connect(_follow_night)
	ThemeManager.changed.connect(_style)
	ThemeManager.changed.connect(func(): _update_split(); _tell_front())
	# A (re)connected core starts from its own idea of the main screen: say what this page shows.
	Core.welcome.connect(func(_v): _refresh(); _tell_front(); _ask_area(true))
	Core.changed.connect(_on_core_changed)
	Core.open_page.connect(_on_core_page)
	# _input runs last node first: after the shell and the rail, which joins right after the shell
	# (NavRail.attach), so it sees a press before the pages, the rail or any window view.
	get_parent().add_child.call_deferred(_edge)
	tree_exited.connect(_edge.queue_free)
	# Compact: the media card leads home.
	_stat.hero = false
	_projection.visible = false
	_projection.visibility_changed.connect(_pace_windows)
	_precondition.icon_name = "therm"
	_precondition.pressed.connect(_on_precondition)
	var auto := AutoChip.new("Auto")
	auto.name = "Auto"
	auto.pressed.connect(_on_auto_precondition)
	_precondition.trailing = auto
	_player.control.connect(func(c): now_playing.pressed(c); Core.act({kind = "media", control = c}))
	_player.opened.connect(func(): open_page.call_deferred("media"))
	_player.now_playing = now_playing
	(_side.get_node("Panel") as HomeCards).tall = _player
	(_side.get_node("Panel") as HomeCards).host = _stat
	# Which cards fit depends on the panel's width too (the media card's layout, a split column).
	_side.get_node("Panel").resized.connect(func(): _fit.call_deferred())
	now_playing.changed.connect(_update_player)
	now_playing.art_changed.connect(_update_player)
	_update_player()
	Wayland.window_mapped.connect(func(id, app_id, title): print("window %d mapped: app_id \"%s\" title \"%s\"" % [id, app_id, title]); _windows.append(id); _app_ids[id] = app_id; _show_app())
	Wayland.window_unmapped.connect(_on_window_unmapped)
	Wayland.text_input_wanted.connect(_on_text_wanted)
	Wayland.text_input_released.connect(func(id): if app_keyboard and app_keyboard.window_id == id: app_keyboard.close())
	# After the first frames: a keyboard ready for the first field.
	get_tree().create_timer(2.0).timeout.connect(_prepare_keyboard)
	Drive.changed.connect(_update_keys_button)
	launcher.show_window.connect(bring_forward)
	launcher.changed.connect(_update_source)
	# Deferred: `changed` comes from inside the launcher's own calls.
	launcher.changed.connect(func(): _keep_nav.call_deferred())
	_nav_retry = Timer.new()
	_nav_retry.one_shot = true
	_nav_retry.timeout.connect(_keep_nav.bind(true))
	add_child(_nav_retry)
	_source.picked.connect(_pick_source)
	ThemeManager.changed.connect(_on_nav_look)
	_nav_seen = [ThemeManager.nav_app, ThemeManager.home_source]
	_status.edge = ThemeManager.status_position
	_style()
	_refresh()
	_tell_app_area()
	# The navigation app runs from the start, whatever page is restored; on home it shows in the
	# slot, with no phone yet.
	if ThemeManager.nav_app != "":
		_keep_nav.call_deferred()
		_show_app.call_deferred()


func _process(_delta: float) -> void:
	var t := Time.get_datetime_dict_from_unix_time(int(Clock.local()))
	_status.clock = "%02d:%02d" % [t.hour, t.minute]


func _draw() -> void:
	# A scene theme's 3D world shows through instead.
	if not ThemeManager.is_scene() and not _is_page(_page, "ev_live"):
		draw_rect(Rect2(Vector2.ZERO, size), ThemeManager.c.bg)


func _style() -> void:
	theme = ThemeManager.godot_theme
	if ThemeManager.is_scene() and _scene == null:
		_scene = SceneSkin.new()
		_scene.name = "Scene"
		_scene.surfaces = [_status, _stat, _precondition, _stop, _player, _handle.pill, _source]
		add_child(_scene)
		move_child(_scene, 0)
	elif not ThemeManager.is_scene() and _scene != null:
		_scene.queue_free()
		_scene = null
	if _scene:
		_scene.visible = _page == null
	# A pack that comes or goes changes who draws the live page's title bar.
	if _is_page(_page, "ev_live") and _live_bar != _own_bar():
		open_page("ev_live")
	var g: float = ThemeManager.px.gap
	for k in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		_side.add_theme_constant_override(k, roundi(g * 1.5))
	_update_source()
	var cards: HomeCards = _side.get_node("Panel")
	cards.gap = roundi(g * 1.5)
	cards.column = ThemeManager.px.side - roundi(g * 1.5) * 2
	cards.column_left = ThemeManager.side_left()
	cards.driver_left = _driver_left()
	cards.side_by_side = ThemeManager.home_layout == "split"
	_stat.vertical = cards.side_by_side
	_body.move_child(_side, 0 if ThemeManager.side_left() else 1)
	_resplit()
	_place_handle.call_deferred()
	# The page passes input through where the projection shows.
	$Page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()
	_fit_key = []
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
		# The slot toggle follows the bar's new shape.
		_update_source()
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
	# Riding the cards, the bar takes from their column only (its margin), not the body.
	if _riding():
		return r
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


## Home with the picture shown and the bar along the top or the bottom: the bar rides the cards'
## column, over or under them, and the picture has the panel's whole height. Left, right or off,
## the picture had it already.
func _riding() -> bool:
	return _status != null and _page_name == "home" and _split_to < 1.0 and _status.edge in ["top", "bottom"]


## Riding: the bar over the cards' column, as wide; where its row does not fit, the outside
## temperature goes, then the slot toggle's words (`_status_tight`).
func _place_status() -> void:
	if not _riding() or _placing_status:
		return
	_placing_status = true
	var t := _status_thickness()
	var side := _side.get_rect()
	_status.position = Vector2(_body.position.x + side.position.x, 0.0 if _status.edge == "top" else size.y - t)
	_status.size = Vector2(side.size.x, t)
	# Measured with the toggle's widths at each squeeze, whatever it shows now, so the choice
	# does not flip: the temperature goes, then the toggle's names are cut, then it is icons.
	var rest := func() -> float: return _status.get_combined_minimum_size().x - _status.source_size.x
	_status.narrow = false
	var level := 0
	if _source_in_bar:
		_status.narrow = rest.call() + _source_widths[0] > side.size.x
		while level < 2 and rest.call() + _source_widths[level] > side.size.x:
			level += 1
	else:
		_status.narrow = rest.call() > side.size.x
	if level != _status_tight:
		_status_tight = level
		_update_source()
	_placing_status = false


## Riding, how far the slot toggle is squeezed (SourceToggle.squeeze) to fit the bar's row.
var _status_tight := 0
var _placing_status := false
## The slot toggle's width at each squeeze.
var _source_widths: Array[float] = [0.0, 0.0, 0.0]


## The cards' margins: a band for the slot toggle with the bar off, room for the bar riding them.
func _side_margins(band: float) -> void:
	var m := roundi(ThemeManager.px.gap * 1.5)
	var t := roundi(_status_thickness()) if _riding() else 0
	var top := m + (t if _status.edge == "top" else 0)
	var bottom := m + roundi(band) + (t if _status.edge == "bottom" else 0)
	if _side.get_theme_constant("margin_top") != top or _side.get_theme_constant("margin_bottom") != bottom:
		_side.add_theme_constant_override("margin_top", top)
		_side.add_theme_constant_override("margin_bottom", bottom)
		_fit.call_deferred()


## Puts the status bar on its edge and the body in the rest, and the open page with it.
func _layout_status() -> void:
	if _status == null:
		return
	if not _riding():
		_status.narrow = false
		_status_tight = 0
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
	if _riding():
		_status.set_anchors_preset(Control.PRESET_TOP_LEFT)
		_place_status()
		_place_status.call_deferred()
	_update_source()
	if _page:
		_fit_page(_page)
	_place_next_frame()
	_place_source.call_deferred()


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
		if _is_page(page, "settings"):
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
		if _page != _ev_live:
			_page.free()
		_page = null
	# An app's menus close as a tap outside them would.
	if page != _page_name and Wayland.has_method("dismiss_popups"):
		Wayland.dismiss_popups(-1)
	if page == "projection" and _page_name != "projection":
		_return_to = _page_name
	if page == "settings" and _page_name != "settings":
		_settings_from = _page_name
	_page_name = page
	_edge.armed = page != "home"
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
	_show_charge()
	_update_source()
	if home and _cards_due:
		_bind_cards()
		_update_player()
	elif home and _fit_due:
		_fit.call_deferred()
	# Off home, the split is where it will be when home shows again.
	if not home and (_split_tween or _dragging):
		if _split_tween:
			_split_tween.kill()
		_split_tween = null
		_dragging = false
		_projection.window.hold = false
		_resplit()
	_projection.visible = _app_page or (home and _split < 1.0)
	# Every page change: leaving the full-panel pages puts the picture back in home's slot. The
	# slot's size is stale until the body, hidden till now, lays out: the phone is asked after.
	_place_projection(not home)
	_place_next_frame()
	if _scene:
		_scene.visible = home
	if live:
		var ev := _live_page()
		_fit_page(ev)
		_page = ev
		add_child(_page)
	elif page == "settings":
		var settings: Control = _page_script("settings").new()
		settings.back_pressed.connect(func(): open_page.call_deferred(_settings_from))
		settings.back_button = rail_width <= 0.0
		$Page.visible = true
		_fit_page(settings)
		_page = settings
		add_child(_page)
	elif page == "media":
		var media: Control = _page_script("media").new()
		media.now_playing = now_playing
		_fit_page(media)
		_page = media
		add_child(_page)
	elif page == "apps":
		var apps: Control = _page_script("apps").new()
		apps.launcher = launcher
		_fit_page(apps)
		_page = apps
		add_child(_page)
	elif not home and not _app_page:
		_page = _page_script("pack").new()
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
## focus there too (and the slot's picture exists only while it does), unless the slot shows the
## navigation app.
func _shows_projection() -> bool:
	return _on_projection() or (_page_name == "home" and ThemeManager.home_phone and slot_source() == "phone")


## Day or night as the core has it for the main screen's UI: the car's lights (its night mode,
## through the telemetry) unless LIVI's appearance setting is Day or Night. Checked on every
## look change too: under Auto, an appearance set directly would otherwise hold until the core's
## night mode next changes.
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
		if tab != "" and _is_page(_page, "media") and now_playing.receiver:
			_page.show_view(tab)
	else:
		print("core asks for %s: the shell has no such page" % path)


## The live EV page, built once and kept: building it is half a second on the unit, and a new
## one's materials would compile their shaders again on its first frame.
func _live_page() -> Control:
	if _ev_live == null:
		_ev_live = _page_script("ev_live").new()
		_ev_live.tile_pressed.connect(func(id): ev_action.emit(id))
		_ev_live.back_pressed.connect(func(): open_page.call_deferred("home"))
		_ev_live.back_button = rail_width <= 0.0
	elif _ev_live.get_parent():
		# Still in warm_up's viewport.
		_ev_live.get_parent().remove_child(_ev_live)
	return _ev_live


## Builds the live page and draws it once, offscreen at its size, so it, its shaders and its
## glyphs are ready before the first visit: on the unit's GPU that is seconds, which would
## otherwise stall the first tap. Again once the look settles after a change (day and night
## follow the car's lights) while the page is away, so the next visit does not restyle it.
func warm_up() -> void:
	if _rewarm == null:
		_rewarm = Timer.new()
		_rewarm.one_shot = true
		_rewarm.wait_time = REWARM_S
		_rewarm.timeout.connect(warm_up)
		add_child(_rewarm)
		ThemeManager.changed.connect(func(): if not _ev_live.is_inside_tree(): _rewarm.start())
	if _ev_live != null and _ev_live.is_inside_tree():
		return
	var t0 := Time.get_ticks_msec()
	var vp := SubViewport.new()
	vp.size = Vector2i(size)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# Its own world: the page's environment stays out of a scene theme's home.
	vp.own_world_3d = true
	add_child(vp)
	vp.add_child(_live_page())
	var line := "[warm] built %d ms, frames at" % (Time.get_ticks_msec() - t0)
	for i in 3:
		await RenderingServer.frame_post_draw
		line += " %d" % (Time.get_ticks_msec() - t0)
	if OS.get_environment("LIVI_SHELL_TIMING") != "":
		launcher._log(line)
	if _ev_live.get_parent() == vp:
		vp.remove_child(_ev_live)
	vp.queue_free()


## Whether the active pack draws the live page's title bar itself: it has the stock layout.
func _own_bar() -> bool:
	return not _page_script("ev_live").pack_layout().is_empty()


static func _page_script(id: String) -> GDScript:
	return load(PAGE_SCRIPTS[id])


## `page is <id's class>`, without loading the class.
static func _is_page(page: Object, id: String) -> bool:
	return page != null and page.get_script() != null and page.get_script().resource_path == PAGE_SCRIPTS[id]


func _place_projection(ask := true) -> void:
	if _projection == null:
		return
	var r := _slot_rect()
	if _app_page:
		r = Rect2(Vector2.ZERO, size)
		var kw := 0.0 if _projection_page else _keyboard_width()
		r.size.x -= kw
		if _driver_left():
			r.position.x += kw
	elif ThemeManager.floating() and not _slot_nav():
		# Under the floating panel: the whole projection screen, 1:1 with the panel, under a docked
		# rail too; the shell's own rect would scale it into the rest. The navigation app keeps the
		# slot: its own controls would be under the cards.
		r = Rect2(get_viewport_rect().position - global_position, get_viewport_rect().size)
	_projection.position = r.position
	_projection.size = r.size
	# The picture follows the slot every frame; the phone, or the navigation app, is asked for
	# where it settles.
	if ask and _split_tween == null and not _dragging:
		_ask_area()
		_size_nav()


## Once this frame's deferred layout passes (minimum size, then sort) have run.
func _place_next_frame() -> void:
	if is_inside_tree() and not get_tree().process_frame.is_connected(_place_projection):
		get_tree().process_frame.connect(_place_projection, CONNECT_ONE_SHOT)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _side:
		_layout_status()
		_resplit()
		_place_keyboard()
	elif what == NOTIFICATION_PREDELETE and _ev_live and not _ev_live.is_inside_tree():
		_ev_live.free()


## Opens home's slot while there is a phone's picture, else gives the cards the whole width:
## animated on home, at once elsewhere or under reduced motion.
func _update_split() -> void:
	var phone := has_phone()
	var present := phone or nav_app() != ""
	if present != _slot_present:
		_slot_present = present
		_handle.visible = present
		_resplit()
		_place_handle.call_deferred()
	if phone != _phone_present:
		_phone_present = phone
		phone_changed.emit(phone)
	# The driver can keep home to the cards while a phone is connected (Look → Phone on home).
	var want := 0.0 if present and ThemeManager.home_phone else 1.0
	_slide(want, _side_target(want))
	_update_source()


## The phone's widths home snaps to: about a third, a half and two thirds of the body, none
## narrower than the cards' column nor leaving the cards less than it. Android Auto takes any
## area (a phone that refuses one is letterboxed), so the cards set the limits. The picture comes
## first on its own: with no choice in the look (`_phone_width`) the cards take no more than
## SIDE_SHARE (side by side SIDE_SHARE_SPLIT).
func _snaps() -> Array[float]:
	var full := _rect_beside_status().size.x
	var lo: float = ThemeManager.px.side
	var hi := maxf(lo, full - lo)
	var out: Array[float] = []
	for f in [1.0 / 3.0, 0.5, 2.0 / 3.0]:
		var w := roundf(clampf(full * f, lo, hi))
		if out.is_empty() or w - out.back() >= ThemeManager.px.touch:
			out.append(w)
	return out


## The most of home's body the cards take beside the picture by default, in each layout.
const SIDE_SHARE := 1.0 / 3.0
const SIDE_SHARE_SPLIT := 0.5


## The phone's width while shown: the snap nearest the look's share; by default the narrowest that
## leaves the cards no more than their layout's share.
func _phone_width() -> float:
	var snaps := _snaps()
	var full := _rect_beside_status().size.x
	if ThemeManager.home_split <= 0.0:
		var share := SIDE_SHARE_SPLIT if ThemeManager.home_layout == "split" else SIDE_SHARE
		var most := maxf(ThemeManager.px.side, roundf(full * share))
		for s in snaps:
			if full - s <= most + 0.5:
				return s
		return snaps.back()
	var want: float = ThemeManager.home_split * full
	var best: float = snaps[0]
	for s in snaps:
		if absf(s - want) < absf(best - want):
			best = s
	return best


func _side_target(want: float) -> float:
	var full := _rect_beside_status().size.x
	return full if want == 1.0 else full - _phone_width()


## The split where the look puts it, unless it is moving.
func _resplit() -> void:
	if _split_tween == null and not _dragging:
		_side_to = _side_target(_split_to)
		_set_side(_side_to)


## To the cards' width `to` (`want` 1: no phone), animated on home, at once elsewhere or under
## reduced motion.
func _slide(want: float, to: float) -> void:
	if want == _split_to and is_equal_approx(to, _side_to):
		return
	var rode := _riding()
	_split_to = want
	_side_to = to
	_slides += 1
	if _riding() != rode:
		_layout_status()
	if _split_tween:
		_split_tween.kill()
		_split_tween = null
	if ThemeManager.reduced_motion or _page_name != "home" or not is_visible_in_tree():
		_fit.call_deferred()
		_set_side(to)
		_split_settled()
		return
	_start_slide.call_deferred(_slides, _side_w, to)


## Once this frame's changes are in (the toggle's band under the cards too): the cards fitted
## once, laid out at the width they go to, and the slide only moves them; the phone or the
## navigation app asked for that width now, its new picture on its way meanwhile.
func _start_slide(n: int, from: float, to: float) -> void:
	if n != _slides:
		return
	_set_side(to)
	# Twice: the first fit's looks change the cards' minimum, and so the room the second sees.
	for i in 2:
		_body.notification(Container.NOTIFICATION_SORT_CHILDREN)
		_side.notification(Container.NOTIFICATION_SORT_CHILDREN)
		_fit()
	_projection.visible = true
	_split_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_split_tween.tween_method(_set_side, from, to, SPLIT_S)
	_split_tween.finished.connect(_split_settled)
	_set_side(from)
	_ask_area()
	_size_nav()


## The cards `w` wide and the slot the rest. Past the narrowest phone they blend into the
## dashboard (`_split` 1); before it they are one column filling the side.
func _set_side(w: float) -> void:
	var full := _rect_beside_status().size.x
	var least := full - _snaps()[0]
	_side_w = w
	_side.custom_minimum_size.x = w
	_split = clampf(inverse_lerp(least, full, w), 0.0, 1.0) if full > least else 1.0
	var cards: HomeCards = _side.get_node("Panel")
	var m: float = _side.get_theme_constant("margin_left") * 2.0
	# A drag or a slide shows the column or the dashboard, never a blend, whose cards cross
	# mid-way; the column fills the side, its edge with the picture's.
	var moving := _dragging or _split_tween != null
	cards.wide = roundf(_split) if moving else _split
	cards.column = maxf(0.0, (w if moving and cards.wide == 0.0 else lerpf(minf(w, least), ThemeManager.px.side, _split)) - m)
	_place_handle()
	_place_status()
	_place_source()
	if app_keyboard:
		_place_keyboard()


## The handle dragged `dx` since the press: the divider follows the finger, the picture stretched
## to the slot meanwhile, the phone not asked until the release.
func _on_handle_drag(dx: float) -> void:
	if not _dragging:
		_dragging = true
		_drag_w0 = _side_w
		if _split_tween:
			_split_tween.kill()
			_split_tween = null
		if _page_name == "home":
			_projection.visible = true
		_projection.window.hold = true
	var full := _rect_beside_status().size.x
	var w := _drag_w0 + (dx if ThemeManager.side_left() else -dx)
	_set_side(clampf(roundf(w), full - _snaps().back(), full))


## Released: to the nearest snap, or none (the slot's edge), kept in the look.
func _on_handle_release() -> void:
	if not _dragging:
		return
	_dragging = false
	var full := _rect_beside_status().size.x
	var phone := full - _side_w
	var best := 0.0
	for s in _snaps():
		if absf(s - phone) < absf(best - phone):
			best = s
	# Slides there (`_update_split`) with the look already kept, so the phone is asked at once.
	_side_to = -1.0
	var look := {home_phone = best > 0.0}
	if best > 0.0:
		look.home_split = best / full
	_keep_split(look)


## A double tap: the phone back at the default width, from any width or hidden.
func _on_handle_reset() -> void:
	if not _slot_present:
		return
	_keep_split({home_phone = true, home_split = 0.0})


## Kept in the look without restyling everything (`ThemeManager.apply`): only home reads them.
func _keep_split(look: Dictionary) -> void:
	for k in look:
		ThemeManager.set(k, look[k])
	ThemeManager.save_look()
	_update_split()
	_tell_front()


func _split_settled() -> void:
	_split_tween = null
	if _page_name == "home":
		_projection.visible = _split < 1.0
	# A slot that closed is asked for again when it opens, whatever it was before.
	if _split_to == 1.0:
		_area_asked = Rect2i()
		_projection.window.hold = false
	_place_next_frame()
	_projection.window.release_hold()
	# What changed meanwhile.
	_fit.call_deferred()


## The handle's pill centred in the side's margin toward the slot (the gutter, as wide as the
## cards' own margin), becoming a tab against the content's edge as the slot closes. Its target
## overlaps the slot and the cards rather than taking width from either.
func _place_handle() -> void:
	if _handle == null or not _handle.visible:
		return
	var touch: float = ThemeManager.px.touch
	var left := ThemeManager.side_left()
	var content := _body.get_global_rect()
	var side := _side.get_global_rect()
	var m := float(_side.get_theme_constant("margin_right" if left else "margin_left"))
	var t := clampf(_split, 0.0, 1.0)
	var pw := maxf(4.0, roundf(touch * 0.065))
	var tw := maxf(pw, roundf(m * 0.45))
	var w := roundf(lerpf(pw, tw, t))
	var gutter := side.end.x - m if left else side.position.x
	# From the slot's edge: a tab as the slot closes, under the finger all the way.
	var x := roundf(gutter + lerpf((m - pw) / 2.0, m - w if left else 0.0, t))
	var h := roundf(touch * 0.8)
	var pill := Rect2(x, roundf(content.get_center().y - h / 2.0), w, h)
	_handle.pill.tab = t
	_handle.pill.edge_left = not left
	_handle.place(pill, touch, content)


## A projection video window (Android Auto or CarPlay streaming) is mapped.
func has_phone() -> bool:
	return _windows.any(_is_projection)


## The navigation app (Settings → Look, or its tile's menu) while the launcher lists it, else "".
func nav_app() -> String:
	var id := ThemeManager.nav_app
	if id == "":
		return ""
	if launcher.apps.is_empty() and not _apps_scanned:
		_apps_scanned = true
		launcher.refresh()
	return id if not launcher.app(id).is_empty() else ""


## What home's slot shows: "phone" (the projection) or "nav" (the navigation app). The look's
## choice while both are there, else whichever is.
func slot_source() -> String:
	if nav_app() == "":
		return "phone"
	if not has_phone():
		return "nav"
	return "nav" if ThemeManager.home_source == "nav" else "phone"


## Home with the navigation app in its slot.
func _slot_nav() -> bool:
	return _page_name == "home" and slot_source() == "nav"


## The navigation app's newest window, or -1.
func _nav_window_id() -> int:
	var id := nav_app()
	var mine: Array = launcher.windows_of(id) if id != "" else []
	return mine[-1] if not mine.is_empty() else -1


## The toggle's segment tapped: kept in the look, which shows it (`_on_nav_look`).
func _pick_source(source: String) -> void:
	if source == "nav":
		# Again after a launch that failed or the driver's close: they asked for it.
		launcher.failed.erase(nav_app())
		launcher.user_closed.erase(nav_app())
	ThemeManager.set_look({home_source = source})
	ThemeManager.save_look()
	_keep_nav(true)
	_show_app()


## The navigation app or the slot's choice changed: the slot shows the other, the phone keeps
## video focus only while it is the one shown, and is asked for the slot again when it comes back.
func _on_nav_look() -> void:
	var now := [ThemeManager.nav_app, ThemeManager.home_source]
	if now == _nav_seen:
		return
	_nav_seen = now
	launcher.failed.erase(ThemeManager.nav_app)
	launcher.user_closed.erase(ThemeManager.nav_app)
	_keep_nav(true)
	_show_app()
	_tell_front()
	_ask_area(true)


## Keeps the navigation app running while it is designated, quietly (no app page): started once
## the launcher lists it, whatever page shows, and again after an exit the driver did not ask for
## (their close from the switcher), after `NAV_RETRY_S`. `now`: the wait is over, or the driver
## asked for it.
func _keep_nav(now := false) -> void:
	var id := nav_app()
	if id == "":
		_nav_kept = ""
		_nav_retry.stop()
		return
	var state := launcher.state(id)
	if state == "running":
		if _nav_kept != id:
			_nav_kept = id
			_nav_restarts = 0
		if _nav_up_ms == 0:
			_nav_up_ms = Time.get_ticks_msec()
		return
	if state == "launching" or launcher.user_closed.has(id):
		return
	if _nav_kept != id:
		# Designated (or at start): now.
		_nav_kept = id
		_nav_restarts = 0
	elif not now:
		# Gone: again after a wait, shorter once it had run a while.
		if not _nav_retry.is_stopped():
			return
		if _nav_up_ms > 0 and Time.get_ticks_msec() - _nav_up_ms >= NAV_STABLE_S * 1000.0:
			_nav_restarts = 0
		_nav_up_ms = 0
		var wait: float = NAV_RETRY_S[mini(_nav_restarts, NAV_RETRY_S.size() - 1)]
		_nav_restarts += 1
		launcher._log("launcher: %s, the navigation app, %s: again in %d s" % [id, "failed" if state == "failed" else "exited", wait])
		_nav_retry.start(wait)
		return
	_nav_up_ms = 0
	launcher.failed.erase(id)
	launcher.open(id, false)


## The slot toggle is in the status bar (`_update_source`).
var _source_in_bar := false


## The toggle shows on home while the phone and the navigation app are both there and the slot
## is open: in the status bar in place of the phone's name, or with the bar off in a band that is
## the side's bottom margin, so the cards fit above it, the tall player too.
func _update_source() -> void:
	if _source == null:
		return
	var nav := nav_app()
	var shown := nav != "" and has_phone() and ThemeManager.home_phone
	if shown:
		_source.nav_name = str(launcher.app(nav).get("name", nav))
		_source.phone_name = _status.phone
		_source.source = slot_source()
	_source.visible = shown and _page_name == "home"
	_source_in_bar = _source.visible and ThemeManager.status_position != "off"
	_source.vertical = _source_in_bar and _status.vertical()
	for i in 3:
		_source.squeeze = i
		_source_widths[i] = _source.get_combined_minimum_size().x
	_source.squeeze = _status_tight if _source_in_bar and _riding() else 0
	_status.source_size = _source.get_combined_minimum_size() if _source_in_bar else Vector2.ZERO
	var band := shown and ThemeManager.status_position == "off"
	var m := roundi(ThemeManager.px.gap * 1.5)
	_side_margins(_source.get_combined_minimum_size().y + m if band else 0.0)
	_place_source()
	_place_source.call_deferred()


## Over its slot in the status bar; with the bar off, at the bottom of the cards' column on the
## slot's side.
func _place_source() -> void:
	if _source == null or not _source.visible:
		return
	if _source_in_bar:
		if _status.source_slot:
			_source.size = _source.get_combined_minimum_size()
			_source.global_position = _status.source_slot.get_global_rect().position.round()
		return
	var side := _side.get_global_rect()
	var m := float(roundi(ThemeManager.px.gap * 1.5))
	var s := _source.get_combined_minimum_size()
	s.x = minf(s.x, side.size.x - m * 2.0)
	var x := side.end.x - m - s.x if ThemeManager.side_left() else side.position.x + m
	var panel: HomeCards = _side.get_node("Panel")
	# Side by side: under the media column, from its edge.
	if panel.side_by_side and panel.below > 0.0:
		var col := panel.side_column()
		s.x = minf(s.x, col.y)
		x = panel.global_position.x + col.x
	_source.size = s
	_source.global_position = Vector2(x, side.end.y - m - s.y).round()
	# Precondition, one line, at the band's other end when the cards had no room for it.
	if _precondition.top_level and _precondition.visible:
		var w := _precondition.compact_width(not _precondition.icon_only)
		var px := side.position.x + m if ThemeManager.side_left() else side.end.x - m - w
		_precondition.size = Vector2(w, s.y)
		_precondition.global_position = Vector2(px, side.end.y - m - s.y).round()


## What of the one-line Precondition the band under the cards holds beside the pill: "words",
## "icon" (and Auto), or "" (nothing).
func _band_room() -> String:
	if _source == null or not _source.visible or _source_in_bar:
		return ""
	var m := float(roundi(ThemeManager.px.gap * 1.5))
	var free: float = _side.size.x - m * 2.0 - _source.get_combined_minimum_size().x - ThemeManager.px.gap
	return "words" if free >= _precondition.compact_width(true) else "icon" if free >= _precondition.compact_width(false) else ""


## The navigation app's window is configured to where it shows: home's slot (once the split
## settles, as the phone is asked) or the app page's area, as any hosted app. Elsewhere it keeps
## the last.
func _size_nav() -> void:
	var nav := _nav_window_id()
	# No longer the navigation app's: the app area again.
	if _nav_window >= 0 and _nav_window != nav:
		Wayland.set_window_area(_nav_window, 0, 0)
		_nav_window = -1
	if nav < 0 or _projection.window.window_id != nav:
		return
	if _page_name == "app":
		Wayland.set_window_area(nav, 0, 0)
		_nav_window = -1
	elif _slot_nav() and not _dragging and _slot_settled().size.x >= 1.0:
		var s := _slot_rect(true)
		Wayland.set_window_area(nav, roundi(s.size.x), roundi(s.size.y))
		_nav_window = nav


## Home's slot, global, where a slide leaves it.
func _slot_settled() -> Rect2:
	if _split_tween == null:
		return _slot.get_global_rect()
	# The content's rect, not the body's: mid-change the cards' minimum may stretch the body.
	var r := _rect_beside_status()
	r.position += global_position
	r.size.x = maxf(0.0, r.size.x - _side_to)
	if ThemeManager.side_left():
		r.position.x += _side_to
	return r


## The last area asked of the phone, in the projection screen's pixels.
var _area_asked := Rect2i()


## Android Auto lays its UI out where the page shows it: home's slot (under a floating panel too),
## else the whole panel. A phone that does not take it is letterboxed (`WindowView`).
func _ask_area(again := false) -> void:
	if not _shows_projection():
		return
	var a: Rect2i = _projection.window.to_screen(_slot_settled() if _page_name == "home" else get_global_rect())
	if a.size.x <= 0 or a.size.y <= 0 or (a == _area_asked and not again):
		return
	_area_asked = a
	Core.act({kind = "projectionArea", screen = "main", x = a.position.x, y = a.position.y, width = a.size.x, height = a.size.y})


## The status bar's charge, unless home's battery card shows it.
func _show_charge() -> void:
	_status.charge_shown = not _stat.is_visible_in_tree()


## Side by side: Precondition one line in the battery column's foot (its icon where its words
## don't fit), the column down beside the Phone | <app> pill, as wide as its widest part.
func _fit_side_by_side(panel: HomeCards, fits: Callable, inside: Callable) -> void:
	_precondition.compact = true
	inside.call(_precondition.visible)
	var pad: float = _stat.get_theme_stylebox("panel").get_minimum_size().x
	var widen := func() -> void:
		panel.host_width = ceilf(maxf(ThemeManager.px.touch * HOST_TOUCH, maxf(_stat.get_combined_minimum_size().x, _precondition.compact_width(false) + pad)))
		_precondition.icon_only = _precondition.compact_width(true) + pad > panel.host_width
		panel.sync_foot()
	widen.call()
	# The media card's controls want the width: the battery's type smaller first.
	var narrow := func() -> bool: return panel.side_column().y - _player.get_theme_stylebox("panel").get_minimum_size().x < _player._buttons_width(2, ThemeManager.px.touch)
	if narrow.call():
		_stat.compact = true
		widen.call()
	# Under the media column where it fits there, else across the foot as in the stack.
	if _source.visible and not _source_in_bar and _source.get_combined_minimum_size().x <= panel.side_column().y:
		panel.below = _side.get_theme_constant("margin_bottom") - roundf(ThemeManager.px.gap * 1.5)
	if not fits.call():
		_stat.compact = true


## The battery column's least width side by side, in touch targets.
const HOST_TOUCH := 2.6


## Shows every item that has content, then drops the least important until the rest fit.
func _fit() -> void:
	if not _body.is_visible_in_tree():
		_fit_due = true
		return
	# A drag or a slide only places the cards at their looks: `_slide` fits them at its end width.
	if _dragging or _split_tween:
		return
	_fit_due = false
	var panel: HomeCards = _side.get_node("Panel")
	var dashboard := _split_to == 1.0
	var electric := _powertrain() == "electric"
	var wanted := {Stat = true, Precondition = electric, Stop = electric and _stop.has_content(), Player = true}
	# The screen's height, not the panel's: the panel grows with what it holds.
	var room: float = _rect_beside_status().size.y \
		- _side.get_theme_constant("margin_top") - _side.get_theme_constant("margin_bottom")
	# Telemetry refits several times a second, mostly with nothing the fit reads changed; a refit
	# restyles every card twice over.
	# Widths only: the room is the height, and the side's own runs past it while the cards that
	# made it too tall wait for this fit.
	var key := [room, _side.size.x, panel.size.x, dashboard, wanted, panel.side_by_side, _source.visible and not _source_in_bar, Vector2.ZERO if _source_in_bar else _source.get_combined_minimum_size(),
		_stat.value, _stat.unit, _stat.sub_label, _stat.sub_value, _stat.icon_name,
		_precondition.label, _precondition.short_label, _precondition.detail, _stop.stop,
		_player.title, _player.artist, _player.album, _player.initials, _player.show_position, _player.art,
		_player.has_content()]
	if key == _fit_key:
		return
	_fit_key = key
	fits += 1
	for n in PRIORITY:
		panel.get_node(n).visible = wanted[n]
	left_out.clear()
	# Before any card goes: Precondition inside the battery card, then one line, then beside the
	# Phone | <app> pill (an icon where its words don't fit), then the battery card compact, then
	# the media card one row without prev.
	var fits := func() -> bool: return panel.needed(dashboard) <= room + 1.0
	var inside := func(on: bool) -> void:
		_precondition.inset = on
		panel.foot = _precondition if on else null
		panel.sync_foot()
	_precondition.compact = false
	_precondition.top_level = false
	_precondition.icon_only = false
	inside.call(false)
	_stat.compact = false
	_player.allow_two_rows = true
	panel.below = 0.0
	if panel.side_by_side:
		_fit_side_by_side(panel, fits, inside)
	# Nothing playing, the media card is the first to go.
	if not fits.call() and not _player.has_content() and not panel.side_by_side:
		_player.visible = false
		left_out.append("Player")
	if not fits.call() and _precondition.visible and not panel.side_by_side:
		inside.call(true)
	if not fits.call() and _precondition.visible:
		_precondition.compact = true
		panel.sync_foot()
	if not fits.call() and _precondition.visible and _band_room() != "" and not panel.side_by_side:
		inside.call(false)
		_precondition.icon_only = _band_room() == "icon"
		_precondition.top_level = true
	if not fits.call():
		_stat.compact = true
	# Side by side the media card has its column whatever the battery's needs.
	if not fits.call() and _player._choose()[0] == "two" and not panel.side_by_side:
		_player.allow_two_rows = false
	_place_source()
	var order := PRIORITY.duplicate()
	order.reverse()
	for n in order:
		var need := panel.needed(dashboard)
		# Fractions of a pixel: the cards' heights are not whole.
		if need <= room + 1.0:
			break
		var item: Control = panel.get_node(n)
		if item == _player or item.top_level:
			continue
		if item.visible:
			item.visible = false
			panel.sync_foot()
			# The hero beside a too-tall stack: leaving it out would not make the stack fit.
			if panel.needed(dashboard) >= need:
				item.visible = true
				panel.sync_foot()
				continue
			left_out.append(n)
	# Trying a card's larger look grows it to that look's minimum at once; a fit that ends where
	# it began changes no minimum, so nothing would shrink it back.
	panel.queue_sort()
	_show_charge()
	var said := "left out %s; it holds %d px" % [", ".join(left_out), roundi(room)] if not left_out.is_empty() else ""
	if said != _left_out_said:
		_left_out_said = said
		if said != "":
			print("side panel: " + said)


func _on_window_unmapped(id: int) -> void:
	var app_id: String = _app_ids.get(id, "")
	_windows.erase(id)
	_app_ids.erase(id)
	# The app page's app gone (its last window: a dialog closing leaves it): back to the grid it
	# came from, not to another running app or the phone's video.
	var shown: bool = _projection.window.window_id == id
	var gone := shown and (app_id == "" or not _windows.any(func(w): return _app_ids.get(w, "") == app_id))
	if _page_name == "app" and (gone or not _windows.any(func(w): return not _is_projection(w))):
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
	var id := -1
	if _slot_nav():
		# One window in one place: the navigation app's moves here from the app page. `_keep_nav`
		# starts it.
		id = _nav_window_id()
	else:
		# Home's slot is otherwise the phone's: a hosted app is the app page's.
		var phone := _projection_page or _page_name == "home"
		var shown: Array = _windows.filter(_is_projection) if phone else _windows.filter(func(w): return not _is_projection(w)) if _page_name == "app" else Array(_windows)
		id = shown[-1] if not shown.is_empty() else -1
	_projection.show_window(id, id >= 0 and _is_projection(id))
	_pace_windows()
	_size_nav()
	# The keyboard types into the app showing, on its page only.
	if app_keyboard and (not _typing_page() or app_keyboard.window_id != id):
		app_keyboard.close()
	_update_keys_button()


## Hosted windows off screen get no frame callbacks, so a hidden app (the navigation app behind
## the phone, one left running off the app page) does not keep drawing on the shared GPU. The
## phone's video keeps its pace: its stream is the core's to stop.
func _pace_windows() -> void:
	var drawn := _projection.window.window_id if _projection.is_visible_in_tree() else -1
	for w in _windows:
		Wayland.set_window_paused(w, w != drawn and not _is_projection(w))


func _driver_left() -> bool:
	return ThemeManager.hand != "rhd"


## What the app page's keyboard takes of its width; on home it covers the cards instead.
func _keyboard_width() -> float:
	return roundf(size.x * APP_KEYBOARD_SHARE) if app_keyboard and not app_keyboard.closing() and _page_name == "app" else 0.0


## The pages a hosted app is typed into: the app page, and home with the navigation app.
func _typing_page() -> bool:
	return _page_name == "app" or _slot_nav()


## Over the cards on home, beside the navigation app; else full height on the driver's side of
## the shell's rect.
func _keyboard_rect() -> Rect2:
	var kw := roundf(size.x * APP_KEYBOARD_SHARE)
	if _page_name == "home":
		# The cards' column is too narrow for the keys: at least the app page's share, into the
		# slot, whose app is configured to the rest (`_slot_rect`).
		var side := Rect2(_side.get_global_rect().position - global_position, _side.size)
		kw = maxf(side.size.x, kw)
		return Rect2(side.position.x if ThemeManager.side_left() else side.end.x - kw, side.position.y, kw, side.size.y)
	return Rect2(0.0 if _driver_left() else size.x - kw, 0.0, kw, size.y)


## Home's slot, less what the keyboard takes of it.
func _slot_rect(settled := false) -> Rect2:
	var r := (_slot_settled() if settled else _slot.get_global_rect())
	r.position -= global_position
	if _page_name != "home" or app_keyboard == null or app_keyboard.closing():
		return r
	var k := _keyboard_rect()
	if ThemeManager.side_left():
		var cut := clampf(k.end.x - r.position.x, 0.0, r.size.x)
		r.position.x += cut
		r.size.x -= cut
	else:
		r.size.x -= clampf(r.end.x - k.position.x, 0.0, r.size.x)
	return r


## A hosted app showing on the app page, or the navigation app in home's slot, wants text: the
## keyboard comes up for it. Never for the phone's picture, whose own keyboard is on the phone's UI.
func _on_text_wanted(id: int) -> void:
	print("keyboard: window %d (%s) wants text: %s" % [id, _app_ids.get(id, ""), Wayland.text_field(id)])
	if not _typing_page() or _projection.window.window_id != id or _is_projection(id):
		return
	var t0 := Time.get_ticks_usec()
	var was := app_keyboard
	var ready := is_instance_valid(_spare_keyboard)
	open_keyboard(id, Wayland.text_field(id))
	if app_keyboard != was:
		_time_keyboard(t0, ready)


## LIVI_SHELL_TIMING: from the field's ask (the frame its enable arrived) to the keyboard built,
## first drawn, and in place.
func _time_keyboard(t0: int, ready: bool) -> void:
	if OS.get_environment("LIVI_SHELL_TIMING") == "":
		return
	var ms := func() -> float: return (Time.get_ticks_usec() - t0) / 1000.0
	var line := "[keyboard] %s %.1f ms" % ["shown (built ahead)" if ready else "built", ms.call()]
	var k := app_keyboard
	await RenderingServer.frame_post_draw
	line += ", first frame %.1f ms" % ms.call()
	while is_instance_valid(k) and k.moving():
		await get_tree().process_frame
	launcher._log(line + ", in place %.1f ms" % ms.call())


## The keyboard for window `id`'s `field` (as `Wayland.text_field` gives it; empty: keys only).
func open_keyboard(id: int, field: Dictionary) -> void:
	if app_keyboard and app_keyboard.window_id == id and not app_keyboard.closing():
		return
	# The one built ahead, hidden, if it is there: a keyboard's buttons take a frame or more.
	var k := _spare_keyboard if is_instance_valid(_spare_keyboard) else AppKeyboard.new()
	_spare_keyboard = null
	k.closed.connect(_on_keyboard_closed.bind(k))
	if k.get_parent() == self:
		move_child(k, -1)
	else:
		add_child(k)
	k.name = "AppKeyboard"
	k.visible = true
	k.set_process(true)
	# The next, once this one is in.
	get_tree().create_timer(1.0).timeout.connect(_prepare_keyboard)
	# No typing while the car is driven.
	var lock := DriveCover.new()
	lock.typing = true
	lock.dismissed.connect(k.close)
	k.add_child(lock)
	app_keyboard = k
	k.terminal = _terminal(id)
	k.configure(id, field)
	_place_keyboard()
	# On home from the cards' edge.
	k.slide_in(k.position.x, ThemeManager.side_left() if _page_name == "home" else _driver_left())
	_tell_app_area()
	_place_projection(false)
	_size_nav()
	_update_keys_button()


## A keyboard built and kept hidden for the next field, so it shows the frame it is asked for.
func _prepare_keyboard() -> void:
	if is_instance_valid(_spare_keyboard) or not is_inside_tree():
		return
	var k := AppKeyboard.new()
	k.name = "SpareKeyboard"
	k.visible = false
	k.set_process(false)
	add_child(k)
	# Sized as it will show, so its keys are laid out for it.
	k.size = Vector2(roundf(size.x * APP_KEYBOARD_SHARE), size.y)
	_spare_keyboard = k


func _on_keyboard_closed(_submitted: bool, k: AppKeyboard) -> void:
	# Its name is the next one's, while it slides out.
	k.name = "ClosingKeyboard"
	if app_keyboard == k:
		app_keyboard = null
	_tell_app_area()
	_place_projection(false)
	_size_nav()
	_update_keys_button()


## At `_keyboard_rect`, beside a docked rail.
func _place_keyboard() -> void:
	if app_keyboard == null or app_keyboard.closing():
		return
	var r := _keyboard_rect()
	app_keyboard.size = r.size
	if not app_keyboard.moving():
		app_keyboard.position = r.position
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
	print("keyboard: by the keys button for window %d (%s), text input %s" % [id, _app_ids.get(id, ""), "bound" if Wayland.has_text_input(id) else "not bound"])
	# A client that bound text input since the button showed: its field, if enabled.
	open_keyboard(id, Wayland.text_field(id))


## A terminal: its launcher entry says TerminalEmulator, or its app_id is a known one.
func _terminal(id: int) -> bool:
	var owner: Dictionary = launcher.windows.get(id, {})
	return bool(launcher.app(str(owner.get("app", ""))).get("terminal", false)) or AppKeyboard.terminal_app(str(_app_ids.get(id, "")))


## livi-output names its video windows livi-video; their touches are the phone's.
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


## What home's cards and the status bar read.
const CARD_READS := ["telemetry", "config", "precondition", "navigation"]
## The cards were left stale off home (`_refresh`), or unfitted (`_fit`).
var _cards_due := false
var _fit_due := false


## `sections` are the changed ones; empty means all.
func _refresh(sections := {}) -> void:
	if sections.is_empty() or sections.has("front"):
		_follow_front()
	if sections.is_empty() or sections.has("config"):
		_follow_night()
	if not sections.is_empty() and not CARD_READS.any(func(r): return sections.has(r)):
		return
	var t := func(p: String): return Core.get_value("/telemetry/" + p)
	# fuelPct is the charge for an electric car and the tank otherwise.
	var power := _powertrain()
	var soc = t.call("fuelPct")
	var amb = t.call("ambientC")
	_status.outside = "" if amb == null else Units.temperature(amb)
	_status.charge = "" if soc == null else "%d %%" % roundi(soc)
	_status.charge_icon = "bolt" if power == "electric" else "fuel"
	_status.phone = "Pixel"
	# Off home, telemetry streaming in would lay the hidden cards out again and again, at the cost
	# of every other page's frames (the unit's CPU): they catch up when home shows.
	if not _body.is_visible_in_tree():
		_cards_due = true
		return
	_bind_cards()


func _bind_cards() -> void:
	_cards_due = false
	var t := func(p: String): return Core.get_value("/telemetry/" + p)
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

	var on := _preconditioning()
	var auto: AutoChip = _precondition.trailing
	var allowed: bool = Core.get_value("/config/batteryPreconditioning") != "off"
	var state = t.call("preconditionState")
	var why = t.call("preconditionWhy")
	var mins = Core.get_value("/config/batteryPreconditioningManualMinutes")
	var detail := "for %d min" % (int(mins) if mins != null else 30)
	var stop = Core.get_value("/navigation/chargingStop")
	_precondition.set_pressed_no_signal(on)
	# Off in LIVI's settings is off for the manual request too (the core refuses it).
	_precondition.disabled = not allowed and not on
	_precondition.label = "Warming battery" if on else "Precondition battery"
	_precondition.short_label = "Warming" if on else "Precondition"
	if on:
		detail = "on"
	elif state == "running" and stop is Dictionary:
		_precondition.label = "Warming for charger"
		_precondition.short_label = "Warming"
		detail = "%d kW · %s" % [int(stop.get("powerW", 0) / 1000), Units.range_text(float(stop.get("distanceM", 0)) / 1000.0)]
	elif state == null:
		detail += " · no auto"
	elif not allowed:
		detail = "off in settings"
	elif stop is Dictionary and why is String and why != "":
		detail = "auto: " + why.trim_prefix("the charger is ")
	# The car's own word: conditioning it runs unasked, why it would not, its mode while asked.
	var cond_err := CarStatus.conditioning_error(t.call("batteryConditioningError"))
	var cond_mode = t.call("batteryConditioningMode")
	if t.call("batteryConditioning") == true and not on and state != "running":
		_precondition.label = "Warming battery"
		_precondition.short_label = "Warming"
		detail = "by the car"
	if cond_err != "":
		detail = cond_err
	elif on and t.call("batteryConditioning") == true:
		detail = "running"
	elif on and cond_mode is String:
		detail = "car mode " + cond_mode
	# Off in settings stays switchable even when the car link reports nothing.
	auto.disabled = state == null and allowed
	auto.set_pressed_no_signal(allowed)
	auto._style()
	_precondition.detail = detail
	_precondition._style()

	if stop is Dictionary:
		var cap = t.call("batteryCapacityKwh")
		if stop.get("arrivalWh") != null and cap:
			stop.arrivalPct = stop.arrivalWh / (cap * 10.0)
		_stop.stop = stop

	_fit.call_deferred()


## Home's player: the phone's track, or the radio station on air.
func _update_player() -> void:
	if not _body.is_visible_in_tree():
		_cards_due = true
		return
	var np := now_playing
	var band: Dictionary = np.dab if np.on_air() == "dab" else np.fm if np.on_air() == "fm" else {}
	if band.is_empty():
		_player.title = np.title
		_player.artist = np.artist
		_player.album = np.album
		_player.show_position = np.duration_ms > 0.0
		_player.playing = np.playing()
		_player.art = np.art
		_player.initials = ""
		_player.badge = Color(0, 0, 0, 0)
	else:
		_player.title = band.title if band.title != "" else ("DAB+" if np.on_air() == "dab" else "FM")
		_player.artist = band.text
		_player.album = band.detail
		_player.show_position = false
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


## LIVI's preconditioning setting, which the car link reads with the route (automatic for a fast
## charger on it). Like the row, it shows the core's state, not the tap.
func _on_auto_precondition() -> void:
	var auto: AutoChip = _precondition.trailing
	var want := "off" if Core.get_value("/config/batteryPreconditioning") != "off" else "auto"
	auto.set_pressed_no_signal(want == "off")
	var err: String = Core.act({kind = "setConfig", patch = {batteryPreconditioning = want}})
	if err != "":
		push_error("auto precondition: %s" % err)
