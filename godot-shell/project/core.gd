extends CoreLink
## The shell's link to livi-core. Scenarios replace it with a fake before the shell starts.


# The first autoload: the engine, its extensions and the project's settings are up.
func _init() -> void:
	preload("res://startup.gd").mark("engine")
