extends Node
## Runs YAML scenarios against the shell with a fake core; see godot-shell/PLAN.md, "Testing".
##   godot --path project --fixed-fps 60 -- --test <dir|file.yaml> [--update-goldens] [--shots-only]

const SHELL := preload("res://shell.tscn")
const DEFAULT_CLOCK := "2026-01-01T08:00:00"
const DEFAULT_TOLERANCE := 8
const SOCKET := "livi-shell-test"
## Wall time a client gets to show its first frame: a process start is not counted in frames.
const WINDOW_TIMEOUT_MS := 5000

var _tests: String
var _out: String
var _update := false
var _shots_only := false
var _rows: Array[Dictionary] = []
var _failed := 0

var _vp: SubViewport
var _shell: Control
var _scenario: String
var _client_bin: String
var _clients: Array[int] = []

## Flow recording, for review and docs; never compared. Only with --record.
const RECORD_MAX_FRAMES := 1800
const TAP_MARK_FRAMES := 18
var _record := false
var _rec_dir := ""
var _rec_frame := 0
var _rec_hold := 30
var _rec_marks: Array[Dictionary] = []
var _tap_ring: Image


func run(args: PackedStringArray) -> void:
	var root := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	_tests = root.path_join("tests")
	_out = root.path_join("out")
	_update = args.has("--update-goldens")
	_shots_only = args.has("--shots-only")
	_record = args.has("--record")
	var i := args.find("--test")
	var target := _tests.path_join("scenarios")
	for a in args.slice(i + 1):
		if not a.begins_with("--"):
			target = _resolve(a)
			break
	_client_bin = OS.get_environment("SHELL_TEST_CLIENT")
	if _client_bin == "":
		_client_bin = root.path_join("ext/target/release/livi-shell-test-client")
	# Desktop entries in fixtures run the client by name.
	OS.set_environment("PATH", _client_bin.get_base_dir() + ":" + OS.get_environment("PATH"))
	var err: String = Wayland.listen(SOCKET)
	if err != "":
		_fail("", "", "compositor: %s" % err)
	var files := _scenarios(target)
	if files.is_empty():
		_fail("", "", "no scenarios at %s" % target)
	for f in files:
		var e := await _run_one(f)
		if e != "":
			_fail(_scenario, "", e)
		await _teardown()
	_write_report()
	print("%d scenario(s), %d failure(s); report: %s" % [files.size(), _failed, _out.path_join("report.html")])
	get_tree().quit(1 if _failed > 0 else 0)


func _resolve(p: String) -> String:
	if p.is_absolute_path():
		return p
	var cwd := OS.get_environment("PWD")
	for base in [cwd, _tests.path_join("scenarios")]:
		var full: String = base.path_join(p).simplify_path()
		if FileAccess.file_exists(full) or DirAccess.dir_exists_absolute(full):
			return full
		if FileAccess.file_exists(full + ".yaml"):
			return full + ".yaml"
	return p


func _scenarios(target: String) -> PackedStringArray:
	if FileAccess.file_exists(target):
		return [target]
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(target):
		if f.ends_with(".yaml"):
			out.append(target.path_join(f))
	out.sort()
	return out


