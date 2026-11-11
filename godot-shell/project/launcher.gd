class_name Launcher
extends Node
## The apps the unit can run (`AppCatalog`: desktop entries, Waydroid's apps, apps.yaml), started
## as clients of the shell's compositor, and the hosted windows they and others map. One
## instance per app: opening a running app shows its window. Projection video is not an app.
##   LIVI_SHELL_APPS_DIRS  data dirs to list (':'-separated), instead of the XDG ones
##   LIVI_SHELL_APPS       the apps file, instead of $XDG_CONFIG_HOME/livi-shell/apps.yaml
##   LIVI_SHELL_APP_LOGS   where each app's output goes, instead of $XDG_STATE_HOME/livi-shell/apps

## The list, the running windows or a launch's state changed.
signal changed
## A window to bring forward: a launched app's first, or a running one that was picked.
signal show_window(id: int)

## Grace between asking a window to close, SIGTERM to its process group, and SIGKILL.
const CLOSE_GRACE_S := 3.0
## The scales, in percent, the settings offer apps.
const SCALES := [100, 125, 150, 175, 200]

## `{id, name, icon, argv, cwd, app_ids, source, timeout_s}`, in the order to show.
var apps: Array = []
## Hosted windows by id: `{app_id, title, app}`, `app` the catalog id or "".
var windows := {}
## Window ids, most recently shown last.
var recent: Array[int] = []
## App id -> `{pid, until}` (ticks ms) while its window has not mapped.
var launching := {}
## App id -> why its last launch failed.
var failed := {}

var _catalog := AppCatalog.new()
## App id -> the PID this launcher started it as; its process group is the same number.
var _pids := {}
var _poll_at := 0


func _ready() -> void:
	Wayland.window_mapped.connect(_on_mapped)
	Wayland.window_unmapped.connect(_on_unmapped)
	ThemeManager.changed.connect(_rescale)


func _exit_tree() -> void:
	stop_all()


## Lists the apps again.
func refresh() -> void:
	var dirs := PackedStringArray()
	var env := OS.get_environment("LIVI_SHELL_APPS_DIRS")
	if env != "":
		dirs = env.split(":", false)
	_set_apps(_catalog.scan(dirs, _config_path()))


func config_error() -> String:
	return _catalog.config_error()


func _config_path() -> String:
	var p := OS.get_environment("LIVI_SHELL_APPS")
	if p != "":
		return p
	var base := OS.get_environment("XDG_CONFIG_HOME")
	if base == "":
		base = OS.get_environment("HOME").path_join(".config")
	return base.path_join("livi-shell/apps.yaml")


func _log_path(id: String) -> String:
	var dir := OS.get_environment("LIVI_SHELL_APP_LOGS")
	if dir == "":
		var state := OS.get_environment("XDG_STATE_HOME")
		if state == "":
			state = OS.get_environment("HOME").path_join(".local/state")
		dir = state.path_join("livi-shell/apps")
	return dir.path_join(id + ".log")


func _set_apps(list: Array) -> void:
	apps = list
	for id in windows:
		if windows[id].app == "":
			windows[id].app = _owner_of(windows[id].app_id, id, false)
	changed.emit()


func app(id: String) -> Dictionary:
	for a in apps:
		if a.id == id:
			return a
	return {}


## The app's windows, most recently shown last.
func windows_of(id: String) -> Array:
	return recent.filter(func(w): return windows[w].app == id)


## "running", "launching", "failed" or "".
func state(id: String) -> String:
	if launching.has(id):
		return "launching"
	if not windows_of(id).is_empty():
		return "running"
	return "failed" if failed.has(id) else ""


## Shows the app's window when it runs; otherwise starts it, unless it is starting already.
func open(id: String) -> void:
	var mine := windows_of(id)
	if not mine.is_empty():
		bring(mine[-1])
		return
	if launching.has(id):
		return
	var a := app(id)
	if a.is_empty():
		push_warning("launcher: no app %s" % id)
		return
	failed.erase(id)
	# Toolkits pick X11 or their own default without these; DISPLAY goes so nothing reaches an X server.
	var env := {
		WAYLAND_DISPLAY = Wayland.socket_name(), XDG_RUNTIME_DIR = OS.get_environment("XDG_RUNTIME_DIR"),
		DISPLAY = null, WAYLAND_SOCKET = null, XDG_CURRENT_DESKTOP = "LIVI",
		GDK_BACKEND = "wayland", QT_QPA_PLATFORM = "wayland", SDL_VIDEODRIVER = "wayland",
		CLUTTER_BACKEND = "wayland", MOZ_ENABLE_WAYLAND = "1"}
	var pid: int = _catalog.launch(a.argv, a.cwd, env, _log_path(id))
	if pid < 0:
		failed[id] = "could not start %s" % a.argv[0]
	else:
		print("launcher: %s started as %d at %d %%: %s" % [id, pid, scale_of(id), " ".join(a.argv)])
		# Before the compositor next dispatches, which is when the client can connect.
		Wayland.set_process_scale(pid, scale_of(id) / 100.0)
		_pids[id] = pid
		launching[id] = {pid = pid, until = Time.get_ticks_msec() + int(a.timeout_s) * 1000}
	changed.emit()


func bring(window: int) -> void:
	if not windows.has(window):
		return
	recent.erase(window)
	recent.append(window)
	show_window.emit(window)
	changed.emit()


