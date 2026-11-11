class_name Units
## Values in the units LIVI's config sets, as stock LIVI shows them (livi-ui-model's
## dashboard readings): temperature follows `temperatureUnit`, distance and speed follow
## `speedUnit`; whole numbers rounded half away from zero. Callers re-format on Core's
## "config" change.

## Stock's factor, not 1/1.609344: values must read the same as LIVI's own screens.
const MI_PER_KM := 0.621371
const FT_PER_M := 3.28084
## Under this a distance reads in the short unit: 1 km, 0.1 mi.
const SHORT_KM := 1.0
const SHORT_MI := 0.1


static func imperial() -> bool:
	return Core.get_value("/config/speedUnit") == "mph"


static func fahrenheit() -> bool:
	return Core.get_value("/config/temperatureUnit") == "fahrenheit"


## "4 °C", "39 °F".
static func temperature(c: float) -> String:
	return "%d %s" % [roundi(c * 9.0 / 5.0 + 32.0 if fahrenheit() else c), "°F" if fahrenheit() else "°C"]


## A range, a whole number in km or mi.
static func range_value(km: float) -> int:
	return roundi(km * MI_PER_KM if imperial() else km)


static func range_unit() -> String:
	return "mi" if imperial() else "km"


## "148 km", "92 mi".
static func range_text(km: float) -> String:
	return "%d %s" % [range_value(km), range_unit()]


## A distance as [value, unit]: whole m or ft when short, else km or mi to one place, with a
## trailing ".0" dropped.
static func distance(km: float) -> PackedStringArray:
	var long := km * MI_PER_KM if imperial() else km
	if long < (SHORT_MI if imperial() else SHORT_KM):
		return PackedStringArray([str(roundi(km * 1000.0 * FT_PER_M if imperial() else km * 1000.0)), "ft" if imperial() else "m"])
	return PackedStringArray([("%.1f" % long).trim_suffix(".0"), range_unit()])


## "740 m", "42 km", "26.1 mi".
static func distance_text(km: float) -> String:
	return " ".join(distance(km))


static func speed_value(kph: float) -> int:
	return roundi(kph * MI_PER_KM if imperial() else kph)


static func speed_unit() -> String:
	return "mph" if imperial() else "km/h"


## "88 km/h", "55 mph".
static func speed_text(kph: float) -> String:
	return "%d %s" % [speed_value(kph), speed_unit()]


## "45 min", "1 h 25 min", "7 h".
static func duration_text(minutes: float) -> String:
	var m := maxi(0, roundi(minutes))
	if m < 60:
		return "%d min" % m
	var h := int(m / 60.0)
	return "%d h" % h if m % 60 == 0 else "%d h %d min" % [h, m % 60]


## "350 W", "1.4 kW".
static func power_text(w: float) -> String:
	if absf(w) < 1000.0:
		return "%d W" % roundi(w)
	return "%s kW" % ("%.1f" % (w / 1000.0)).trim_suffix(".0")