func _run_one(path: String) -> String:
	_scenario = path.get_file().get_basename()
	var sc = ShellTest.load_yaml(FileAccess.get_file_as_string(path))
	if sc is String:
		return "%s: %s" % [path, sc]
	_scenario = sc.get("name", _scenario)
	print("scenario %s" % _scenario)

	var fixtures: Dictionary = sc.get("fixtures", {})
	# Packs from the scenario's own folder, else the user's; a scenario that needs a pack only
	# the developer has is skipped where it is missing.
	ThemeManager.packs_dir = _tests.path_join(fixtures.packs) if fixtures.has("packs") else ThemeManager.default_packs_dir()
	var needs: String = sc.get("requires", {}).get("theme", "")
	if needs != "" and not ThemeManager.has_theme(needs):
		print("skipped: no theme %s in %s" % [needs, ThemeManager.packs_dir])
		_rows.append({scenario = _scenario, shot = "", status = "skipped", msg = "no theme %s" % needs})
		return ""
	if sc.get("requires", {}).get("car", false) and EvCar.load_model("auto") == null:
		print("skipped: no car.mesh")
		_rows.append({scenario = _scenario, shot = "", status = "skipped", msg = "no car.mesh"})
		return ""
	# The launcher lists only the fixture's apps (and its apps.yaml), and never Waydroid's.
	if fixtures.has("apps"):
		var apps := _tests.path_join(fixtures.apps)
		OS.set_environment("LIVI_SHELL_APPS_DIRS", apps)
		OS.set_environment("LIVI_SHELL_APPS", apps.path_join("apps.yaml"))
		OS.set_environment("LIVI_SHELL_APP_LOGS", _out.path_join(_scenario))
	else:
		for k in ["LIVI_SHELL_APPS_DIRS", "LIVI_SHELL_APPS", "LIVI_SHELL_APP_LOGS"]:
			OS.unset_environment(k)
	var state = {}
	if fixtures.has("core"):
		state = JSON.parse_string(FileAccess.get_file_as_string(_tests.path_join(fixtures.core)))
		if state == null:
			return "fixture %s does not parse" % fixtures.core
	# Counts from an earlier scenario's windows would pass for this one's.
	Wayland.reset_stats()
	var err: String = Core.start_fake(state)
	if err != "":
		return "fake core: %s" % err

	Clock.fix(Time.get_unix_time_from_datetime_string(str(sc.get("clock", DEFAULT_CLOCK))))
	var vp: Dictionary = sc.get("viewport", {width = 1920, height = 720})
	_vp = SubViewport.new()
	_vp.size = Vector2i(vp.width, vp.height)
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	# Each scenario starts from the default look, then its own `theme:`.
	ThemeManager.defaults()
	Drive.reset()
	var look: Dictionary = sc.get("theme", {})
	if sc.has("appearance"):
		look.appearance = sc.appearance
	var bad := _look_error(look)
	if bad != "":
		return bad
	ThemeManager.set_look(look)
	_shell = SHELL.instantiate()
	_vp.add_child(_shell)
	# `nav: true`: the docked rail, as LIVI_SHELL_NAV has it.
	if sc.get("nav", false):
		NavRail.attach(_shell)
	await _frames(1)
	for c in fixtures.get("clients", []):
		var e := _spawn(c)
		if e != "":
			return e

	for step in sc.get("steps", []):
		var e := await _step(step)
		if e != "":
			return "%s: %s" % [JSON.stringify(step), e]
		# A recording holds after each step so a viewer can follow; test runs are unaffected.
		if _rec_dir != "":
			await _frames(_rec_hold)
	return ""


## `{ role: app, app_id, pattern, size: WxH, animate: N, buffer: shm|dmabuf|nv12|i420, video: true,
## honour: none|fractional|integer, scale: percent }` as a test client process, or
## `{ role: command, run: [program, args...] }` for a real one, such as weston-terminal.
func _spawn(c: Dictionary) -> String:
	var bin := _client_bin
	var args := PackedStringArray()
	match c.get("role", "app"):
		"app":
			args = [
				"--app-id", c.get("app_id", "org.livi.test"),
				"--pattern", c.get("pattern", "grid"), "--size", c.get("size", "640x360")]
			if c.has("title"):
				args.append_array(["--title", c.title])
			if c.has("animate"):
				args.append_array(["--animate", str(int(c.animate))])
			if c.has("buffer"):
				args.append_array(["--buffer", c.buffer])
			if c.get("video", false):
				args.append("--video")
			if c.has("honour"):
				args.append_array(["--honour", c.honour])
			if c.has("text_input"):
				args.append_array(["--text-input", c.text_input])
			if c.get("events", false):
				DirAccess.make_dir_recursive_absolute(_out.path_join(_scenario))
				args.append_array(["--events", _client_events(c.get("app_id", "org.livi.test"))])
		"command":
			var run: Array = c.get("run", [])
			if run.is_empty():
				return "a command client needs run: [program, args...]"
			bin = run[0]
			args = PackedStringArray(run.slice(1))
		var r:
			return "client role %s: app or command" % r
	OS.set_environment("WAYLAND_DISPLAY", Wayland.socket_name())
	var pid := OS.create_process(bin, args)
	if pid <= 0:
		return "could not start %s" % bin
	_clients.append(pid)
	if c.has("scale"):
		Wayland.set_process_scale(pid, float(c.scale) / 100.0)
	return ""


