class_name Card
extends PanelContainer
## A surface in the theme's card style. Subclasses build into `_build()` and restyle in
## `_style()`; both the card and its contents follow ThemeManager.


func _init() -> void:
	_build()


func _ready() -> void:
	ThemeManager.changed.connect(_restyle)
	resized.connect(_apply_material)
	_restyle()


func _build() -> void:
	pass


func _style() -> void:
	pass


func _restyle() -> void:
	add_theme_stylebox_override("panel", ThemeManager.card_box())
	UI.restyle(self)
	_style()
	_apply_material()


## Frosted or glass over the map; nothing for solid surfaces.
func _apply_material() -> void:
	material = ThemeManager.surface_material(size)
