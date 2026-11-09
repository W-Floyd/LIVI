extends Control
## The shell's root. A placeholder home page until the layouts land.

const DAY := {bg = Color("#eef1f4"), fg = Color("#15191e"), dim = Color("#5b6672")}
const NIGHT := {bg = Color("#0b0e12"), fg = Color("#e8edf2"), dim = Color("#8a96a3")}

@export var night := false:
	set(v):
		night = v
		if is_node_ready():
			_paint()

@onready var _bg: ColorRect = $Background
@onready var _clock: Label = $Home/Clock
@onready var _soc: Label = $Home/Soc
@onready var _range: Label = $Home/Range
@onready var _precondition: Button = $Home/Precondition


func _ready() -> void:
	Core.welcome.connect(func(_v): _refresh())
	Core.changed.connect(func(_s): _refresh())
	_precondition.pressed.connect(_on_precondition)
	_paint()
	_refresh()


func _process(_delta: float) -> void:
	var t := Time.get_datetime_dict_from_unix_time(int(Clock.now()))
	_clock.text = "%02d:%02d" % [t.hour, t.minute]


func _refresh() -> void:
	var soc = Core.get_value("/telemetry/fuelPct")
	_soc.text = "–" if soc == null else "%d %%" % roundi(soc)
	var km = Core.get_value("/telemetry/rangeKm")
	_range.text = "" if km == null else "%d km" % roundi(km)
	_precondition.text = "Stop preconditioning" if _preconditioning() else "Precondition battery"


func _preconditioning() -> bool:
	return Core.get_value("/precondition/manualUntil") != null


func _on_precondition() -> void:
	var err: String = Core.act({kind = "preconditionBattery", on = not _preconditioning()})
	if err != "":
		push_error("precondition: %s" % err)


func _paint() -> void:
	var p := NIGHT if night else DAY
	_bg.color = p.bg
	for l in [_clock, _soc]:
		l.add_theme_color_override("font_color", p.fg)
	_range.add_theme_color_override("font_color", p.dim)
