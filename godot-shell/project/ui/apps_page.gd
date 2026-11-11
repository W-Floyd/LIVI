class_name AppsPage
extends Control
## The launcher's page: every app as a tile, and the running windows in a strip above them to
## bring forward or close. No title: the rail says which page this is. Tapping an app starts it, or
## shows its window when it runs; holding it opens its menu, the app's size on the panel.

## Rows the grid's height shows: two whole, and enough of a third to read as more below.
const ROWS_SHOWN := 2.4

var launcher: Launcher
## The status bar's height, which the page leaves clear.
var top_inset := 0.0

var _note: Label
## Says why tiles are greyed while the car is driven.
var _parked_only: HBoxContainer
var _running: HBoxContainer
var _scroll: DragScroll
var _grid: GridContainer
var _foot: Control
## App id -> its tile, kept across changes so the grid's scroll stays put.
var _tiles := {}
## An app's menu while it shows.
var _menu: Control


func _init() -> void:
	name = "Apps"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_running = UI.hbox([], 1.0)
	_running.name = "Running"
	_running.clip_contents = true
	add_child(_running)
	_note = UI.label("", "body", "caption", "dim")
	_note.name = "Note"
	add_child(_note)
	_parked_only = UI.hbox([UI.icon("lock", "icon", "dim"), UI.label("Greyed apps are available when parked", "body", "caption", "dim")], 0.5)
	_parked_only.name = "ParkedOnly"
	_parked_only.visible = false
	add_child(_parked_only)
	# A finger drags the grid; a drag never opens the tile it ends on.
	_scroll = DragScroll.new()
	_scroll.name = "Scroll"
	add_child(_scroll)
	_grid = GridContainer.new()
	_grid.name = "Grid"
	_scroll.list.add_child(_grid)
	# The last row clear of the page's edge when scrolled to the end.
	_foot = Control.new()
	_foot.name = "Foot"
	_foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scroll.list.add_child(_foot)


func _ready() -> void:
	ThemeManager.changed.connect(_style)
	resized.connect(_layout)
	visibility_changed.connect(close_menu)
	launcher.changed.connect(_update)
	Drive.changed.connect(_update)
	launcher.refresh()
	_style()


## The shell draws the ground, except under a scene theme, whose 3D layer is home's alone.
func _draw() -> void:
	draw_rect(Rect2(0, top_inset, size.x, size.y - top_inset), ThemeManager.c.bg)


func _style() -> void:
	UI.restyle(self)
	_update()
	queue_redraw()


## The gutter between tiles, and round the grid.
static func gutter() -> int:
	return roundi(ThemeManager.px.gap * 1.5)


## Columns and tile size from the grid's room: as many columns as tiles at their least width
## allow, widened to fill it; tall enough that `ROWS_SHOWN` rows fill its height, within the
## tile's least height (two lines of name at the text scale) and a little taller than wide.
static func cells(room: Vector2) -> Dictionary:
	var sep := gutter()
	var least := AppTile.least_cell()
	var cols := maxi(1, int((room.x + sep) / (least.x + sep)))
	var w := floorf((room.x - sep * (cols - 1)) / cols)
	var h := floorf(clampf((room.y - sep * floorf(ROWS_SHOWN)) / ROWS_SHOWN, least.y, maxf(least.y, w * 1.15)))
	return {columns = cols, cell = Vector2(maxf(w, 1.0), h)}


func _layout() -> void:
	var sep := float(gutter())
	var x := sep
	var right := size.x - sep
	var y := top_inset + sep
	# The running strip, or the note, above the grid: only when there is one.
	var head := _running.get_child_count() > 0 or _note.text != ""
	var head_h: float = ThemeManager.px.touch if head else 0.0
	_running.position = Vector2(x, y)
	_running.size = Vector2(maxf(0.0, right - x), head_h)
	_note.position = Vector2(x, y + (head_h - _note.get_combined_minimum_size().y) / 2.0)
	_note.size = Vector2(maxf(0.0, right - x), _note.get_combined_minimum_size().y)
	var top := y + (head_h + sep if head else 0.0)
	var foot := 0.0
	if _parked_only.visible:
		var ph := _parked_only.get_combined_minimum_size().y
		_parked_only.position = Vector2(x, size.y - sep - ph)
		_parked_only.size = Vector2(maxf(0.0, right - x), ph)
		foot = ph + sep
	_scroll.position = Vector2(x, top)
	_scroll.size = Vector2(maxf(0.0, right - x), maxf(0.0, size.y - top - foot))
	_grid.add_theme_constant_override("h_separation", int(sep))
	_grid.add_theme_constant_override("v_separation", int(sep))
	_scroll.list.add_theme_constant_override("separation", 0)
	_foot.custom_minimum_size = Vector2(0, sep)
	var k := cells(Vector2(_scroll.size.x, size.y - top - foot))
	_grid.columns = k.columns
	for t in _tiles.values():
		t.cell = k.cell


