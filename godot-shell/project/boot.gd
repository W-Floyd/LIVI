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
	err = Core.connect_core("")
	if err != "":
		push_error("core: %s" % err)
	add_child(preload("res://shell.tscn").instantiate())
