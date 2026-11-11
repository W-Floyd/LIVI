extends Node
## Whether the car is driven, and what that locks (PLAN.md, "What a screen visible to the driver
## may show"): hosted apps not marked DriveSafe are covered (they keep running) and typing is
## off. Driving is the car's own lockout signal (`drivingRegulation`, which stock applies to
## video and the keyboard), else out of Park, else the parking brake and speed (`DriveState`).
## The phone's projection is never locked here: Android Auto and CarPlay apply their own.
##
## Settings → Driving's "While driving" (`mode`):
##   car        locks as the car says (the default);
##   passenger  as `car`, but a passenger may unlock for one drive, confirming each time; it ends
##              when the car parks or the ignition goes off, and shows while it lasts;
##   offroad    never locks: for testing, offered only with the developer options on, and shown
##              for as long as it is chosen.
## Kept in `$XDG_CONFIG_HOME/livi-shell/driving.json`; none in tests.

signal changed

const MODES := ["car", "passenger", "offroad"]

var mode := "car"
## Shows `offroad` among the choices.
var developer := false
## The car is driven, by its own signals.
var moving := false
## What `moving` went by (`DriveState.source`).
var source := ""
## A passenger unlocked this drive.
var passenger := false
## Set by the launcher: which app a window is, and whether it is DriveSafe.
var launcher: Launcher
var file := ""

var _state := DriveState.new()
var _telemetry: Variant = null
var _ms := 0.0


func _ready() -> void:
	Core.changed.connect(func(sections): if sections.has("telemetry"): _update(true))
	Core.welcome.connect(func(_v): _update(true))
	var args := OS.get_cmdline_user_args()
	if not args.has("--test") and not args.has("--live"):
		load_file(default_file())


func _process(delta: float) -> void:
	_ms += delta * 1000.0
	# A lockout lifts only once parked has held: time has to pass without a push.
	if moving and _state.pending():
		_update(false)


## The look's folder, beside look.json.
static func default_file() -> String:
	return ThemeManager.default_look_file().get_base_dir().path_join("driving.json")


func load_file(path: String) -> void:
	file = path
	var saved = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	if saved is Dictionary:
		developer = saved.get("developer", false) == true
		var m := str(saved.get("mode", "car"))
		mode = m if m in MODES and (m != "offroad" or developer) else "car"
	changed.emit()


func _save() -> void:
	if file == "":
		return
	DirAccess.make_dir_recursive_absolute(file.get_base_dir())
	var f := FileAccess.open(file, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({mode = mode, developer = developer}, "  "))


## The defaults, for each scenario.
func reset() -> void:
	mode = "car"
	developer = false
	passenger = false
	launcher = null
	_state = DriveState.new()
	moving = false
	source = ""
	_update(true)


## Whether the driver may change the choice to `m` now: while the car is driven, only to locking
## as the car says.
func may_set_mode(m: String) -> bool:
	return m in MODES and (m == "car" or not moving) and (m != "offroad" or developer)


func set_mode(m: String) -> bool:
	if not may_set_mode(m):
		return false
	mode = m
	if m != "passenger":
		passenger = false
	_save()
	changed.emit()
	return true


## Off also leaves `offroad`; changed only while parked.
func set_developer(on: bool) -> bool:
	if moving:
		return false
	developer = on
	if not on and mode == "offroad":
		mode = "car"
	_save()
	changed.emit()
	return true


## What the driver may not use now.
func locked() -> bool:
	return moving and not passenger and mode != "offroad"


## A passenger may unlock this drive, after confirming.
func can_unlock() -> bool:
	return moving and not passenger and mode == "passenger"


func unlock_for_passenger() -> bool:
	if not can_unlock():
		return false
	passenger = true
	print("drive: unlocked for a passenger until the car parks")
	changed.emit()
	return true


## "passenger" or "offroad" while the lockout is set aside, else "".
func override() -> String:
	if mode == "offroad":
		return "offroad"
	return "passenger" if moving and passenger else ""


## A hosted window is covered: driving, and its app is not DriveSafe (a window no launched app
## owns is not).
func covers_window(id: int) -> bool:
	if not locked() or id < 0:
		return false
	return not app_safe(app_of(id))


func app_of(window: int) -> String:
	return str(launcher.windows.get(window, {}).get("app", "")) if is_instance_valid(launcher) else ""


func app_safe(id: String) -> bool:
	return is_instance_valid(launcher) and id != "" and bool(launcher.app(id).get("drive_safe", false))


func _update(pushed: bool) -> void:
	if pushed:
		_telemetry = Core.get_value("/telemetry")
	var was_moving := moving
	var was_passenger := passenger
	moving = _state.update(_telemetry, roundi(_ms))
	source = _state.source()
	# One drive's: parking or switching off ends it.
	var t: Dictionary = _telemetry if _telemetry is Dictionary else {}
	if not moving or t.get("ignition") == false or t.get("vehicleReady") == false:
		passenger = false
	if moving != was_moving or passenger != was_passenger:
		print("drive: %s (%s)%s" % ["driving" if moving else "parked", source if source != "" else "nothing known", ", passenger" if passenger else ""])
		changed.emit()
