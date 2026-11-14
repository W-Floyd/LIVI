extends Node
## Runs the shell against livi-core, or the scenario runner with `-- --test <path>`, or the live tuning server with `-- --live`.

const Startup := preload("res://startup.gd")
const ShellScript := preload("res://shell.gd")
## Short at first: home waits for the core's state, and the core starts beside the shell.
var _core_retry_s := 0.25
var _welcomed := false


func _ready() -> void:
	set_process_input(false)
	var args := OS.get_cmdline_user_args()
	# load, not preload: a preload compiles the runner and the tuning server on every start.
	if args.has("--test"):
		var runner: Node = load("res://test/runner.gd").new()
		add_child(runner)
		runner.run(args)
		return
	if args.has("--live"):
		add_child(load("res://live/live_server.gd").new())
		return
	Startup.mark("main")
	var page := _saved_page()
	# livi-core's video host is pointed at this socket (packaging/), so a unit names it.
	var err: String = Wayland.listen(OS.get_environment("LIVI_SHELL_SOCKET"))
	if err != "":
		push_error("compositor: %s" % err)
	if Wayland.stub():
		err = Wayland.host_video()
		if err != "":
			push_error("compositor: %s" % err)
	Startup.mark("compositor")
	_keep_core()
	# The driver's look from last time; tests start from the default one and save nothing.
	ThemeManager.load_look(ThemeManager.default_look_file())
	Startup.mark("look")
	var shell: Control = preload("res://shell.tscn").instantiate()
	add_child(shell)
	Startup.mark("shell")
	_time_startup(shell)
	_compile_after_first_frame(page)
	# Once the home page is up: the live EV page's shaders, compiled while nobody waits.
	get_tree().create_timer(2.0).timeout.connect(shell.warm_up)
	if NavRail.wanted():
		NavRail.attach(shell, func(page): _open(shell, page))
	_restore_page(shell, page)


## Not sooner: a compile on another thread slows home's build (in the VM 25 -> 80 ms).
func _compile_after_first_frame(page: String) -> void:
	await RenderingServer.frame_post_draw
	ShellScript.compile_ahead(page if page in ShellScript.PAGE_SCRIPTS else "")


## The first frame; the first with the core's state on home (summed up in shell.log); the first
## touch, which the driver gives once the panel looks ready.
func _time_startup(shell: Control) -> void:
	Core.welcome.connect(_on_first_welcome.bind(shell), CONNECT_ONE_SHOT)
	set_process_input(true)
	await RenderingServer.frame_post_draw
	Startup.mark("first_frame")


func _on_first_welcome(_version: String, shell: Control) -> void:
	_welcomed = true
	Startup.mark("core")
	await RenderingServer.frame_post_draw
	Startup.mark("home")
	shell.launcher._log(Startup.summary())


func _input(event: InputEvent) -> void:
	if (event is InputEventScreenTouch or event is InputEventMouseButton) and event.pressed:
		Startup.mark("touch")
		set_process_input(false)


## LIVI_SHELL_TIMING logs how long a page takes to open and to draw its first frames, and the
## EV page's warm-up (shell.log: under the kiosk, stdout is the console).
func _open(shell: Control, page: String) -> void:
	var t0 := Time.get_ticks_msec()
	shell.open_page(page)
	if OS.get_environment("LIVI_SHELL_TIMING") == "":
		return
	var line := "[nav] %s: open_page %d ms, frames at" % [page, Time.get_ticks_msec() - t0]
	for i in 6:
		await RenderingServer.frame_post_draw
		line += " %d" % (Time.get_ticks_msec() - t0)
	shell.launcher._log(line)


## Connects to the core, and again whenever it goes: it starts after the shell, or restarts
## under it, and the shell would otherwise keep a dead link (input sent nowhere).
func _keep_core() -> void:
	Core.gone.connect(func(reason): print("core: gone (%s), reconnecting" % reason); _retry_core())
	_retry_core()


func _retry_core() -> void:
	var err: String = Core.try_connect_core()
	if err == "":
		print("core: connected")
		_core_retry_s = 0.25
		return
	get_tree().create_timer(_core_retry_s).timeout.connect(_retry_core)
	_core_retry_s = minf(_core_retry_s * 2.0, 2.0)


## The page open when the shell last stopped, so a restart lands where the driver was. A hosted
## app's window ("app") did not survive the restart: its grid instead.
func _saved_page() -> String:
	var f := FileAccess.open(_page_file(), FileAccess.READ)
	if f == null:
		return "home"
	var page := f.get_as_text().strip_edges()
	return "apps" if page == "app" else page if page != "" else "home"


func _page_file() -> String:
	var dir := OS.get_environment("XDG_STATE_HOME")
	if dir == "":
		dir = OS.get_environment("HOME").path_join(".local/state")
	return dir.path_join("livi-shell/page")


## Home first, with the core's state (the EV page needs it), and the page once its script is
## compiled: on the unit the EV page's compile and first draws took 9 s before home showed.
func _restore_page(shell: Control, page: String) -> void:
	var path := _page_file()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	shell.page_changed.connect(func(p):
		var w := FileAccess.open(path, FileAccess.WRITE)
		if w:
			w.store_string(p))
	if page == "home":
		return
	await RenderingServer.frame_post_draw
	if not _welcomed:
		await Core.welcome
	if page in ShellScript.PAGE_SCRIPTS:
		await ShellScript.compiled(page)
	# The driver went elsewhere meanwhile.
	if shell._page_name != "home":
		return
	if shell.open_page(page) != "":
		return
	await RenderingServer.frame_post_draw
	Startup.mark("restored")
