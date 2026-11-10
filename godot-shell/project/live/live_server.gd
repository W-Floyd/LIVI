extends Node
## A live view of the shell for tuning from a browser (scripts/live.sh): serves a page, the
## current frame as JPEG, and applies the values it posts. One HTTP request per connection, on
## this thread, between frames.

const PORT := 8765
const PAGES := ["home", "ev", "ev_live", "ev_main"]
const LOOK := {
	appearance = ["day", "night"], hand = ["lhd", "rhd"], near = ["projection", "panel"],
	material = ["solid", "frosted", "glass"], quality = ["normal", "low"],
	ev_page = ["auto", "image", "live"], car = ["auto", "procedural"],
}
## Core values a slider sets: key, label, path, scale to the core's unit, range, step.
const DATA := [
	["fuel", "Charge %", "/telemetry/fuelPct", 1.0, 0.0, 100.0, 1.0],
	["range", "Range km", "/telemetry/rangeKm", 1.0, 0.0, 520.0, 1.0],
	["range_off", "Range off km", "/telemetry/rangeClimateOffKm", 1.0, 0.0, 600.0, 1.0],
	["stop", "Charger km", "/navigation/chargingStop/distanceM", 1000.0, 0.0, 400.0, 0.5],
]

var _tcp := TCPServer.new()
var _conns: Array[Dictionary] = []
var _vp: SubViewport
var _shell: Node
var _page := "ev"
var _data := {}
var _defaults := {}
var _mask := 0
var _last := Vector2.ZERO


