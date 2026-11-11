class_name AppTile
extends BaseButton
## An app in the launcher's grid: icon over name, marked while it runs, starts or has failed.
## As a `chip`, a running window in the switcher: icon, name and a close button in a row.

signal close_pressed
## Held for `HOLD_S`: the app's menu, instead of a tap.
signal long_pressed

const HOLD_S := 0.6

var app_name := "":
	set(v):
		app_name = v
		_refresh()
var icon_path := "":
	set(v):
		icon_path = v
		_refresh()
## "", "running", "launching" or "failed".
var state := "":
	set(v):
		state = v
		_refresh()
## Launching for a while: says it is still starting.
var slow := false:
	set(v):
		slow = v
		_refresh()
var chip := false
## A hold fired since the last press, so its release is no tap.
var held := false

var _icon: AppIcon
var _name: Label
var _close: Button


func _init() -> void:
	focus_mode = Control.FOCUS_NONE
	_icon = AppIcon.new()
	_icon.name = "Icon"
	add_child(_icon)
	_name = UI.label("", "body", "caption", "text")
	_name.name = "Name"
	_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_name)
	button_down.connect(queue_redraw)
	button_up.connect(queue_redraw)
	var hold := Timer.new()
	hold.name = "Hold"
	hold.one_shot = true
	hold.wait_time = HOLD_S
	hold.timeout.connect(func():
		if is_pressed():
			held = true
			long_pressed.emit())
	add_child(hold)
	button_down.connect(func():
		held = false
		hold.start())
	button_up.connect(hold.stop)


func _ready() -> void:
	if chip:
		_close = Button.new()
		_close.name = "Close"
		_close.focus_mode = Control.FOCUS_NONE
		_close.flat = true
		_close.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_close.pressed.connect(func(): close_pressed.emit())
		add_child(_close)
	_name.autowrap_mode = TextServer.AUTOWRAP_OFF if chip else TextServer.AUTOWRAP_WORD_SMART
	_name.max_lines_visible = 1 if chip else 2
	_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if chip else HORIZONTAL_ALIGNMENT_CENTER
	_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER if chip else VERTICAL_ALIGNMENT_TOP
	_name.clip_text = true
	ThemeManager.changed.connect(_style)
	resized.connect(_layout)
	_style()


func _style() -> void:
	UI.style_label(_name)
	var t: float = ThemeManager.px.touch
	var g: float = ThemeManager.px.gap
	if chip:
		_close.icon = Icons.texture("close", ThemeManager.px.icon)
		_close.add_theme_color_override("icon_normal_color", ThemeManager.c.dim)
		_close.add_theme_color_override("icon_hover_color", ThemeManager.c.dim)
		_close.add_theme_color_override("icon_pressed_color", ThemeManager.c.text)
		_fit_chip()
	else:
		custom_minimum_size = Vector2(t * 4.0, t * 1.5 + g * 4.0 + _line_h() * 2.0)
	_refresh()
	_layout()


func _line_h() -> float:
	var f: Font = ThemeManager.fonts.body
	return f.get_height(ThemeManager.font_size("caption"))


func _layout() -> void:
	var g: float = ThemeManager.px.gap
	var t: float = ThemeManager.px.touch
	if chip:
		var side := size.y - g * 1.5
		_icon.position = Vector2(g, (size.y - side) / 2.0)
		_icon.size = Vector2(side, side)
		_close.position = Vector2(size.x - t, 0)
		_close.size = Vector2(t, size.y)
		_name.position = Vector2(_icon.position.x + side + g, 0)
		_name.size = Vector2(maxf(0.0, _close.position.x - _name.position.x), size.y)
	else:
		var side := t * 1.5
		_icon.position = Vector2((size.x - side) / 2.0, g * 1.5)
		_icon.size = Vector2(side, side)
		_name.position = Vector2(g, _icon.position.y + side + g)
		_name.size = Vector2(size.x - g * 2.0, size.y - _name.position.y)
	queue_redraw()


func _refresh() -> void:
	if _icon == null:
		return
	_icon.path = icon_path
	_icon.label = app_name
	_icon.modulate.a = 0.45 if state == "launching" else 1.0
	match state:
		"launching":
			_name.text = "Still starting…" if slow else "Starting…"
		"failed":
			_name.text = "Couldn't start"
		_:
			_name.text = app_name
	_name.get_meta("look")[2] = "crit" if state == "failed" else "dim" if state == "launching" else "text"
	UI.style_label(_name)
	if chip and _close:
		_fit_chip()
	queue_redraw()


## As wide as the name needs, within limits: a long one is cut short.
func _fit_chip() -> void:
	var t: float = ThemeManager.px.touch
	var g: float = ThemeManager.px.gap
	var w: float = ThemeManager.fonts.body.get_string_size(app_name, HORIZONTAL_ALIGNMENT_LEFT, -1, ThemeManager.font_size("caption")).x
	custom_minimum_size = Vector2(clampf(w + t * 2.0 + g * 3.0, t * 3.0, t * 7.0), t)


func _draw() -> void:
	var c := ThemeManager.c
	var box := StyleBoxFlat.new()
	box.bg_color = c.accent.lerp(c.surface2, 0.6) if is_pressed() else c.surface2
	box.set_corner_radius_all(roundi(ThemeManager.px.radius * 2.0))
	box.anti_aliasing = true
	box.set_border_width_all(2)
	box.border_color = c.accent if state == "running" and not chip else c.line
	draw_style_box(box, Rect2(Vector2.ZERO, size))
	if state == "running" and not chip:
		var rad: float = ThemeManager.px.gap * 0.9
		draw_circle(Vector2(size.x - rad * 2.2, rad * 2.2), rad, c.accent, true, -1.0, true)
