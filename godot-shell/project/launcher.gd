class_name Launcher
extends Node
## The apps the unit can run (`AppCatalog`: desktop entries, Waydroid's apps, apps.yaml), started
## as clients of the shell's compositor, and the hosted windows they and others map. One
## instance per app: opening a running app shows its window. Projection video is not an app.
##   LIVI_SHELL_APPS_DIRS  data dirs to list (':'-separated), instead of the XDG ones
##   LIVI_SHELL_APPS       the apps file, instead of $XDG_CONFIG_HOME/livi-shell/apps.yaml
##   LIVI_SHELL_APP_LOGS   where each app's output goes, instead of $XDG_STATE_HOME/livi-shell/apps
##   LIVI_SHELL_PORTAL     "off": no settings portal (another one serves the look)
## Its lines also go to $XDG_STATE_HOME/livi-shell/shell.log: under the kiosk service the
## shell's stdout and stderr reach the console, not the journal.

## The list, the running windows or a launch's state changed.
signal changed
## A window to bring forward: a launched app's first, or a running one that was picked.
signal show_window(id: int)

## Grace between asking a window to close, SIGTERM to its process group, and SIGKILL.
const CLOSE_GRACE_S := 3.0
## The scales, in percent, the settings offer apps.
const SCALES := [100, 125, 150, 175, 200]

## `{id, name, icon, argv, cwd, app_ids, source, timeout_s, scale, drive_safe}`, in the order to show.
var apps: Array = []
## Whether `apps` has been listed: empty can be the list, and a refresh emits `changed`.
var scanned := false
## Hosted windows by id: `{app_id, title, app}`, `app` the catalog id or "".
var windows := {}
## Window ids, most recently shown last.
var recent: Array[int] = []
## App id -> `{pid, started, timeout_s, exit, slow}` while its window has not mapped: `started`
## in ticks ms, `exit` its status once the process has gone (-1 before), `slow` once it has
## taken long enough to say so (`AppCatalog.launch_state`).
var launching := {}
## App id -> why its last launch failed.
var failed := {}
## Apps whose window the driver closed (`close`) since they were last opened: the shell does not
## start its navigation app again by itself after that.
var user_closed := {}

var _catalog := AppCatalog.new()
## App id -> the PID this launcher started it as; its process group is the same number.
var _pids := {}
## App id -> the window mode its windows were last given (`window_mode_of`).
var _modes := {}
var _poll_at := 0
## Whether the shell keeps a settings portal; while it is not served, apps get the look in their
## environment at launch instead, and do not follow it live.
var _portal := false
## The portal's last status, logged when it changes.
var _portal_status := ""
var _log_file: FileAccess


func _ready() -> void:
	# Which app a window is decides whether it is covered while driving.
	Drive.launcher = self
	changed.connect(Drive.changed.emit)
	Wayland.window_mapped.connect(_on_mapped)
	Wayland.window_unmapped.connect(_on_unmapped)
	ThemeManager.changed.connect(_rescale)
	ThemeManager.changed.connect(_send_look)
	ThemeManager.changed.connect(_tell_core_look)
	Core.welcome.connect(func(_v): _tell_core_look())
	_tell_core_look()
	_portal = OS.get_environment("LIVI_SHELL_PORTAL") != "off"
	if _portal:
		AppearancePortal.start(ThemeManager.appearance == "night", ThemeManager.c.accent, ThemeManager.reduced_motion)
	else:
		_log("launcher: no settings portal: LIVI_SHELL_PORTAL is off")


## A line for the console and shell.log, which starts afresh once it passes 1 MB.
func _log(line: String) -> void:
	print(line)
	if _log_file == null:
		# Beside the apps' logs: ~/.local/state/livi-shell/shell.log, a scenario's out/ in tests.
		var path := _log_path("").get_base_dir().get_base_dir().path_join("shell.log")
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		_log_file = FileAccess.open(path, FileAccess.READ_WRITE)
		if _log_file == null or _log_file.get_length() > 1 << 20:
			_log_file = FileAccess.open(path, FileAccess.WRITE)
		if _log_file == null:
			return
		_log_file.seek_end()
	_log_file.store_line("%s %s" % [Time.get_datetime_string_from_system(), line])
	_log_file.flush()


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
	scanned = true
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


## Launching for long enough to say it is still starting.
func slow(id: String) -> bool:
	return launching.has(id) and launching[id].slow


## Shows the app's window when it runs; otherwise starts it, unless it is starting already.
## `show` false starts it without bringing its window forward when it maps (home's slot shows it).
func open(id: String, show := true) -> void:
	user_closed.erase(id)
	var mine := windows_of(id)
	if not mine.is_empty():
		if show:
			bring(mine[-1])
		return
	if launching.has(id):
		launching[id].show = launching[id].show or show
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
	if not (_portal and AppearancePortal.serving()):
		# libadwaita's override of the portal; fixed for the app's life.
		env.ADW_DEBUG_COLOR_SCHEME = "prefer-dark" if ThemeManager.appearance == "night" else "prefer-light"
	var pid: int = _catalog.launch(a.argv, a.cwd, env, _log_path(id))
	if pid < 0:
		failed[id] = "could not start %s" % a.argv[0]
	else:
		_log("launcher: %s started as %d at %d %%: %s" % [id, pid, scale_of(id), " ".join(a.argv)])
		# Before the compositor next dispatches, which is when the client can connect.
		Wayland.set_process_scale(pid, scale_of(id) / 100.0)
		Wayland.set_process_fullscreen(pid, window_mode_of(id) == "fullscreen")
		_modes[id] = window_mode_of(id)
		_pids[id] = pid
		launching[id] = {pid = pid, started = Time.get_ticks_msec(), timeout_s = int(a.timeout_s), exit = -1, slow = false, show = show}
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
	if windows[window].app != "":
		user_closed[windows[window].app] = true
	var pid: int = _pids.get(windows[window].app, -1)
	if pid < 0:
		return
	for kill in [false, true]:
		await get_tree().create_timer(CLOSE_GRACE_S).timeout
		if windows.has(window) and _pids.get(windows[window].app, -1) == pid:
			_log("launcher: %s did not close, %s" % [windows[window].app, "SIGKILL" if kill else "SIGTERM"])
			_catalog.stop(pid, kill)


