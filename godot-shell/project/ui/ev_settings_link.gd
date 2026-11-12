class_name EvSettingsLink
## What the EV settings page reads from the car and sends to it, per setting. `read` is the
## telemetry field the core carries for it today; `proposed` the field it would take once
## micom-livi decodes it (the core drops fields it does not know). `write` is how a change
## reaches the car: "core" through LIVI's own action, which micom-livi sends to the micom only
## with its opt-in -precondition; "schedule" as an edit of the car's schedules (SetEvSchedule),
## which micom-livi sends only with its opt-in -ev-schedule-writes and while parked; "charge" a
## change of a charge limit or the AC current (SetEvCharge), likewise with -ev-charge-writes; ""
## none yet, the page shows the setting read-only or unavailable. `unreported_ok`: takes a change
## while the car has not reported it (it reports the AC current only on change). `frames` names
## the micom messages (docs/ev-settings.md has the evidence).

const SETTINGS := {
	charge_limit_ac = {read = "chargeLimitAcPct", write = "charge", frames = "set 0x0C18 [4]; read item 0x21, 0x8C01 [50]"},
	charge_limit_dc = {read = "chargeLimitDcPct", write = "charge", frames = "set 0x0C18 [5]; read item 0x22, 0x8C01 [51]"},
	ac_current = {read = "acChargingCurrentPct", write = "charge", unreported_ok = true, frames = "set 0x0C5B; read 0x8C50 [0], item 0x51"},
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
## The AC current's choices as the car's % of the charger's.
const AC_CURRENT_PCT := {max = 100, reduced = 90, min = 60}
const OFF_PEAK_MODES := ["off", "prioritize_off_peak", "off_peak_only"]
## Each schedule setting's key in SetEvSchedule's `set`.
const SCHEDULE_KEYS := {departure_1 = "departure1", departure_2 = "departure2", off_peak = "offPeak",
	off_peak_mode = "chargingMode", scheduled_climate = "climate", climate_defog = "climateDefrost"}
## Each charge setting's key in SetEvCharge's `set`.
const CHARGE_KEYS := {charge_limit_ac = "chargeLimitAcPct", charge_limit_dc = "chargeLimitDcPct",
	ac_current = "chargingCurrentPct"}

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
	if t.get(field) == null and not SETTINGS[id].get("unreported_ok", false):
		return "unreported"
	return "ok" if writable(id) and blocked(id, t) == "" else "read_only"


## Whether the car has said: true for a setting with no read path.
static func reported(id: String, t: Dictionary) -> bool:
	return _field(id) == "" or t.get(_field(id)) != null


static func value(id: String, t: Dictionary) -> Variant:
	var field := _field(id)
	return null if field == "" else _from_car(id, t.get(field))


## A value as the car link gives it, in the row's terms.
static func _from_car(id: String, v: Variant) -> Variant:
	if id == "ac_current" and (v is int or v is float):
		return AC_CURRENT_PCT.find_key(int(v))
	return v


static func writable(id: String) -> bool:
	return fake or str(SETTINGS[id].write) != ""


## Why a setting LIVI can set takes no change now, "" when it does. The schedules and charge
## settings: only with micom-livi's opt-in, parked, and one change of each at a time; the AC
## current, as stock, only while the on-board charger is ready.
static func blocked(id: String, t: Dictionary) -> String:
	var kind := str(SETTINGS[id].write)
	match kind:
		"schedule":
			if t.get("evScheduleWrites") != true:
				return "Read only: the car link does not set schedules (micom-livi -ev-schedule-writes)"
		"charge":
			if t.get("evChargeWrites") != true:
				return "Read only: the car link does not set charging (micom-livi -ev-charge-writes)"
		_:
			return ""
	if Drive.moving:
		return "Read only while driving"
	if pending(kind) != null:
		return "Sending to the car…"
	if id == "ac_current" and t.get("chargerReady") != true:
		return "Read only until the charger is ready"
	return ""


## The change of `kind` ("schedule", "charge") on its way to the car (`set` of SetEvSchedule or
## SetEvCharge), null for none.
static func pending(kind := "schedule") -> Variant:
	var r = Core.get_value("/%s/request" % _section(kind))
	return r.get("set") if r is Dictionary else null


## The value on its way to the car for a setting, in the row's terms, as [value]; [] for none.
static func pending_value(id: String) -> Array:
	var kind := str(SETTINGS[id].write)
	var key: String = (SCHEDULE_KEYS if kind == "schedule" else CHARGE_KEYS).get(id, "")
	var p = pending(kind) if kind in ["schedule", "charge"] else null
	if not (p is Dictionary and key != "" and p.has(key)):
		return []
	return [_from_car(id, p[key])]


## Why the car did not take the last change of `kind`, "" when it did or none was made.
static func failed(kind := "schedule") -> String:
	var last = Core.get_value("/%s/last" % _section(kind))
	if last is Dictionary and last.get("ok") == false:
		return str(last.get("why", ""))
	return ""


static func _section(kind: String) -> String:
	return "evCharge" if kind == "charge" else "evSchedule"


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
		"charge":
			var pct: int = AC_CURRENT_PCT[v] if id == "ac_current" else roundi(float(v))
			return Core.act({kind = "setEvCharge", set = {CHARGE_KEYS[id]: pct}})
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
