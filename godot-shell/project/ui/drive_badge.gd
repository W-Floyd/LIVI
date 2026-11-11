class_name DriveBadge
extends PanelContainer
## Says the driving lockout is set aside (`Drive.override`): "Passenger" until the car parks, or
## "Always offroad" while that is chosen. A small pill at the top centre of the shell, over every
## page but the phone's own.

var _icon: TextureRect
var _label: Label
var _page := "home"


func _init() -> void:
	name = "DriveBadge"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Over the pages, which are added after it.
	z_index = 20
	visible = false
	_icon = UI.icon("car", "icon", "accent")
	_label = UI.label("", "strong", "caption", "accent")
	_label.name = "Label"
	var row := UI.hbox([_icon, _label], 0.4)
	row.name = "Row"
	add_child(row)


func _ready() -> void:
	Drive.changed.connect(_update)
	ThemeManager.changed.connect(_update)
	var shell := get_parent()
	if shell.has_signal("page_changed"):
		shell.page_changed.connect(func(p): _page = p; _update())
	shell.resized.connect(_place)
	_update()


func _update() -> void:
	var o: String = Drive.override()
	visible = o != "" and _page != "projection"
	if not visible:
		return
	var color := "warn" if o == "offroad" else "accent"
	_label.text = "Always offroad" if o == "offroad" else "Passenger"
	_label.get_meta("look")[2] = color
	_icon.get_meta("icon")[0] = "warn" if o == "offroad" else "car"
	_icon.get_meta("icon")[2] = color
	UI.restyle(self)
	var b := StyleBoxFlat.new()
	b.bg_color = ThemeManager.c.surface
	b.border_color = ThemeManager.c[color]
	b.set_border_width_all(2)
	b.set_corner_radius_all(roundi(ThemeManager.px.status))
	b.content_margin_left = ThemeManager.px.gap * 1.2
	b.content_margin_right = ThemeManager.px.gap * 1.2
	b.content_margin_top = ThemeManager.px.gap * 0.3
	b.content_margin_bottom = ThemeManager.px.gap * 0.3
	b.anti_aliasing = true
	add_theme_stylebox_override("panel", b)
	_place.call_deferred()


## Centred in the status bar's height.
func _place() -> void:
	if not visible:
		return
	size = get_combined_minimum_size()
	var shell := get_parent() as Control
	position = (Vector2((shell.size.x - size.x) / 2.0, (ThemeManager.px.status - size.y) / 2.0)).round()