## Waits until the killed clients' windows are gone, so the next scenario starts with an empty
## compositor: a stale window would satisfy its wait-for-window.
func _teardown() -> void:
	_record_stop()
	for pid in _clients:
		OS.kill(pid)
		Wayland.set_process_scale(pid, 0)
	_clients.clear()
	if _shell:
		_shell.launcher.stop_all()
	var until := Time.get_ticks_msec() + WINDOW_TIMEOUT_MS
	while Wayland.window_count() > 0 and Time.get_ticks_msec() < until:
		await _frames(1)
	if Wayland.window_count() > 0:
		push_error("windows outlived their clients: %d" % Wayland.window_count())
	if _vp:
		_vp.queue_free()
		_vp = null
	_shell = null


func _step(step: Dictionary) -> String:
	if step.size() != 1:
		return "a step has one key"
	var kind: String = step.keys()[0]
	var arg = step[kind]
	match kind:
		"wait":
			if arg.has("window"):
				return await _wait_window(arg.window)
			await _frames(int(arg.get("frames", 1)))
		"tap":
			var at = _point(arg)
			if at is String:
				return at
			if arg.get("with", "mouse") == "touch":
				await _touch(at)
			else:
				await _tap(at)
		"key":
			await _key(str(arg))
		"set":
			for e in _set_core(arg.get("core", {}), ""):
				return e
		"expect_action":
			return _expect("action", "action", ShellTest.action_from_scenario(arg))
		"expect_input":
			return _expect("input", "input", _input_from_scenario(arg))
		"expect_node":
			return _expect_node(arg)
		"expect_client":
			return await _expect_client(arg)
		"record":
			if str(arg) == "stop":
				_record_stop()
			else:
				_rec_hold = int(arg.get("hold_frames", 30)) if arg is Dictionary else 30
				_record_start(arg.name if arg is Dictionary else str(arg))
		"screenshot":
			return await _screenshot(arg if arg is Dictionary else {name = arg})
		"measure":
			return await _measure(arg)
		"page":
			var shown: String = _shell.open_page(str(arg))
			if shown != "":
				return shown
			await _frames(2)
		"compare_reference":
			return await _compare_reference(arg)
		"theme":
			var bad := _look_error(arg)
			if bad != "":
				return bad
			ThemeManager.set_look(arg)
			# A frame to restyle, one to lay out.
			await _frames(2)
		"gdscript":
			return await _gdscript(str(arg))
		_:
			return "unknown step"
	return ""


## For what the other steps cannot say. The block is the body of `func run(shell, runner)`:
## it may await (runner.frames(n)), and returns an error String, or nothing to pass.
func _gdscript(body: String) -> String:
	# Spaces, as the YAML block's own nesting is in spaces and GDScript refuses a mix.
	var src := "extends RefCounted\n\n\nfunc run(shell: Control, runner: Node) -> Variant:\n"
	for line in body.split("\n"):
		src += "    " + line + "\n"
	src += "    return null\n"
	var script := GDScript.new()
	script.source_code = src
	var err := script.reload()
	if err != OK:
		return "does not compile (%s); Godot's error is above" % error_string(err)
	var r = await script.new().run(_shell, self)
	return "" if r == null or str(r) == "" else str(r)


## For gdscript steps.
func frames(n: int) -> void:
	await _frames(n)


