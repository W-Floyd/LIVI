extends Node
## Wall time, or a fixed start advanced by frame time, so test renders do not depend on when
## they run. Under `--fixed-fps` every frame's delta is exact.

var _fixed_start := -1.0
var _elapsed := 0.0


func fix(unix_seconds: float) -> void:
	_fixed_start = unix_seconds
	_elapsed = 0.0


func _process(delta: float) -> void:
	_elapsed += delta


func now() -> float:
	if _fixed_start < 0.0:
		return Time.get_unix_time_from_system()
	return _fixed_start + _elapsed
