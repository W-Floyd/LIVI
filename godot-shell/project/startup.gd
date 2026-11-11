extends RefCounted
## Startup milestones in ms since the process started, one `[startup]` line each on stdout (the
## journal, under livi-shell.service), and all of them in one line for shell.log (`summary`).
## docs/startup.md reads them.

static var _marks: PackedStringArray = []
## ms between the process starting and the engine's clock (Time.get_ticks_msec) starting.
static var _lead := -1
## When the process started, s after boot; -1 without /proc.
static var _started_s := -1.0


static func mark(name: String) -> void:
	if _lead < 0:
		_measure_lead()
	var line := "%s %d" % [name, Time.get_ticks_msec() + _lead]
	_marks.append(line)
	print("[startup] %s ms" % line)


static func summary() -> String:
	var line := "[startup] " + " ".join(_marks) + " (ms since the process started"
	if _started_s >= 0.0:
		line += ", %.2f s after boot" % _started_s
	return line + ")"


## /proc/self/stat's start time and /proc/uptime are in 10 ms clock ticks: the lead is to ±10 ms.
static func _measure_lead() -> void:
	_lead = 0
	var stat := _first_line("/proc/self/stat")
	var uptime := _first_line("/proc/uptime")
	if stat == "" or uptime == "":
		return
	# Field 22, counting from the state after the parenthesised command name.
	var fields := stat.substr(stat.rfind(")") + 2).split(" ")
	if fields.size() < 20:
		return
	_started_s = fields[19].to_float() / 100.0
	var up_ms := uptime.split(" ")[0].to_float() * 1000.0
	_lead = maxi(0, int(up_ms - _started_s * 1000.0) - Time.get_ticks_msec())


## /proc files have no length, which get_file_as_string needs.
static func _first_line(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_line() if f else ""