## `{ name, frames: N, expect: { <profile>: { <metric>: max } } }`: runs N frames as fast as
## they go and records what they cost. Thresholds are per profile (SHELL_PERF_PROFILE, default
## vm), since llvmpipe's numbers say nothing about the unit's. Every metric is a maximum.
func _measure(arg: Dictionary) -> String:
	var name: String = arg.get("name", "measure")
	var n := int(arg.get("frames", 120))
	var rid := _vp.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	await _frames(1)
	Wayland.reset_stats()
	var cpu0 := _cpu_seconds()
	var t0 := Time.get_ticks_usec()
	var frame_ms := PackedFloat64Array()
	var render_ms := PackedFloat64Array()
	var last := t0
	for i in n:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		frame_ms.append((now - last) / 1000.0)
		render_ms.append(RenderingServer.viewport_get_measured_render_time_cpu(rid))
		last = now
	var wall := (Time.get_ticks_usec() - t0) / 1e6
	RenderingServer.viewport_set_measure_render_time(rid, false)
	frame_ms.sort()
	render_ms.sort()
	var m := {
		frames = n,
		fps = n / wall,
		frame_ms_p50 = _pct(frame_ms, 0.5),
		frame_ms_p95 = _pct(frame_ms, 0.95),
		frame_ms_max = frame_ms[-1],
		render_cpu_ms_p95 = _pct(render_ms, 0.95),
		cpu_pct = 100.0 * (_cpu_seconds() - cpu0) / wall,
		rss_mb = _rss_mb(),
	}
	var stats: Dictionary = Wayland.stats()
	for k in stats:
		if k != "frames":
			m[k] = stats[k]
	for app_id in stats.frames:
		m["client_fps:" + app_id] = stats.frames[app_id] / wall
	var dir := _out.path_join(_scenario)
	DirAccess.make_dir_recursive_absolute(dir)
	FileAccess.open(dir.path_join(name + ".metrics.json"), FileAccess.WRITE).store_string(
		JSON.stringify(m, "  ", false))
	var profile := OS.get_environment("SHELL_PERF_PROFILE")
	profile = profile if profile != "" else "vm"
	var limits: Dictionary = arg.get("expect", {}).get(profile, {})
	var over := PackedStringArray()
	for k in limits:
		if not m.has(k):
			over.append("%s: no such metric" % k)
		elif m[k] > limits[k]:
			over.append("%s %.2f > %.2f" % [k, m[k], limits[k]])
	var row := {scenario = _scenario, shot = name, status = "ok", msg = "", metrics = m}
	_rows.append(row)
	if not over.is_empty():
		row.status = "fail"
		row.msg = "over the %s limits: %s" % [profile, ", ".join(over)]
		return row.msg
	return ""


func _pct(sorted: PackedFloat64Array, p: float) -> float:
	return sorted[clampi(int(ceil(p * sorted.size())) - 1, 0, sorted.size() - 1)]


## User and system time of this process, from /proc (Linux).
func _cpu_seconds() -> float:
	var f := FileAccess.open("/proc/self/stat", FileAccess.READ)
	if f == null:
		return 0.0
	# Fields after the command name, which is in parentheses and may hold spaces. get_line, as
	# /proc files report no length and get_as_text reads nothing.
	var rest := f.get_line().get_slice(") ", 1).split(" ")
	return (int(rest[11]) + int(rest[12])) / 100.0


func _rss_mb() -> float:
	var f := FileAccess.open("/proc/self/status", FileAccess.READ)
	if f == null:
		return 0.0
	while not f.eof_reached():
		var line := f.get_line()
		if line.begins_with("VmRSS:"):
			return int(line.split(" ", false)[1]) / 1024.0
	return 0.0


func _wait_window(app_id: String) -> String:
	var until := Time.get_ticks_msec() + WINDOW_TIMEOUT_MS
	while Wayland.find_window(app_id) < 0:
		if Time.get_ticks_msec() > until:
			return "no window %s within %d ms" % [app_id, WINDOW_TIMEOUT_MS]
		await _frames(1)
	# The frame it mapped in has been drawn into the texture; one more puts it on screen.
	await _frames(1)
	return ""


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _point(arg) -> Variant:
	if arg.has("node"):
		var n := _shell.get_node_or_null(NodePath(arg.node))
		if not n is Control:
			return "no Control at %s" % arg.node
		return (n as Control).get_global_rect().get_center()
	if arg.has("x") and arg.has("y"):
		return Vector2(arg.x, arg.y)
	return "tap needs node, or x and y"