## SIGTERM to everything this launcher started.
func stop_all() -> void:
	for id in _pids:
		_catalog.stop(_pids[id], false)
		Wayland.set_process_scale(_pids[id], 0)
		Wayland.set_process_fullscreen(_pids[id], false)
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
	if _portal and AppearancePortal.status() != _portal_status:
		_portal_status = AppearancePortal.status()
		_log("launcher: settings portal: %s" % _portal_status)
	var dirty := false
	for id in _pids.keys():
		# Reaps it. One that hands off and exits 0 (waydroid app launch, a GApplication whose
		# D-Bus name another instance owns) may still show a window, and its group may live on;
		# one that fails is done.
		var code: int = _catalog.poll(_pids[id])
		if code < 0:
			continue
		if launching.has(id):
			launching[id].exit = code
			if code == 0:
				_log("launcher: %s's process %d exited 0 before its window: waiting for one from another" % [id, _pids[id]])
		if code > 0:
			Wayland.set_process_scale(_pids[id], 0)
			Wayland.set_process_fullscreen(_pids[id], false)
			_pids.erase(id)
	for id in launching.keys():
		var l: Dictionary = launching[id]
		var st: Dictionary = AppCatalog.launch_state(now - l.started, l.timeout_s, l.exit)
		if st.state == "failed":
			launching.erase(id)
			failed[id] = st.reason
			_log("launcher: %s %s" % [id, failed[id]])
			dirty = true
		elif st.state == "slow" and not l.slow:
			l.slow = true
			dirty = true
	if dirty:
		changed.emit()


func _on_mapped(id: int, app_id: String, title: String) -> void:
	# livi-output's: the phone's picture, which the projection pages own.
	if app_id.begins_with("livi-video"):
		return
	var owner := _owner_of(app_id, id, true)
	windows[id] = {app_id = app_id, title = title, app = owner}
	recent.append(id)
	var pid := Wayland.window_pid(id)
	if launching.has(owner):
		var l: Dictionary = launching[owner]
		var from := "" if pid == l.pid else ", from process %d" % pid
		_log("launcher: launched %s in %d ms%s" % [owner, Time.get_ticks_msec() - l.started, from])
		launching.erase(owner)
		# After the shell has the window too: it connected to the same signal later.
		if l.show:
			show_window.emit.call_deferred(id)
	elif failed.erase(owner):
		# Given up on, then up after all: running now, but not pulled forward this late.
		_log("launcher: %s's window came after its launch was given up (process %d)" % [owner, pid])
	changed.emit()


func _on_unmapped(id: int) -> void:
	if windows.erase(id):
		recent.erase(id)
		changed.emit()


## Which app a window is (`AppCatalog.window_owner`); `fresh` as it maps.
func _owner_of(app_id: String, window: int, fresh: bool) -> String:
	var group: int = _catalog.group_of(Wayland.window_pid(window))
	return _catalog.window_owner(app_id, group, PackedStringArray(launching.keys()), _pids, fresh)


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


## How the app's windows start: `maximized` (the default) or `fullscreen`, its own in Settings.
## The app may still go fullscreen or leave it itself.
func window_mode_of(id: String) -> String:
	return "fullscreen" if ThemeManager.app_window_modes.get(id, "") == "fullscreen" else "maximized"


## Saved with the look; open windows follow at once.
func set_app_window_mode(id: String, mode: String) -> void:
	var modes: Dictionary = ThemeManager.app_window_modes.duplicate()
	if mode == "fullscreen":
		modes[id] = mode
	else:
		modes.erase(id)
	ThemeManager.set_look({app_window_modes = modes})
	ThemeManager.save_look()


## Windows of launched apps whose scale or window mode has changed get the new one. A mode is
## sent only when the setting changes, so an app's own fullscreen choice stands until then.
func _rescale() -> void:
	for w in windows:
		var id: String = windows[w].app
		if id == "" or not _pids.has(id):
			continue
		var s := scale_of(id) / 100.0
		if not is_equal_approx(Wayland.window_scale(w), s):
			Wayland.set_window_scale(w, s)
		var mode := window_mode_of(id)
		if _modes.get(id, "maximized") != mode:
			Wayland.set_window_fullscreen(w, mode == "fullscreen")
	for id in _pids:
		_modes[id] = window_mode_of(id)


## Launched apps follow the shell's look through the portal.
func _send_look() -> void:
	if _portal:
		AppearancePortal.set_look(ThemeManager.appearance == "night", ThemeManager.c.accent, ThemeManager.reduced_motion)


## Day or night as shown, for the car's own displays (the instrument cluster follows it through
## the car integration). Again on each connection: the core forgets it when the shell's goes.
func _tell_core_look() -> void:
	if Core.get_value("/appearance") != ThemeManager.appearance:
		Core.act({kind = "setAppearance", appearance = ThemeManager.appearance})


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
