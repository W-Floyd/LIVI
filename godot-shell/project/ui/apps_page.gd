class_name AppsPage
extends Control
## The launcher's page: every app as a tile, and the running windows in a strip by the title to
## bring forward or close. Tapping an app starts it, or shows its window when it runs.

var launcher: Launcher
## The status bar's height, which the page leaves clear.
var top_inset := 0.0

var _title: Label
var _note: Label
var _running: HBoxContainer
var _scroll: DragScroll
var _grid: GridContainer
## App id -> its tile, kept across changes so the grid's scroll stays put.
var _tiles := {}


func _init() -> void:
	name = "Apps"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_title = UI.label("Apps", "display", "title")
	_title.name = "Title"
	add_child(_title)
	_running = UI.hbox([], 1.0)
	_running.name = "Running"
	_running.clip_contents = true
	add_child(_running)
	_note = UI.label("", "body", "caption", "dim")
	_note.name = "Note"
	add_child(_note)
	# A finger drags the grid; a drag never opens the tile it ends on.
	_scroll = DragScroll.new()
	_scroll.name = "Scroll"
	add_child(_scroll)
	_grid = GridContainer.new()
	_grid.name = "Grid"
	_scroll.list.add_child(_grid)


func _ready() -> void:
	ThemeManager.changed.connect(_style)
	resized.connect(_layout)
	launcher.changed.connect(_update)
	launcher.refresh()
	_style()


## The shell draws the ground, except under a scene theme, whose 3D layer is home's alone.
func _draw() -> void:
	draw_rect(Rect2(0, top_inset, size.x, size.y - top_inset), ThemeManager.c.bg)


func _style() -> void:
	UI.restyle(self)
	var g: float = ThemeManager.px.gap
	_grid.add_theme_constant_override("h_separation", roundi(g * 2.0))
	_grid.add_theme_constant_override("v_separation", roundi(g * 2.0))
	_update()
	queue_redraw()


## Clear of the rail on the left edge (LIVI_SHELL_NAV), which overlays every page but projection.
func _left() -> float:
	return ThemeManager.px.touch + ThemeManager.px.gap * 4.0


func _layout() -> void:
	var g: float = ThemeManager.px.gap
	var x := _left()
	var right := size.x - g * 4.0
	var head_h := maxf(ThemeManager.px.touch, _title.get_combined_minimum_size().y)
	var y := top_inset + g * 2.0
	_title.position = Vector2(x, y + (head_h - _title.get_combined_minimum_size().y) / 2.0)
	_title.size = _title.get_combined_minimum_size()
	var rx := _title.position.x + _title.size.x + g * 4.0
	_running.position = Vector2(rx, y)
	_running.size = Vector2(maxf(0.0, right - rx), head_h)
	_note.position = Vector2(rx, y + (head_h - _note.get_combined_minimum_size().y) / 2.0)
	_note.size = Vector2(maxf(0.0, right - rx), _note.get_combined_minimum_size().y)
	var top := y + head_h + g * 3.0
	_scroll.position = Vector2(x, top)
	_scroll.size = Vector2(maxf(0.0, right - x), maxf(0.0, size.y - top))
	var tile_w: float = ThemeManager.px.touch * 4.0
	var sep: float = g * 2.0
	_grid.columns = maxi(1, int((_scroll.size.x + sep) / (tile_w + sep)))


func _update() -> void:
	if launcher == null or not is_inside_tree():
		return
	var keep := {}
	var i := 0
	for a in launcher.apps:
		keep[a.id] = true
		var t: AppTile = _tiles.get(a.id)
		if t == null:
			t = AppTile.new()
			t.name = _node_name(a.id)
			var id: String = a.id
			t.pressed.connect(func(): if not _scroll.dragged: launcher.open.call_deferred(id))
			_grid.add_child(t)
			_tiles[a.id] = t
		t.app_name = a.name
		t.icon_path = a.icon
		t.state = launcher.state(a.id)
		_grid.move_child(t, i)
		i += 1
	for id in _tiles.keys():
		if not keep.has(id):
			_tiles[id].queue_free()
			_tiles.erase(id)
	_update_running()
	var err := launcher.config_error()
	_note.text = err if err != "" else "No apps found" if launcher.apps.is_empty() and _running.get_child_count() == 0 else ""
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


## Tiles are found by app id, '.' as '_' (`Apps/Scroll/List/Grid/org_livi_test_grid`), which a node
## name cannot hold.
static func _node_name(id: String) -> String:
	return id.validate_node_name().replace(".", "_")