## `record: name` starts, `record: stop` (or the scenario's end) stops. Frames go to
## out/<scenario>/<name>.frames/ as JPEG; test.sh encodes them to <name>.mp4.
func _record_start(name: String) -> void:
	_record_stop()
	if not _record:
		return
	_rec_dir = _out.path_join(_scenario).path_join(name + ".frames")
	DirAccess.make_dir_recursive_absolute(_rec_dir)
	_rec_frame = 0
	_rec_marks.clear()
	_rows.append({scenario = _scenario, shot = name, status = "recorded", msg = "",
		video = _out.path_join(_scenario).path_join(name + ".mp4")})
	RenderingServer.frame_post_draw.connect(_record_frame)


func _record_stop() -> void:
	if RenderingServer.frame_post_draw.is_connected(_record_frame):
		RenderingServer.frame_post_draw.disconnect(_record_frame)
	_rec_dir = ""


func _record_frame() -> void:
	if _vp == null or _rec_frame >= RECORD_MAX_FRAMES:
		return
	var img := _vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	var ring := _ring()
	for m in _rec_marks:
		var r := Rect2i(Vector2i.ZERO, ring.get_size())
		img.blend_rect(ring, r, Vector2i(m.pos) - ring.get_size() / 2)
		m.age += 1
	_rec_marks = _rec_marks.filter(func(m): return m.age < TAP_MARK_FRAMES)
	_rec_frame += 1
	img.save_jpg(_rec_dir.path_join("%05d.jpg" % _rec_frame), 0.9)


## A white ring with a dark edge, readable on any theme, drawn where a tap lands.
func _ring() -> Image:
	if _tap_ring:
		return _tap_ring
	var size := 76
	_tap_ring = Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := Vector2(size, size) / 2.0
	for y in size:
		for x in size:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(c)
			if d >= 27 and d < 33:
				_tap_ring.set_pixel(x, y, Color(1, 1, 1, 0.9))
			elif d >= 24 and d < 36:
				_tap_ring.set_pixel(x, y, Color(0, 0, 0, 0.55))
	return _tap_ring


## A finger: touch events only, as the panel sends them (no emulated mouse, which a pushed
## event does not get).
func _touch(at: Vector2) -> void:
	if _rec_dir != "":
		_rec_marks.append({pos = at, age = 0})
	for pressed in [true, false]:
		var ev := InputEventScreenTouch.new()
		ev.index = 0
		ev.position = at
		ev.pressed = pressed
		_vp.push_input(ev)
		await _frames(1)


## `{ theme_name, appearance, appearance_mode, hand, near, text_scale, material, reduced_motion, quality, ev_page, car }`,
## any of them.
func _look_error(look: Dictionary) -> String:
	const KEYS := {
		theme_name = null, appearance = ["day", "night"], appearance_mode = ["auto", "day", "night"],
		hand = ["lhd", "rhd"], near = ["projection", "panel"], text_scale = null,
		material = ["solid", "frosted", "glass"], reduced_motion = [true, false],
		quality = ["normal", "low"], ev_page = ["auto", "image", "live"], car = ["auto", "procedural"], volume_style = ["card", "glow"], home_phone = null,
		status_position = ["top", "bottom", "left", "right", "off"]}
	for k in look:
		if not KEYS.has(k):
			return "theme: unknown key %s" % k
		if k == "theme_name":
			if not ThemeManager.has_theme(str(look[k])):
				return "theme: no theme %s" % look[k]
		elif KEYS[k] != null and not look[k] in KEYS[k]:
			return "theme: %s is one of %s" % [k, KEYS[k]]
	return ""


## `{ app_id, lines: [...] }`: the client logged these input events, in this order (others may
## come between). Clients log as events arrive, so this waits up to a second for them.
func _expect_client(arg: Dictionary) -> String:
	var path := _client_events(arg.get("app_id", ""))
	var want: Array = arg.get("lines", [])
	var got := PackedStringArray()
	for i in 60:
		got = FileAccess.get_file_as_string(path).strip_edges().split("\n", false)
		var n := 0
		for line in got:
			if n < want.size() and line == want[n]:
				n += 1
		if n == want.size():
			return ""
		await _frames(1)
	return "client got %s" % JSON.stringify(got)


func _client_events(app_id: String) -> String:
	return _out.path_join(_scenario).path_join(app_id + ".events")


