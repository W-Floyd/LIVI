extends Node
## Runs the shell against livi-core, or the scenario runner with `-- --test <path>`, or the live tuning server with `-- --live`.


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--test"):
		var runner := preload("res://test/runner.gd").new()
		add_child(runner)
		runner.run(args)
		return
	if args.has("--live"):
		add_child(preload("res://live/live_server.gd").new())
		return
	# livi-core's video host is pointed at this socket (packaging/), so a unit names it.
	var err: String = Wayland.listen(OS.get_environment("LIVI_SHELL_SOCKET"))
	if err != "":
		push_error("compositor: %s" % err)
	_keep_core()
	# The driver's look from last time; tests start from the default one and save nothing.
	ThemeManager.load_look(ThemeManager.default_look_file())
	var shell: Control = preload("res://shell.tscn").instantiate()
	add_child(shell)
	# Once the home page is up: the live EV page's shaders, compiled while nobody waits.
	get_tree().create_timer(2.0).timeout.connect(shell.warm_up)
	if OS.get_environment("LIVI_SHELL_NAV") != "":
		var rail: Control = preload("res://ui/nav_rail.gd").new()
		rail.selected.connect(func(page): _open(shell, page))
		shell.page_changed.connect(rail.show_page)
		add_child(rail)
	_restore_page(shell)


## LIVI_SHELL_TIMING prints how long a page takes to open and to draw its first frames.
func _open(shell: Control, page: String) -> void:
	var t0 := Time.get_ticks_msec()
	shell.open_page(page)
	if OS.get_environment("LIVI_SHELL_TIMING") == "":
		return
	print("[nav] %s: open_page %d ms" % [page, Time.get_ticks_msec() - t0])
	for i in 6:
		await RenderingServer.frame_post_draw
		print("[nav] %s: frame %d at %d ms" % [page, i, Time.get_ticks_msec() - t0])


## Connects to the core, and again whenever it goes: it starts after the shell, or restarts
## under it, and the shell would otherwise keep a dead link (input sent nowhere).
func _keep_core() -> void:
	Core.gone.connect(func(reason): print("core: gone (%s), reconnecting" % reason); _retry_core())
	_retry_core()


func _retry_core() -> void:
	var err: String = Core.try_connect_core()
	if err == "":
		print("core: connected")
		return
	get_tree().create_timer(2.0).timeout.connect(_retry_core)


## The page open when the shell last stopped, so a restart lands where the driver was. A hosted
## app's window ("app") did not survive the restart: its grid instead.
func _restore_page(shell: Control) -> void:
	var dir := OS.get_environment("XDG_STATE_HOME")
	if dir == "":
		dir = OS.get_environment("HOME").path_join(".local/state")
	var path := dir.path_join("livi-shell/page")
	var f := FileAccess.open(path, FileAccess.READ)
	if f:
		var page := f.get_as_text().strip_edges()
		f.close()
		if page == "app":
			page = "apps"
		if page != "" and page != "home":
			shell.open_page.call_deferred(page)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	shell.page_changed.connect(func(page):
		var w := FileAccess.open(path, FileAccess.WRITE)
		if w:
			w.store_string(page))
