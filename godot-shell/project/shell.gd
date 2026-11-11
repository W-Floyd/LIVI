extends Control
## The shell's root: the home page in its split layout, bound to the core's state. The
## projection is on one side and the panel on the other, swapped for RHD or the driver's
## "nearer" choice.

@onready var _status: StatusBar = $Page/Status
@onready var _body: HBoxContainer = $Page/Body
@onready var _slot: Control = $Page/Body/Slot
@onready var _projection: ProjectionView = $Projection
@onready var _side: MarginContainer = $Page/Body/Side
@onready var _stat: StatTile = $Page/Body/Side/Panel/Stat
@onready var _precondition: ToggleRow = $Page/Body/Side/Panel/Precondition
@onready var _stop: StopCard = $Page/Body/Side/Panel/Stop
@onready var _player: MiniPlayer = $Page/Body/Side/Panel/Player

## A tap on the "Electric vehicle" page's targets (`next_departure`, `scheduled`, `v2l`,
## `settings`). The core has no action for any of them yet.
signal ev_action(id: String)
## The page now showing, as `open_page` resolved it (`ev` is `ev_live` or `ev_main`).
signal page_changed(page: String)

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


func _init() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var page := VBoxContainer.new()
	page.name = "Page"
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.add_theme_constant_override("separation", 0)
	var status := StatusBar.new()
	status.name = "Status"
	page.add_child(status)
	var body := HBoxContainer.new()
	body.name = "Body"
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
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
	var panel := VBoxContainer.new()
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


func _ready() -> void:
	theme = ThemeManager.godot_theme
	ThemeManager.changed.connect(_style)
	# A (re)connected core starts from its own idea of the main screen: say what this page shows.
	Core.welcome.connect(func(_v): _refresh(); _tell_front(); _ask_area(true))
	Core.changed.connect(_on_core_changed)
	Core.open_page.connect(_on_core_page)
	_precondition.icon_name = "therm"
	_precondition.pressed.connect(_on_precondition)
	_player.control.connect(func(c): Core.act({kind = "media", control = c}))
	Wayland.window_mapped.connect(func(id, app_id, title): print("window %d mapped: app_id \"%s\" title \"%s\"" % [id, app_id, title]); _windows.append(id); _app_ids[id] = app_id; _show_app())
	Wayland.window_unmapped.connect(_on_window_unmapped)
	launcher.show_window.connect(bring_forward)
	_style()
	_refresh()


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
		_scene.surfaces = [_status, _stat, _precondition, _stop, _player]
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
	_side.custom_minimum_size.x = ThemeManager.px.side
	for k in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		_side.add_theme_constant_override(k, roundi(g * 1.5))
	(_side.get_node("Panel") as VBoxContainer).add_theme_constant_override("separation", roundi(g * 1.5))
	_body.move_child(_side, 0 if ThemeManager.side_left() else 1)
	# The page passes input through where the projection shows.
	$Page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()
	_fit.call_deferred()
	_place_projection.call_deferred()


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
	elif page not in ["home", "app", "apps", "projection"] and not (ThemeManager.pack and ThemeManager.pack.has_screen(page)):
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
	var home := page == "home"
	var live := page == "ev_live"
	var own_bar := live and _own_bar()
	_live_bar = own_bar
	# The live page keeps the status bar unless its pack draws its own title bar.
	$Page.visible = home or page == "apps" or (live and not own_bar)
	_body.visible = home
	_projection.visible = home or _app_page
	# Every page change: leaving the full-panel pages puts the picture back in home's slot.
	_place_projection()
	_place_projection.call_deferred()
	if _scene:
		_scene.visible = home
	if live:
		var ev := EvLive.new()
		ev.top_inset = 0.0 if own_bar else _status.get_combined_minimum_size().y
		ev.tile_pressed.connect(func(id): ev_action.emit(id))
		ev.back_pressed.connect(func(): open_page.call_deferred("home"))
		_page = ev
		add_child(_page)
	elif page == "settings":
		var settings := SettingsPage.new()
		settings.top_inset = _status.get_combined_minimum_size().y
		settings.back_pressed.connect(func(): open_page.call_deferred(_settings_from))
		$Page.visible = true
		_page = settings
		add_child(_page)
	elif page == "apps":
		var apps := AppsPage.new()
		apps.launcher = launcher
		apps.top_inset = _status.get_combined_minimum_size().y
		_page = apps
		add_child(_page)
	elif not home and not _app_page:
		_page = PackScreen.new()
		_page.screen_name = page
		add_child(_page)
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
	return _on_projection() or _page_name == "home"


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