func _tap(at: Vector2) -> void:
	if _rec_dir != "":
		_rec_marks.append({pos = at, age = 0})
	var move := InputEventMouseMotion.new()
	move.position = at
	_vp.push_input(move)
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.position = at
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		ev.pressed = pressed
		_vp.push_input(ev)
		await _frames(1)


func _key(code: String) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = OS.find_keycode_from_string(code)
		ev.physical_keycode = ev.keycode
		ev.pressed = pressed
		_vp.push_input(ev)
		await _frames(1)


## Nested maps to one fake_set per leaf, so a step only touches what it names.
func _set_core(tree: Dictionary, prefix: String) -> PackedStringArray:
	var errs := PackedStringArray()
	for k in tree:
		var path := prefix.path_join(k) if prefix != "" else str(k)
		if tree[k] is Dictionary and not tree[k].is_empty():
			errs.append_array(_set_core(tree[k], path))
		else:
			var e: String = Core.fake_set(path, tree[k])
			if e != "":
				errs.append("%s: %s" % [path, e])
	return errs


## `{ pointer: { screen, x, y, phase } }` to the wire's one-point pointer input.
func _input_from_scenario(arg: Dictionary) -> Variant:
	if arg.has("pointer"):
		var p: Dictionary = arg.pointer
		var point := {}
		for k in ["x", "y", "phase", "id"]:
			if p.has(k):
				point[k] = p[k]
		return {kind = "pointer", screen = p.get("screen", "main"), points = [point]}
	if arg.has("key"):
		return {kind = "key"}.merged(arg.key)
	return "expect_input needs pointer or key"


## Passes when a message sent since the last expectation matches; those are then consumed.
func _expect(type: String, field: String, want) -> String:
	if want is String:
		return want
	var sent: Array = Core.fake_sent()
	for m in sent:
		if m.get("type") == type and ShellTest.subset(want, m.get(field)):
			Core.fake_clear()
			return ""
	var got := sent.filter(func(m): return m.get("type") == type)
	return "not sent; sent %s" % JSON.stringify(got)


func _expect_node(arg: Dictionary) -> String:
	var n := _shell.get_node_or_null(NodePath(arg.get("path", "")))
	if n == null:
		return "no node"
	for k in arg:
		if k == "rect":
			# [x, y, w, h] in panel pixels.
			var want := Rect2(arg[k][0], arg[k][1], arg[k][2], arg[k][3])
			var got: Rect2 = n.get_global_rect() if n is Control else Rect2()
			if not (got.position.is_equal_approx(want.position) and got.size.is_equal_approx(want.size)):
				return "rect is %s" % got
		elif k != "path" and str(n.get(k)) != str(arg[k]):
			return "%s is %s" % [k, str(n.get(k))]
	return ""


func _screenshot(arg: Dictionary) -> String:
	var name: String = arg.name
	await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	var dir := _out.path_join(_scenario)
	DirAccess.make_dir_recursive_absolute(dir)
	# Captures go to disk only when someone will look at them: a pass compares in memory.
	var shot := dir.path_join(name + ".png")
	# Lossless WebP: a third of PNG's size in git, and decoded exactly.
	var golden_path := _tests.path_join("goldens").path_join(name + ".webp")
	var row := {scenario = _scenario, shot = name, new = shot, golden = golden_path, status = "ok", msg = ""}
	_rows.append(row)
	if _update and arg.get("compare", true):
		DirAccess.make_dir_recursive_absolute(golden_path.get_base_dir())
		img.save_webp(golden_path, false)
		row.status = "updated"
		return ""
	if _shots_only or not arg.get("compare", true):
		img.save_png(shot)
		row.status = "shot"
		return ""
	if not FileAccess.file_exists(golden_path):
		row.status = "fail"
		row.msg = "no golden; run with --update-goldens"
		return row.msg
	var golden := Image.load_from_file(golden_path)
	var mask: Array[Rect2i] = []
	for r in arg.get("mask", []):
		mask.append(Rect2i(r[0], r[1], r[2], r[3]))
	var cmp: Dictionary = ShellTest.compare_images(golden, img, int(arg.get("tolerance", DEFAULT_TOLERANCE)), mask)
	if cmp.has("error"):
		img.save_png(shot)
		row.status = "fail"
		row.msg = cmp.error
		return row.msg
	if cmp.differing > int(arg.get("max_pixels", 0)):
		img.save_png(shot)
		row.status = "fail"
		row.diff = dir.path_join(name + ".diff.png")
		cmp.diff.save_png(row.diff)
		row.msg = "%d pixels differ" % cmp.differing
		return row.msg
	return ""


