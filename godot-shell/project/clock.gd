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


## `now()` shifted to the system's time zone, for wall-clock fields
## (`Time.get_datetime_dict_from_unix_time`). A fixed start is already wall time.
func local() -> float:
	if _fixed_start >= 0.0:
		return now()
	return now() + Time.get_time_zone_from_system().bias * 60.0