func _place_projection() -> void:
	if _projection == null:
		return
	var r := Rect2(Vector2.ZERO, size) if (ThemeManager.floating() or _app_page) else Rect2(_slot.global_position - global_position, _slot.size)
	_projection.position = r.position
	_projection.size = r.size
	_ask_area()


## The last area asked of the phone, in the projection screen's pixels.
var _area_asked := Rect2i()


## Android Auto lays its UI out where the page shows it: home's slot (under a floating panel too),
## else the whole panel. A phone that does not take it is letterboxed (`WindowView`).
func _ask_area(again := false) -> void:
	if not _shows_projection():
		return
	var home := Rect2(_slot.global_position - global_position, _slot.size)
	var a: Rect2i = _projection.window.to_screen(home if _page_name == "home" else Rect2(Vector2.ZERO, size))
	if a.size.x <= 0 or a.size.y <= 0 or (a == _area_asked and not again):
		return
	_area_asked = a
	Core.act({kind = "projectionArea", screen = "main", x = a.position.x, y = a.position.y, width = a.size.x, height = a.size.y})


## Shows every item that has content, then drops the least important until the rest fit.
func _fit() -> void:
	var panel: VBoxContainer = _side.get_node("Panel")
	var electric := _powertrain() == "electric"
	var wanted := {Stat = true, Precondition = electric, Stop = electric and _stop.has_content(), Player = _player.has_content()}
	for n in PRIORITY:
		panel.get_node(n).visible = wanted[n]
	# The screen's height, not the panel's: the panel grows with what it holds.
	var room: float = size.y - _status.get_combined_minimum_size().y \
		- _side.get_theme_constant("margin_top") - _side.get_theme_constant("margin_bottom")
	left_out.clear()
	var order := PRIORITY.duplicate()
	order.reverse()
	for n in order:
		if panel.get_combined_minimum_size().y <= room:
			break
		var item: Control = panel.get_node(n)
		if item.visible:
			item.visible = false
			left_out.append(n)
	if not left_out.is_empty():
		print("side panel: left out %s; it holds %d px" % [", ".join(left_out), roundi(room)])


func _on_window_unmapped(id: int) -> void:
	_windows.erase(id)
	_app_ids.erase(id)
	# The app page shows hosted apps only: with none left, back to the grid they came from
	# (not to the phone's video, which is the newest window left).
	if _page_name == "app" and not _windows.any(func(w): return not _is_projection(w)):
		open_page("apps")
		return
	_show_app()


func _show_app() -> void:
	# Home's slot is the phone's while there is a phone: a launched app is the app page's.
	var phone := _projection_page or (_page_name == "home" and _windows.any(_is_projection))
	var shown: Array = _windows.filter(_is_projection) if phone else _windows.filter(func(w): return not _is_projection(w)) if _page_name == "app" else Array(_windows)
	var id: int = shown[-1] if not shown.is_empty() else -1
	_projection.show_window(id, id >= 0 and _is_projection(id))


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
	_stat.sub_value = "–" if km == null else "%d km" % roundi(km)
	var ev_km = t.call("rangeElectricKm")
	if power == "hybrid" and ev_km != null:
		_stat.sub_label = "Range · %d km electric" % roundi(ev_km)
	var amb = t.call("ambientC")
	_status.outside = "" if amb == null else "%d °C" % roundi(amb)
	_status.charge = "" if soc == null else "%d %%" % roundi(soc)
	_status.charge_icon = "bolt" if power == "electric" else "fuel"
	_status.phone = "Pixel"

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

	var np = Core.get_value("/nowPlaying") if sections.is_empty() or sections.has("nowPlaying") else null
	if np is Dictionary and np.get("title"):
		_player.title = np.title
		_player.subtitle = " · ".join([np.get("artist", ""), np.get("album", "")].filter(func(s): return s))
		_player.playing = np.get("playing", false) == true
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