## `{ name, reference, tolerance, min, mask }`: the share of pixels within `tolerance` of a
## reference image must be at least `min`. The reference is a path, relative to the theme's
## pack (else to tests/). The render and the diff are written to out/, never to goldens.
func _compare_reference(arg: Dictionary) -> String:
	var name: String = arg.name
	var path: String = str(arg.reference)
	if not path.is_absolute_path():
		var base: String = ThemeManager.pack.dir if ThemeManager.pack else _tests
		path = base.path_join(path)
	var dir := _out.path_join(_scenario)
	var row := {scenario = _scenario, shot = name, golden = path, new = dir.path_join(name + ".png"), status = "ok", msg = ""}
	_rows.append(row)
	await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(dir)
	img.save_png(row.new)
	var ref := Image.load_from_file(path) if FileAccess.file_exists(path) else null
	if ref == null:
		row.status = "fail"
		row.msg = "no reference at %s" % path
		return row.msg
	var mask: Array[Rect2i] = []
	for r in arg.get("mask", []):
		mask.append(Rect2i(r[0], r[1], r[2], r[3]))
	var tol := int(arg.get("tolerance", DEFAULT_TOLERANCE))
	var cmp: Dictionary = ShellTest.compare_images(ref, img, tol, mask)
	if cmp.has("error"):
		row.status = "fail"
		row.msg = cmp.error
		return row.msg
	row.diff = dir.path_join(name + ".diff.png")
	cmp.diff.save_png(row.diff)
	var share := 1.0 - float(cmp.differing) / maxf(1.0, cmp.compared)
	var want := float(arg.get("min", 0.98))
	row.msg = "%.2f%% of %d pixels within %d (needs %.2f%%)" % [share * 100.0, cmp.compared, tol, want * 100.0]
	print("compare_reference %s: %s" % [name, row.msg])
	if share < want:
		row.status = "fail"
		return row.msg
	return ""


func _fail(scenario: String, shot: String, msg: String) -> void:
	_failed += 1
	push_error("FAIL %s %s" % [scenario, msg])
	if shot == "" and not _rows.any(func(r): return r.scenario == scenario and r.status == "fail"):
		_rows.append({scenario = scenario, shot = "", status = "fail", msg = msg})


func _write_report() -> void:
	DirAccess.make_dir_recursive_absolute(_out)
	var h := PackedStringArray([
		"<!doctype html><meta charset=utf-8><title>Shell scenarios</title><style>",
		"body{font:14px system-ui;margin:16px}img{width:32%;margin-right:1%}",
		".fail{color:#b00}.ok,.updated,.shot{color:#070}.skipped{color:#888}</style>",
		"<h1>%d failure(s)</h1>" % _failed,
	])
	for r in _rows:
		h.append("<h2>%s / %s <span class=%s>%s</span></h2><p>%s</p>" % [
			r.scenario, r.shot, r.status, r.status, r.msg.xml_escape()])
		if r.has("golden"):
			for k in ["golden", "new", "diff"]:
				if r.has(k) and FileAccess.file_exists(r[k]):
					h.append("<img title=%s src='file://%s'>" % [k, r[k].uri_encode().replace("%2F", "/")])
		if r.has("video"):
			h.append("<video controls muted loop width=960 src='file://%s'></video>" % r.video.uri_encode().replace("%2F", "/"))
		if r.has("metrics"):
			h.append("<table>")
			for k in r.metrics:
				var v = r.metrics[k]
				h.append("<tr><td>%s<td>%s" % [k, "%.2f" % v if v is float else str(v)])
			h.append("</table>")
	var f := FileAccess.open(_out.path_join("report.html"), FileAccess.WRITE)
	f.store_string("\n".join(h))
