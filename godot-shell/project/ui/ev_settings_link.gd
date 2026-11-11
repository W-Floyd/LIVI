class_name EvSettingsLink
## What the EV settings page reads from the car and sends to it, per setting. `read` is the
## telemetry field the core carries for it today; `proposed` the field it would take once
## micom-livi decodes it (the core drops fields it does not know). `write` is how a change
## reaches the car: "core" through LIVI's own action, which micom-livi sends to the micom only
## with its opt-in -precondition; "" none yet, the page shows the setting read-only or
## unavailable. `frames` names the micom messages (docs/ev-settings.md has the evidence).

const SETTINGS := {
	charge_limit_ac = {read = "chargeLimitAcPct", write = "", frames = "set 0x0C18 [4]; read item 0x21, 0x8C01 [50]"},
	charge_limit_dc = {read = "chargeLimitDcPct", write = "", frames = "set 0x0C18 [5]; read item 0x22, 0x8C01 [51]"},
	ac_current = {proposed = "acChargingCurrent", write = "", frames = "set 0x0C5B; read 0x8C50 [0], item 0x51"},
	departure_1 = {proposed = "departure1", write = "", frames = "set 0x0C06; read 0x8C55, 0x8C0F"},
	departure_2 = {proposed = "departure2", write = "", frames = "set 0x0C06; read 0x8C55, 0x8C53 [0]"},
	scheduled_charging = {proposed = "scheduledCharging", write = "", frames = "set 0x0C05 [4]; read 0x8C4A [3], 0x8C53 [5]"},
	off_peak = {proposed = "offPeak", write = "", frames = "set 0x0C05 [0..3]; read 0x8C53 [1..2]"},
	off_peak_mode = {proposed = "offPeakMode", write = "", frames = "set 0x0C05 [4]; read 0x8C53 [5]"},
	scheduled_climate = {proposed = "scheduledClimate", write = "", frames = "set 0x0C06 [4..6]; read 0x8C53 [7]"},
	climate_temp = {proposed = "scheduledClimateC", write = "", frames = "set 0x0C06 [4..6]; read 0x8C53 [7] b7:2"},
	climate_defog = {proposed = "scheduledClimateDefog", write = "", frames = "set 0x0C06 [5..6]; read 0x8C54 [0]"},
	battery_conditioning = {read = "batteryConditioningMode", write = "core", frames = "set 0x0C62 (micom-livi -precondition); read item 0x63"},
	winter_mode = {proposed = "winterMode", write = "", frames = "set 0x0C18 [2]; read item 0x44, 0x8C1A [6]"},
	v2l_limit = {proposed = "v2lDischargeLimitPct", write = "", frames = "set 0x0C5A; read item 0x50"},
	utility_mode = {proposed = "utilityMode", write = "", frames = "set 0x0C5D; read item 0x58, 0x59"},
}
const AC_CURRENT := ["max", "reduced", "min"]
const OFF_PEAK_MODES := ["priority", "only"]

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
	return "ok" if writable(id) else "read_only"


static func value(id: String, t: Dictionary) -> Variant:
	var field := _field(id)
	return null if field == "" else t.get(field)


static func writable(id: String) -> bool:
	return fake or str(SETTINGS[id].write) != ""


## Sends a change; "" when it went, else why not.
static func write(id: String, v: Variant) -> String:
	if fake and str(SETTINGS[id].write) == "":
		written.append([id, v])
		return ""
	match str(SETTINGS[id].write):
		"core":
			return _write_core(id, v)
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
