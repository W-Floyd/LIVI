extends Node
## Runs YAML scenarios against the shell with a fake core; see godot-shell/PLAN.md, "Testing".
##   godot --path project --fixed-fps 60 -- --test <dir|file.yaml> [--update-goldens] [--shots-only]

const SHELL := preload("res://shell.tscn")
const DEFAULT_CLOCK := "2026-01-01T08:00:00"
const DEFAULT_TOLERANCE := 8

var _tests: String
var _out: String
var _update := false
var _shots_only := false
var _rows: Array[Dictionary] = []
var _failed := 0

var _vp: SubViewport
var _shell: Control
var _scenario: String


func run(args: PackedStringArray) -> void:
	var root := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	_tests = root.path_join("tests")
	_out = root.path_join("out")
	_update = args.has("--update-goldens")
	_shots_only = args.has("--shots-only")
	var i := args.find("--test")
	var target := _tests.path_join("scenarios")
	if i + 1 < args.size() and not args[i + 1].begins_with("--"):
		target = _resolve(args[i + 1])
	var files := _scenarios(target)
	if files.is_empty():
		_fail("", "", "no scenarios at %s" % target)
	for f in files:
		var err := await _run_one(f)
		if err != "":
			_fail(_scenario, "", err)
		_teardown()
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
	var state = {}
	if fixtures.has("core"):
		state = JSON.parse_string(FileAccess.get_file_as_string(_tests.path_join(fixtures.core)))
		if state == null:
			return "fixture %s does not parse" % fixtures.core
	var err: String = Core.start_fake(state)
	if err != "":
		return "fake core: %s" % err
	if fixtures.has("clients"):
		return "fixtures.clients needs the compositor (milestone 2)"

	Clock.fix(Time.get_unix_time_from_datetime_string(str(sc.get("clock", DEFAULT_CLOCK))))
	var vp: Dictionary = sc.get("viewport", {width = 1920, height = 720})
	_vp = SubViewport.new()
	_vp.size = Vector2i(vp.width, vp.height)
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	_shell = SHELL.instantiate()
	match sc.get("appearance", "day"):
		"day": _shell.night = false
		"night": _shell.night = true
		var a: return "appearance %s: day or night" % a
	_vp.add_child(_shell)
	await _frames(1)

	for step in sc.get("steps", []):
		var e := await _step(step)
		if e != "":
			return "%s: %s" % [JSON.stringify(step), e]
	return ""


func _teardown() -> void:
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
			await _frames(int(arg.get("frames", 1)))
		"tap":
			var at = _point(arg)
			if at is String:
				return at
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
		"screenshot":
			return await _screenshot(arg if arg is Dictionary else {name = arg})
		_:
			return "unknown step"
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


func _tap(at: Vector2) -> void:
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
		if k != "path" and str(n.get(k)) != str(arg[k]):
			return "%s is %s" % [k, str(n.get(k))]
	return ""


func _screenshot(arg: Dictionary) -> String:
	var name: String = arg.name
	await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	var dir := _out.path_join(_scenario)
	DirAccess.make_dir_recursive_absolute(dir)
	var shot := dir.path_join(name + ".png")
	img.save_png(shot)
	var golden_path := _tests.path_join("goldens").path_join(name + ".png")
	var row := {scenario = _scenario, shot = name, new = shot, golden = golden_path, status = "ok", msg = ""}
	_rows.append(row)
	if _update:
		DirAccess.make_dir_recursive_absolute(golden_path.get_base_dir())
		img.save_png(golden_path)
		row.status = "updated"
		return ""
	if _shots_only:
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
		row.status = "fail"
		row.msg = cmp.error
		return row.msg
	if cmp.differing > int(arg.get("max_pixels", 0)):
		row.status = "fail"
		row.diff = dir.path_join(name + ".diff.png")
		cmp.diff.save_png(row.diff)
		row.msg = "%d pixels differ" % cmp.differing
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
		".fail{color:#b00}.ok,.updated,.shot{color:#070}</style>",
		"<h1>%d failure(s)</h1>" % _failed,
	])
	for r in _rows:
		h.append("<h2>%s / %s <span class=%s>%s</span></h2><p>%s</p>" % [
			r.scenario, r.shot, r.status, r.status, r.msg.xml_escape()])
		if r.has("golden"):
			for k in ["golden", "new", "diff"]:
				if r.has(k) and FileAccess.file_exists(r[k]):
					h.append("<img title=%s src='file://%s'>" % [k, r[k].uri_encode().replace("%2F", "/")])
	var f := FileAccess.open(_out.path_join("report.html"), FileAccess.WRITE)
	f.store_string("\n".join(h))
