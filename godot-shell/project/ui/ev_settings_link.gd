class_name EvSettingsLink
## What the EV settings page reads from the car and sends to it, per setting. `read` is the
## telemetry field the core carries for it today; `proposed` the field it would take once
## micom-livi decodes it (the core drops fields it does not know). `write` is how a change
## reaches the car: "core" through LIVI's own action, which micom-livi sends to the micom only
## with its opt-in -precondition; "schedule" as an edit of the car's schedules (SetEvSchedule),
## which micom-livi sends only with its opt-in -ev-schedule-writes and while parked; "" none
## yet, the page shows the setting read-only or unavailable. `frames` names the micom messages
## (docs/ev-settings.md has the evidence).

const SETTINGS := {
	charge_limit_ac = {read = "chargeLimitAcPct", write = "", frames = "set 0x0C18 [4]; read item 0x21, 0x8C01 [50]"},
	charge_limit_dc = {read = "chargeLimitDcPct", write = "", frames = "set 0x0C18 [5]; read item 0x22, 0x8C01 [51]"},
	ac_current = {proposed = "acChargingCurrent", write = "", frames = "set 0x0C5B; read 0x8C50 [0], item 0x51"},
	departure_1 = {read = "departure1", write = "schedule", frames = "set 0x0C06; read 0x8C55"},
	departure_2 = {read = "departure2", write = "schedule", frames = "set 0x0C06; read 0x8C55, 0x8C53 [0]"},
	scheduled_charging = {proposed = "scheduledCharging", write = "", frames = "read 0x8C4A [3]"},
	off_peak = {read = "offPeak", write = "schedule", frames = "set 0x0C05 [0..1]; read 0x8C53 [1..2]"},
	off_peak_mode = {read = "scheduledChargingMode", write = "schedule", frames = "set 0x0C05 [4]; read 0x8C53 [5]"},
	scheduled_climate = {read = "scheduledClimate", write = "schedule", frames = "set 0x0C06 [4]; read 0x8C53 [7]"},
	# The car's code, not degrees: its encoding is not known (°F - 56 fits two stock points only).
	climate_temp = {read = "scheduledClimateTempCode", write = "", frames = "set 0x0C06 [4]; read 0x8C53 [7] b7:2"},
	climate_defog = {read = "scheduledClimateDefrost", write = "schedule", frames = "set 0x0C06 [5]; read 0x8C54 [0]"},
	battery_conditioning = {read = "batteryConditioningMode", write = "core", frames = "set 0x0C62 (micom-livi -precondition); read item 0x63"},
	winter_mode = {proposed = "winterMode", write = "", frames = "set 0x0C18 [2]; read item 0x44, 0x8C1A [6]"},
	v2l_limit = {proposed = "v2lDischargeLimitPct", write = "", frames = "set 0x0C5A; read item 0x50"},
	utility_mode = {proposed = "utilityMode", write = "", frames = "set 0x0C5D; read item 0x58, 0x59"},
}
const AC_CURRENT := ["max", "reduced", "min"]
const OFF_PEAK_MODES := ["off", "prioritize_off_peak", "off_peak_only"]
## Each schedule setting's key in SetEvSchedule's `set`.
const SCHEDULE_KEYS := {departure_1 = "departure1", departure_2 = "departure2", off_peak = "offPeak",
	off_peak_mode = "chargingMode", scheduled_climate = "climate", climate_defog = "climateDefrost"}

## Scenarios: take the proposed fields as read and the stubs' writes into `written`, to check
## what the page would send once the car link has them.
static var fake := false
static var written: Array = []


## "ok" (read and set), "read_only", "unreported" (read, but the car has said nothing yet) or
## "unavailable" (no read path).
static func state(id: String, t: Dictionary) -> String:
	var field := _field(id)
	if field == "":
		return "ok" if writable(id) else "unavailable"
	if t.get(field) == null:
		return "unreported"
	return "ok" if writable(id) and blocked(id, t) == "" else "read_only"


static func value(id: String, t: Dictionary) -> Variant:
	var field := _field(id)
	return null if field == "" else t.get(field)


static func writable(id: String) -> bool:
	return fake or str(SETTINGS[id].write) != ""


## Why a setting LIVI can set takes no change now, "" when it does. The schedules: only with
## micom-livi's opt-in, parked, and one edit at a time.
static func blocked(id: String, t: Dictionary) -> String:
	if str(SETTINGS[id].write) != "schedule":
		return ""
	if t.get("evScheduleWrites") != true:
		return "Read only: the car link does not set schedules (micom-livi -ev-schedule-writes)"
	if Drive.moving:
		return "Read only while driving"
	if pending() != null:
		return "Sending to the car…"
	return ""


## The schedule edit on its way to the car (`set` of SetEvSchedule), null for none.
static func pending() -> Variant:
	var r = Core.get_value("/evSchedule/request")
	return r.get("set") if r is Dictionary else null


## Why the car did not take the last schedule edit, "" when it did or none was made.
static func failed() -> String:
	var last = Core.get_value("/evSchedule/last")
	if last is Dictionary and last.get("ok") == false:
		return str(last.get("why", ""))
	return ""


## Sends a change; "" when it went, else why not.
static func write(id: String, v: Variant) -> String:
	if fake and str(SETTINGS[id].write) == "":
		written.append([id, v])
		return ""
	match str(SETTINGS[id].write):
		"core":
			return _write_core(id, v)
		"schedule":
			return Core.act({kind = "setEvSchedule", set = {SCHEDULE_KEYS[id]: v}})
	return "no path to the car for %s (%s)" % [id, SETTINGS[id].frames]


static func _field(id: String) -> String:
	var s: Dictionary = SETTINGS[id]
	if s.has("read"):
		return s.read
	return s.proposed if fake else ""


## LIVI's manual request is the car's conditioning mode while it lasts: micom-livi holds
## batt-cond-mode on for it.
static func _write_core(id: String, v: Variant) -> String:
	match id:
		"battery_conditioning":
			return Core.act({kind = "preconditionBattery", on = bool(v)})
	return "no core action for %s" % id