func _ready() -> void:
	var state = JSON.parse_string(FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://").path_join("../tests/fixtures/ev6-main.json")))
	var err: String = Core.start_fake(state if state is Dictionary else {})
	if err != "":
		push_error("fake core: %s" % err)
	for d in DATA:
		var v = Core.get_value(d[2])
		_data[d[0]] = float(v) / d[3] if v != null else 0.0
	ThemeManager.defaults()
	ThemeManager.set_look({theme_name = OS.get_environment("LIVE_THEME") if OS.get_environment("LIVE_THEME") != "" else "instrument", appearance = "night", car = "auto"})
	for t in EvScene.tunables():
		_defaults[t.key] = t.value
	_vp = SubViewport.new()
	_vp.size = Vector2i(1920, 720)
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	_shell = preload("res://shell.tscn").instantiate()
	_vp.add_child(_shell)
	var e := _tcp.listen(PORT, "*")
	if e != OK:
		push_error("live: cannot listen on %d (%s)" % [PORT, error_string(e)])
		return
	_open(_page)
	print("live: http://localhost:%d/" % PORT)


func _open(page: String) -> void:
	var e: String = _shell.open_page(page)
	if e != "":
		push_error("live: %s" % e)
	else:
		_page = page


func _process(_delta: float) -> void:
	while _tcp.is_connection_available():
		_conns.append({peer = _tcp.take_connection(), buf = PackedByteArray()})
	for c in _conns.duplicate():
		var peer: StreamPeerTCP = c.peer
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_conns.erase(c)
			continue
		var n := peer.get_available_bytes()
		if n > 0:
			c.buf.append_array(peer.get_data(n)[1])
		if _serve(c):
			peer.disconnect_from_host()
			_conns.erase(c)


## True once the request in `c` is complete and answered.
func _serve(c: Dictionary) -> bool:
	var buf: PackedByteArray = c.buf
	var text := buf.get_string_from_utf8()
	var end := text.find("\r\n\r\n")
	if end < 0:
		return false
	var head := text.substr(0, end)
	var length := 0
	for line in head.split("\r\n"):
		if line.to_lower().begins_with("content-length:"):
			length = int(line.split(":")[1])
	var body_start := end + 4
	if buf.size() - body_start < length:
		return false
	var body := buf.slice(body_start, body_start + length).get_string_from_utf8()
	var first := head.split("\r\n")[0].split(" ")
	var path: String = first[1].split("?")[0]
	var peer: StreamPeerTCP = c.peer
	match [first[0], path]:
		["GET", "/"]:
			_reply(peer, 200, "text/html; charset=utf-8", FileAccess.get_file_as_bytes("res://live/index.html"))
		["GET", "/frame.jpg"]:
			_reply(peer, 200, "image/jpeg", _vp.get_texture().get_image().save_jpg_to_buffer(0.85))
		["GET", "/schema"]:
			_reply(peer, 200, "application/json", JSON.stringify(_schema()).to_utf8_buffer())
		["GET", "/stock.png"]:
			var f := _stock_path()
			if f == "":
				_reply(peer, 404, "text/plain", "none".to_utf8_buffer())
			else:
				_reply(peer, 200, "image/png", FileAccess.get_file_as_bytes(f))
		["POST", "/set"]:
			var d = JSON.parse_string(body)
			if d is Dictionary:
				for k in d:
					_apply(k, d[k])
			_reply(peer, 200, "application/json", "{}".to_utf8_buffer())
		["POST", "/input"]:
			var evs = JSON.parse_string(body)
			if evs is Array:
				for e in evs:
					_pointer(e)
			_reply(peer, 200, "application/json", "{}".to_utf8_buffer())
		["POST", "/reset"]:
			for k in _defaults:
				EvScene.tune(k, _defaults[k])
			_reply(peer, 200, "application/json", "{}".to_utf8_buffer())
		_:
			_reply(peer, 404, "text/plain", "not found".to_utf8_buffer())
	return true


func _reply(peer: StreamPeerTCP, code: int, type: String, body: PackedByteArray) -> void:
	var h := "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n" % [
		code, "OK" if code == 200 else "Not Found", type, body.size()]
	peer.put_data(h.to_utf8_buffer())
	peer.put_data(body)


func _apply(key: String, value) -> void:
	if EvScene.tune(key, float(value) if typeof(value) != TYPE_STRING else 0.0):
		return
	if key == "page":
		_open(str(value))
		return
	if key.begins_with("data."):
		for d in DATA:
			if d[0] == key.substr(5):
				_data[d[0]] = float(value)
				Core.fake_set(d[2], float(value) * d[3])
		return
	if key == "text_scale":
		ThemeManager.set_look({text_scale = float(value)})
	elif key == "theme_name" or LOOK.has(key):
		ThemeManager.set_look({key: value})
		if key == "theme_name" or key == "ev_page" or key == "car":
			_open(_page)


## A pointer event from the page, in panel pixels: `{ t: down | up | move, x, y }`.
func _pointer(e: Dictionary) -> void:
	var pos := Vector2(float(e.get("x", 0)), float(e.get("y", 0)))
	match str(e.get("t", "")):
		"down", "up":
			var b := InputEventMouseButton.new()
			b.button_index = MOUSE_BUTTON_LEFT
			b.pressed = e.t == "down"
			_mask = MOUSE_BUTTON_MASK_LEFT if b.pressed else 0
			b.button_mask = _mask
			b.position = pos
			b.global_position = pos
			_vp.push_input(b)
		"move":
			var m := InputEventMouseMotion.new()
			m.position = pos
			m.global_position = pos
			m.relative = pos - _last
			m.button_mask = _mask
			_vp.push_input(m)
	_last = pos


func _stock_path() -> String:
	var dir := ThemeManager.packs_dir.path_join(ThemeManager.theme_name).path_join("reference")
	var f := dir.path_join("ev_main_%s.png" % ThemeManager.appearance)
	return f if FileAccess.file_exists(f) else ""


func _themes() -> Array:
	var out := []
	var d := DirAccess.open("res://themes")
	if d:
		for f in d.get_files():
			if f.ends_with(".yaml"):
				out.append(f.get_basename())
	var p := DirAccess.open(ThemeManager.packs_dir)
	if p:
		for sub in p.get_directories():
			if FileAccess.file_exists(ThemeManager.packs_dir.path_join(sub).path_join("theme.yaml")):
				out.append(sub)
	out.sort()
	return out


func _schema() -> Array:
	var out := []
	out.append({group = "Page", key = "page", label = "Page", kind = "select", options = PAGES, value = _page})
	out.append({group = "Look", key = "theme_name", label = "Theme", kind = "select", options = _themes(), value = ThemeManager.theme_name})
	for k in LOOK:
		out.append({group = "Look", key = k, label = k.capitalize(), kind = "select", options = LOOK[k], value = str(ThemeManager.get(k))})
	out.append({group = "Look", key = "text_scale", label = "Text scale", min = 0.8, max = 1.6, step = 0.05, value = ThemeManager.text_scale})
	for d in DATA:
		out.append({group = "Data", key = "data." + d[0], label = d[1], min = d[4], max = d[5], step = d[6], value = _data[d[0]]})
	for t in EvScene.tunables():
		var group := "Camera"
		if t.key.begins_with("car_a") or t.key == "car_scale":
			group = "Car"
		elif t.key.begins_with("road"):
			group = "Road"
		t.group = group
		out.append(t)
	return out