## Asks the window to close; its app's process group gets SIGTERM, then SIGKILL, if it stays.
func close(window: int) -> void:
	if not windows.has(window):
		return
	Wayland.close(window)
	var pid: int = _pids.get(windows[window].app, -1)
	if pid < 0:
		return
	for kill in [false, true]:
		await get_tree().create_timer(CLOSE_GRACE_S).timeout
		if windows.has(window) and _pids.get(windows[window].app, -1) == pid:
			print("launcher: %s did not close, %s" % [windows[window].app, "SIGKILL" if kill else "SIGTERM"])
			_catalog.stop(pid, kill)


## SIGTERM to everything this launcher started.
func stop_all() -> void:
	for id in _pids:
		_catalog.stop(_pids[id], false)
		Wayland.set_process_scale(_pids[id], 0)
	_pids.clear()
	launching.clear()


func _process(_delta: float) -> void:
	var more = _catalog.poll_scan()
	if more is Array:
		_set_apps(more)
	var now := Time.get_ticks_msec()
	if now < _poll_at:
		return
	_poll_at = now + 250
	var dirty := false
	for id in _pids.keys():
		# Reaps it. One that hands off and exits 0 (waydroid app launch) may still show a window,
		# and its group may live on; one that fails is done.
		var code: int = _catalog.poll(_pids[id])
		if code <= 0:
			continue
		Wayland.set_process_scale(_pids[id], 0)
		_pids.erase(id)
		if launching.has(id):
			launching.erase(id)
			failed[id] = "exited with status %d" % code
			print("launcher: %s %s" % [id, failed[id]])
			dirty = true
	for id in launching.keys():
		if now > launching[id].until:
			launching.erase(id)
			failed[id] = "no window in %d s" % int(app(id).get("timeout_s", 0))
			print("launcher: %s %s" % [id, failed[id]])
			dirty = true
	if dirty:
		changed.emit()


func _on_mapped(id: int, app_id: String, title: String) -> void:
	# livi-gst-host's: the phone's picture, which the projection pages own.
	if app_id.begins_with("livi-video"):
		return
	var owner := _owner_of(app_id, id, true)
	windows[id] = {app_id = app_id, title = title, app = owner}
	recent.append(id)
	if launching.has(owner):
		launching.erase(owner)
		# After the shell has the window too: it connected to the same signal later.
		show_window.emit.call_deferred(id)
	changed.emit()


func _on_unmapped(id: int) -> void:
	if windows.erase(id):
		recent.erase(id)
		changed.emit()


## Which app a window is: a launch waiting for this app_id, or whose process group the client is
## in; then any app by app_id; then, when exactly one launch waits and nothing else claims the
## window, that one (apps whose app_id is none of their names).
func _owner_of(app_id: String, window: int, fresh: bool) -> String:
	var by_id := func(a: Dictionary) -> bool: return Array(a.get("app_ids", [])).has(app_id)
	for id in launching:
		if by_id.call(app(id)):
			return id
	var group: int = _catalog.group_of(Wayland.window_pid(window))
	if group > 0:
		for id in _pids:
			if _pids[id] == group:
				return id
	for a in apps:
		if by_id.call(a):
			return a.id
	if fresh and launching.size() == 1:
		return launching.keys()[0]
	return ""


## The scale, in percent, at which a logical pixel looks from the driver's seat as a desktop's
## does from a desk (`Wayland.default_app_scale`): 175 for this panel from rules.yaml's view_mm.
static func auto_scale() -> int:
	return roundi(Wayland.default_app_scale(float(ThemeManager.rules.get("view_mm", 750))) * 100.0)


## The shell's scale for apps: Settings' choice, else `auto_scale`.
static func default_scale() -> int:
	return ThemeManager.app_scale if ThemeManager.app_scale > 0 else auto_scale()


## The app's scale in percent: its own in Settings, else apps.yaml's `scale`, else the default.
func scale_of(id: String) -> int:
	if ThemeManager.app_scales.has(id):
		return int(ThemeManager.app_scales[id])
	var own := int(app(id).get("scale", 0))
	return own if own > 0 else default_scale()


## The app's own scale, saved with the look; 0 goes back to apps.yaml's or the default. Its
## windows follow at once.
func set_app_scale(id: String, percent: int) -> void:
	var scales: Dictionary = ThemeManager.app_scales.duplicate()
	if percent > 0:
		scales[id] = percent
	else:
		scales.erase(id)
	ThemeManager.set_look({app_scales = scales})
	ThemeManager.save_look()


## Windows of launched apps whose scale has changed get the new one.
func _rescale() -> void:
	for w in windows:
		var id: String = windows[w].app
		if id == "" or not _pids.has(id):
			continue
		var s := scale_of(id) / 100.0
		if not is_equal_approx(Wayland.window_scale(w), s):
			Wayland.set_window_scale(w, s)


## Running windows for the switcher, most recent first: `{window, app, name, icon}`.
func running() -> Array:
	var out := []
	for i in range(recent.size() - 1, -1, -1):
		var w: int = recent[i]
		var a := app(windows[w].app)
		var name: String = a.get("name", "")
		if name == "":
			name = windows[w].title if windows[w].title != "" else windows[w].app_id
		out.append({window = w, app = windows[w].app, name = name, icon = a.get("icon", "")})
	return out