func _update() -> void:
	if launcher == null or not is_inside_tree():
		return
	var keep := {}
	var i := 0
	var greyed := false
	for a in launcher.apps:
		keep[a.id] = true
		var t: AppTile = _tiles.get(a.id)
		if t == null:
			t = AppTile.new()
			t.name = _node_name(a.id)
			var id: String = a.id
			t.pressed.connect(func(): if not _scroll.dragged and not t.held: launcher.open.call_deferred(id))
			t.long_pressed.connect(func(): if not _scroll.dragged: open_menu(id))
			_grid.add_child(t)
			_tiles[a.id] = t
		t.app_name = a.name
		t.icon_path = a.icon
		t.slow = launcher.slow(a.id)
		t.state = launcher.state(a.id)
		# Parked only, while the car is driven: it opens under the cover.
		var parked_only: bool = Drive.locked() and not a.get("drive_safe", false)
		t.modulate.a = 0.45 if parked_only else 1.0
		greyed = greyed or parked_only
		_grid.move_child(t, i)
		i += 1
	for id in _tiles.keys():
		if not keep.has(id):
			_tiles[id].queue_free()
			_tiles.erase(id)
	_update_running()
	var err := launcher.config_error()
	_note.text = err if err != "" else "No apps found" if launcher.apps.is_empty() and _running.get_child_count() == 0 else ""
	_parked_only.visible = greyed
	_note.get_meta("look")[2] = "crit" if err != "" else "dim"
	UI.style_label(_note)
	_layout.call_deferred()


func _update_running() -> void:
	for ch in _running.get_children():
		_running.remove_child(ch)
		ch.queue_free()
	for r in launcher.running():
		var chip := AppTile.new()
		chip.chip = true
		chip.name = _node_name(r.app if r.app != "" else "window_%d" % r.window)
		chip.app_name = r.name
		chip.icon_path = r.icon
		var w: int = r.window
		chip.pressed.connect(func(): launcher.bring.call_deferred(w))
		chip.close_pressed.connect(func(): launcher.close.call_deferred(w))
		_running.add_child(chip)


## The app's menu over the page: its size on the panel, `Default` (apps.yaml's, else the shell's)
## or one of `Launcher.SCALES`, each a button `Menu/Panel/Box/Sizes/s<percent>` (`s0` the default),
## and its window, `Menu/Panel/Box/Modes/maximized` or `fullscreen`. A tap beside it closes it.
func open_menu(id: String) -> void:
	close_menu()
	var a := launcher.app(id)
	if a.is_empty():
		return
	var g: float = ThemeManager.px.gap
	_menu = Control.new()
	_menu.name = "Menu"
	_menu.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_menu.mouse_filter = Control.MOUSE_FILTER_STOP
	_menu.gui_input.connect(func(e: InputEvent):
		if (e is InputEventMouseButton or e is InputEventScreenTouch) and e.pressed:
			close_menu.call_deferred())
	_menu.draw.connect(func(): _menu.draw_rect(Rect2(Vector2.ZERO, _menu.size), Color(0, 0, 0, 0.45)))
	var panel := PanelContainer.new()
	panel.name = "Panel"
	var box := _flat(ThemeManager.c.surface2)
	box.set_content_margin_all(g * 4.0)
	panel.add_theme_stylebox_override("panel", box)
	var sizes := UI.hbox([], 1.0)
	sizes.name = "Sizes"
	var own := int(a.get("scale", 0))
	var chosen := int(ThemeManager.app_scales.get(id, 0))
	for p in [0] + Launcher.SCALES:
		var pct: int = p
		var text: String = "Default (%d %%)" % (own if own > 0 else Launcher.default_scale()) if p == 0 else "%d %%" % p
		sizes.add_child(_choice("s%d" % p, text, p == chosen, func(): launcher.set_app_scale(id, pct)))
	var modes := UI.hbox([], 1.0)
	modes.name = "Modes"
	for m in ["maximized", "fullscreen"]:
		var mode: String = m
		modes.add_child(_choice(m, m.capitalize(), launcher.window_mode_of(id) == m, func(): launcher.set_app_window_mode(id, mode)))
	var col := UI.vbox([UI.label(a.name, "display", "title"), UI.label("Size on the panel", "body", "caption", "dim"), sizes,
		UI.label("Window", "body", "caption", "dim"), modes], 1.5)
	col.name = "Box"
	panel.add_child(col)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_menu.add_child(panel)
	add_child(_menu)
	UI.restyle(_menu)


## One of the menu's choices; picking it applies `pick` and closes the menu.
func _choice(node_name: String, text: String, chosen: bool, pick: Callable) -> Button:
	var g: float = ThemeManager.px.gap
	var b := Button.new()
	b.name = node_name
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(ThemeManager.px.touch * 1.6, ThemeManager.px.touch)
	b.add_theme_font_size_override("font_size", ThemeManager.font_size("body"))
	b.add_theme_color_override("font_color", ThemeManager.c.text)
	b.add_theme_color_override("font_hover_color", ThemeManager.c.text)
	b.add_theme_color_override("font_pressed_color", ThemeManager.c.text)
	var fill: Color = ThemeManager.c.accent.lerp(ThemeManager.c.surface2, 0.6) if chosen else ThemeManager.c.surface
	for state in ["normal", "hover", "pressed", "focus"]:
		var sb := _flat(fill)
		sb.set_content_margin_all(g * 1.5)
		sb.set_border_width_all(2)
		sb.border_color = ThemeManager.c.accent if chosen else ThemeManager.c.line
		b.add_theme_stylebox_override(state, sb)
	b.pressed.connect(func():
		pick.call()
		close_menu.call_deferred())
	return b


func close_menu() -> void:
	if _menu:
		_menu.queue_free()
		_menu = null


func _flat(fill: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.set_corner_radius_all(roundi(ThemeManager.px.radius * 2.0))
	sb.anti_aliasing = true
	return sb


## Tiles are found by app id, '.' as '_' (`Apps/Scroll/List/Grid/org_livi_test_grid`), which a node
## name cannot hold.
static func _node_name(id: String) -> String:
	return id.validate_node_name().replace(".", "_")
